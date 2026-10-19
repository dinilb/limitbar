import LimitBarDomain
import Foundation

public struct UsageRequest: Sendable {
    public let providers: [String]
    public let timeout: TimeInterval
    public let maxAge: TimeInterval
    public let refresh: Bool
    public let cacheOnly: Bool
    public let noCache: Bool
    public let includeSpend: Bool
    public let codexHome: URL?
    public let claudeHome: URL?
    /// True only when a person clicked Refresh and is waiting on this reading. It
    /// lifts the throttle on launching `claude` to renew its login; nothing shows a
    /// dialog either way.
    public let userInitiated: Bool

    public init(
        providers: [String] = ["codex", "claude"],
        timeout: TimeInterval = 20,
        maxAge: TimeInterval = 300,
        refresh: Bool = false,
        cacheOnly: Bool = false,
        noCache: Bool = false,
        includeSpend: Bool = false,
        codexHome: URL? = nil,
        claudeHome: URL? = nil,
        userInitiated: Bool = false
    ) {
        self.providers = providers
        self.timeout = timeout
        self.maxAge = maxAge
        self.refresh = refresh
        self.cacheOnly = cacheOnly
        self.noCache = noCache
        self.includeSpend = includeSpend
        self.codexHome = codexHome
        self.claudeHome = claudeHome
        self.userInitiated = userInitiated
    }
}

public struct UsageService: Sendable {
    private let providerMap: [String: any UsageProvider]
    private let cache: SnapshotCache
    private let clock: @Sendable () -> Date

    public init(
        providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider()],
        cache: SnapshotCache = SnapshotCache()
    ) {
        self.providerMap = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.cache = cache
        self.clock = { Date() }
    }

    init(
        providers: [any UsageProvider],
        cache: SnapshotCache,
        clock: @escaping @Sendable () -> Date
    ) {
        self.providerMap = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.cache = cache
        self.clock = clock
    }

    public func collect(_ request: UsageRequest = UsageRequest()) async -> UsageDocument {
        let now = clock()
        if request.noCache {
            let live = await fetch(names: request.providers, request: request, now: now)
            return document(from: request.providers, results: live, includeSpend: request.includeSpend, now: now)
        }

        let lock: FileLock
        do {
            lock = try cache.acquireLock()
        } catch {
            let live = await fetch(names: request.providers, request: request, now: now)
            return document(from: request.providers, results: live, includeSpend: request.includeSpend, now: now)
        }
        defer { lock.unlock() }

        var cached = cache.loadProviders()
        var state = cache.loadState()
        if request.cacheOnly {
            let values = request.providers.map { name in
                guard let previous = cached[name] else {
                    return missingCache(provider: name, now: now)
                }
                return ProviderUsage(
                    provider: previous.provider,
                    status: previous.status,
                    plan: previous.plan,
                    source: previous.source,
                    fetchedAt: previous.fetchedAt,
                    stale: true,
                    windows: previous.windows,
                    credits: previous.credits,
                    notes: previous.notes + ["cache-only mode"],
                    error: previous.error
                )
            }
            return UsageDocument.make(providers: values, generatedAt: now)
        }

        var resolved: [String: ProviderUsage] = [:]
        var toFetch: [String] = []
        for name in request.providers {
            let spendRequiresLive = request.includeSpend && name == "claude"
            if !request.refresh, !spendRequiresLive,
               let previous = cached[name], isFresh(previous, maxAge: request.maxAge, now: now) {
                resolved[name] = previous
                continue
            }
            if let cooldown = state.providers[name]?.cooldownUntil, cooldown > now {
                let failure = ProviderFailure.snapshot(
                    provider: name,
                    status: .rateLimited,
                    source: name == "claude" ? "anthropic-oauth-usage" : "provider",
                    message: "refresh cooling down until \(UsageDate.format(cooldown) ?? "later")",
                    now: now
                )
                resolved[name] = fallback(failure: failure, cached: cached[name], now: now)
                continue
            }
            toFetch.append(name)
        }

        let fetched = await fetch(names: toFetch, request: request, now: now)
        for name in toFetch {
            let result = fetched[name] ?? ProviderFetchResult(snapshot: unsupported(provider: name, now: now))
            let snapshot = result.snapshot
            // A confirmed loss of subscription replaces last-good quota too;
            // retaining that quota would resurrect a plan the user no longer has.
            if snapshot.status == .ok || snapshot.status == .noSubscription {
                state.providers[name] = RefreshState.ProviderState(cooldownUntil: nil, consecutiveRateLimits: 0)
                cached[name] = snapshot.withoutSpend()
                resolved[name] = request.includeSpend ? snapshot : snapshot.withoutSpend()
            } else {
                if snapshot.status == .rateLimited {
                    let failures = (state.providers[name]?.consecutiveRateLimits ?? 0) + 1
                    let delay = min(3_600.0, 900.0 * pow(2.0, Double(max(0, failures - 1))))
                    state.providers[name] = RefreshState.ProviderState(
                        cooldownUntil: result.retryAfter ?? now.addingTimeInterval(delay),
                        consecutiveRateLimits: failures
                    )
                }
                resolved[name] = fallback(failure: snapshot, cached: cached[name], now: now)
            }
        }
        cache.storeProviders(cached, now: now)
        cache.storeState(state)
        let ordered = request.providers.map { resolved[$0] ?? unsupported(provider: $0, now: now) }
        return UsageDocument.make(providers: ordered, generatedAt: now)
    }

    private func fetch(
        names: [String],
        request: UsageRequest,
        now: Date
    ) async -> [String: ProviderFetchResult] {
        let options = UsageProviderOptions(
            timeout: request.timeout,
            codexHome: request.codexHome,
            claudeHome: request.claudeHome,
            userInitiated: request.userInitiated
        )
        return await withTaskGroup(of: (String, ProviderFetchResult).self) { group in
            for name in names {
                guard let provider = providerMap[name] else { continue }
                group.addTask { (name, await provider.fetch(options: options, now: now)) }
            }
            var values: [String: ProviderFetchResult] = [:]
            for await (name, value) in group { values[name] = value }
            return values
        }
    }

    private func document(
        from names: [String],
        results: [String: ProviderFetchResult],
        includeSpend: Bool,
        now: Date
    ) -> UsageDocument {
        UsageDocument.make(providers: names.map { name in
            let value = results[name]?.snapshot ?? unsupported(provider: name, now: now)
            return includeSpend ? value : value.withoutSpend()
        }, generatedAt: now)
    }

    private func isFresh(_ provider: ProviderUsage, maxAge: TimeInterval, now: Date) -> Bool {
        guard provider.status == .ok || provider.status == .noSubscription,
              !provider.stale, let fetched = provider.fetchedAt else { return false }
        let age = now.timeIntervalSince(fetched)
        return age >= 0 && age <= maxAge
    }

    private func fallback(failure: ProviderUsage, cached: ProviderUsage?, now: Date) -> ProviderUsage {
        guard let cached else { return failure }
        let age = cached.fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
        return ProviderUsage(
            provider: cached.provider,
            status: failure.status,
            plan: cached.plan ?? failure.plan,
            source: cached.source,
            fetchedAt: cached.fetchedAt,
            stale: true,
            windows: cached.windows,
            credits: cached.credits,
            notes: cached.notes + ["showing cached data from \(age)s ago"],
            error: failure.error
        )
    }

    private func missingCache(provider: String, now: Date) -> ProviderUsage {
        ProviderFailure.snapshot(
            provider: provider,
            status: .unknown,
            source: "cache",
            message: "no cached snapshot available",
            now: now
        )
    }

    private func unsupported(provider: String, now: Date) -> ProviderUsage {
        ProviderFailure.snapshot(
            provider: provider,
            status: .unsupported,
            source: "limitbar",
            message: "unknown provider",
            now: now
        )
    }
}
