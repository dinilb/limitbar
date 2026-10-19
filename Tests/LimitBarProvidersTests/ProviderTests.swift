import LimitBarDomain
import Foundation
import Testing
@testable import LimitBarProviders

private let now = Date(timeIntervalSince1970: 1_786_118_460)

@Test func codexFreePlanClassifiesThirtyDayPrimaryByDuration() throws {
    let payload: [String: Any] = [
        "rateLimits": [
            "primary": ["usedPercent": 83, "windowDurationMins": 43_200, "resetsAt": 1_788_700_645],
            "secondary": NSNull(),
            "credits": ["hasCredits": false, "unlimited": false],
            "planType": "free"
        ]
    ]
    let snapshot = CodexProvider.parseRateLimits(payload, now: now)
    #expect(snapshot.status == .ok)
    #expect(snapshot.plan == "free")
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows[0].key == "monthly")
    #expect(snapshot.windows[0].windowMinutes == 43_200)
    #expect(snapshot.windows[0].isFiveHour == false)
    #expect(snapshot.windows[0].remainingPercent == 17)
}

@Test func codexMalformedSchemaIsTypedFailure() {
    let snapshot = CodexProvider.parseRateLimits(["unexpected": true], now: now)
    #expect(snapshot.status == .upstreamError)
    #expect(snapshot.windows.isEmpty)
}

@Test func claudeLimitsAndSpendAreNarrowlyNormalized() throws {
    let payload: [String: Any] = [
        "limits": [
            ["kind": "session", "percent": 27, "resets_at": "2026-08-07T21:20:00Z"],
            ["kind": "weekly_all", "percent": 44, "resets_at": "2026-08-11T05:00:00Z"],
            ["kind": "monthly_haiku", "percent": 3, "unexpected": "must-not-escape"]
        ],
        "spend": [
            "used": ["amount_minor": 2147, "currency": "AUD", "exponent": 2, "secret": "ignored"],
            "limit": ["amount_minor": 2000, "currency": "AUD", "exponent": 2],
            "percent": 100,
            "enabled": false,
            "unexpected": "ignored"
        ],
        "unexpected": "ignored"
    ]
    let snapshot = ClaudeProvider.parseUsage(payload, now: now)
    #expect(snapshot.status == .ok)
    #expect(snapshot.windows.map(\.key) == ["five_hour", "weekly", "monthly_haiku"])
    #expect(snapshot.windows[0].windowMinutes == 300)
    #expect(snapshot.windows[0].remainingPercent == 73)
    #expect(snapshot.spend?.used?.amountMinor == 2147)
    let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(encoded.contains("must-not-escape") == false)
    #expect(encoded.contains("ignored") == false)
}

@Test func claudeScopedWeeklyIsNamedAfterItsModel() {
    let payload: [String: Any] = [
        "limits": [
            ["kind": "weekly_all", "group": "weekly", "percent": 12, "resets_at": "2026-10-20T05:00:00Z"],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 0, "resets_at": "2026-10-20T05:00:00Z",
             "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 5, "resets_at": "2026-10-20T05:00:00Z",
             "scope": NSNull()]
        ]
    ]
    let snapshot = ClaudeProvider.parseUsage(payload, now: now)
    #expect(snapshot.windows.map(\.key) == ["weekly", "weekly_scoped_fable", "weekly_scoped"])
    #expect(snapshot.windows.map(\.label) == ["7d", "Fable 7d", "Model 7d"])
}

@Test func claudeLegacyFractionalUtilizationIsScaled() {
    let payload: [String: Any] = [
        "five_hour": ["utilization": 0.27, "resets_at": "2026-08-07T21:20:00Z"],
        "seven_day": ["utilization": 0.44, "resets_at": "2026-08-11T05:00:00Z"]
    ]
    let snapshot = ClaudeProvider.parseUsage(payload, now: now)
    #expect(snapshot.windows.map(\.usedPercent) == [27, 44])
}

private struct FixedCredentialReader: ClaudeCredentialReading {
    let credential: ClaudeCredential
    func read(claudeHome: URL?, environment: [String: String]) async throws -> ClaudeCredential { credential }
}

private struct FixedTransport: HTTPTransport {
    let response: HTTPTransportResponse
    func send(_ request: URLRequest, timeout: TimeInterval, allowedHost: String) async throws -> HTTPTransportResponse {
        response
    }
}

@Test func canaryNeverReachesDocumentErrorOrCache() async throws {
    let canary = "sk-ant-oat01-SWIFT-CANARY-DO-NOT-LEAK"
    let credential = ClaudeCredential(
        accessToken: Secret(canary, label: "canary"),
        source: "test",
        expiresAtMilliseconds: nil,
        subscriptionType: "max",
        rateLimitTier: nil
    )
    let responseData = try JSONSerialization.data(withJSONObject: [
        "limits": [["kind": canary, "percent": 5, "unexpected": canary]],
        "unexpected": canary
    ])
    let transport = FixedTransport(response: HTTPTransportResponse(
        statusCode: 200,
        headers: [:],
        data: responseData,
        finalURL: URL(string: "https://api.anthropic.com/api/oauth/usage")
    ))
    let provider = ClaudeProvider(
        credentials: FixedCredentialReader(credential: credential),
        transport: transport
    )
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    let encoded = String(decoding: try JSONEncoder().encode(result.snapshot), as: UTF8.self)
    #expect(encoded.contains(canary) == false)
    #expect(result.snapshot.status == .ok)
    let widget = WidgetSnapshot(document: UsageDocument.make(providers: [result.snapshot]))
    #expect(String(decoding: try JSONEncoder().encode(widget), as: UTF8.self).contains(canary) == false)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("limitbar-canary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = SnapshotCache(directory: directory)
    let service = UsageService(
        providers: [provider],
        cache: cache,
        clock: { now }
    )
    _ = await service.collect(UsageRequest(providers: ["claude"], noCache: false))
    let bytes = try Data(contentsOf: cache.snapshotURL)
    #expect(String(decoding: bytes, as: UTF8.self).contains(canary) == false)
}

private struct ThrowingTransport: HTTPTransport {
    let error: URLError
    func send(_ request: URLRequest, timeout: TimeInterval, allowedHost: String) async throws -> HTTPTransportResponse {
        throw error
    }
}

private struct ThrowingCredentialReader: ClaudeCredentialReading {
    let error: CredentialReadError
    func read(claudeHome: URL?, environment: [String: String]) async throws -> ClaudeCredential { throw error }
}

@Test(arguments: [401, 403])
func claudeRejectedCredentialsAreAuthExpired(status: Int) async {
    let credential = ClaudeCredential(
        accessToken: Secret("sk-ant-oat01-HTTP-STATUS-CANARY"), source: "test",
        expiresAtMilliseconds: nil, subscriptionType: "max", rateLimitTier: nil
    )
    let provider = ClaudeProvider(
        credentials: FixedCredentialReader(credential: credential),
        transport: FixedTransport(response: HTTPTransportResponse(
            statusCode: status, headers: [:], data: Data("discard me".utf8),
            finalURL: URL(string: "https://api.anthropic.com/api/oauth/usage")
        ))
    )
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    #expect(result.snapshot.status == .authExpired)
    #expect(result.snapshot.error?.message.contains("discard me") == false)
}

@Test func claude429SurfacesRetryAfterAndOfflineIsTyped() async {
    let credential = ClaudeCredential(
        accessToken: Secret("sk-ant-oat01-RATE-LIMIT-CANARY"), source: "test",
        expiresAtMilliseconds: nil, subscriptionType: nil, rateLimitTier: nil
    )
    let rateLimited = ClaudeProvider(
        credentials: FixedCredentialReader(credential: credential),
        transport: FixedTransport(response: HTTPTransportResponse(
            statusCode: 429, headers: ["retry-after": "120"], data: Data(),
            finalURL: URL(string: "https://api.anthropic.com/api/oauth/usage")
        ))
    )
    let limitedResult = await rateLimited.fetch(options: UsageProviderOptions(), now: now)
    #expect(limitedResult.snapshot.status == .rateLimited)
    #expect(limitedResult.retryAfter == now.addingTimeInterval(120))

    let offline = ClaudeProvider(
        credentials: FixedCredentialReader(credential: credential),
        transport: ThrowingTransport(error: URLError(.notConnectedToInternet))
    )
    #expect(await offline.fetch(options: UsageProviderOptions(), now: now).snapshot.status == .offline)
}

@Test func unreadableKeychainIsReportedWithoutTransport() async {
    let provider = ClaudeProvider(
        credentials: ThrowingCredentialReader(error: .blocked),
        transport: ThrowingTransport(error: URLError(.unknown))
    )
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    #expect(result.snapshot.status == .authBlocked)
    #expect(result.snapshot.status.remedy(for: "claude")?.contains("Refresh") == true)
}

private struct ThrowingRPCClient: CodexRPCClient {
    func readRateLimits(options: UsageProviderOptions) async throws -> Data {
        throw CodexRPCError.timeout("fixture")
    }
}

@Test func codexTimeoutBecomesTypedFailure() async {
    let result = await CodexProvider(client: ThrowingRPCClient())
        .fetch(options: UsageProviderOptions(timeout: 0.01), now: now)
    #expect(result.snapshot.status == .upstreamError)
    #expect(result.snapshot.error?.message.contains("token") == false)
}

@Test func crossHostFinalURLIsRejected() async {
    let credential = ClaudeCredential(
        accessToken: Secret("sk-ant-oat01-REDIRECT-CANARY"), source: "test",
        expiresAtMilliseconds: nil, subscriptionType: nil, rateLimitTier: nil
    )
    let response = HTTPTransportResponse(
        statusCode: 200,
        headers: [:],
        data: Data(#"{"limits":[{"kind":"session","percent":1}]}"#.utf8),
        finalURL: URL(string: "https://example.invalid/collect")
    )
    let provider = ClaudeProvider(
        credentials: FixedCredentialReader(credential: credential),
        transport: FixedTransport(response: response)
    )
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    #expect(result.snapshot.status == .upstreamError)
    #expect(result.snapshot.error?.message.contains("redirect") == true)
}

@Test func retryAfterSupportsSecondsAndHTTPDate() {
    #expect(ClaudeProvider.parseRetryAfter("120", now: now) == now.addingTimeInterval(120))
    #expect(ClaudeProvider.parseRetryAfter("Fri, 07 Aug 2026 17:00:00 GMT", now: now) != nil)
}

private actor FetchCounter {
    var value = 0
    func increment() { value += 1 }
}

private struct CountingProvider: UsageProvider {
    let id: String
    let counter: FetchCounter

    func fetch(options: UsageProviderOptions, now: Date) async -> ProviderFetchResult {
        await counter.increment()
        return ProviderFetchResult(snapshot: ProviderUsage(
            provider: id,
            status: .ok,
            source: "fixture",
            fetchedAt: now,
            windows: [UsageWindow(
                key: "five_hour", label: "5h", windowMinutes: 300,
                usedPercent: 10, remainingPercent: 90, resetsAt: now.addingTimeInterval(300)
            )]
        ))
    }
}

@Test func freshCacheCoalescesRapidPolls() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("limitbar-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = FetchCounter()
    let service = UsageService(
        providers: [CountingProvider(id: "claude", counter: counter)],
        cache: SnapshotCache(directory: directory),
        clock: { now }
    )
    let request = UsageRequest(providers: ["claude"], maxAge: 300)
    let first = await service.collect(request)
    let second = await service.collect(request)
    #expect(first.ok)
    #expect(second.ok)
    #expect(await counter.value == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("snapshot.json").path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func cacheOnlyIsAlwaysConservativeAndSpendIsNeverCached() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("limitbar-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = FetchCounter()
    let service = UsageService(
        providers: [CountingProvider(id: "claude", counter: counter)],
        cache: SnapshotCache(directory: directory),
        clock: { now }
    )
    _ = await service.collect(UsageRequest(providers: ["claude"]))
    let cached = await service.collect(UsageRequest(providers: ["claude"], cacheOnly: true))
    #expect(cached.ok == false)
    #expect(cached.providers[0].stale)
    #expect(cached.providers[0].spend == nil)
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor ScriptedProviderState {
    var statuses: [UsageStatus]
    var calls = 0
    init(_ statuses: [UsageStatus]) { self.statuses = statuses }

    func next(provider: String, now: Date) -> ProviderFetchResult {
        calls += 1
        let status = statuses.isEmpty ? .ok : statuses.removeFirst()
        if status == .ok {
            return ProviderFetchResult(snapshot: ProviderUsage(
                provider: provider,
                status: .ok,
                source: "fixture",
                fetchedAt: now,
                windows: [UsageWindow(
                    key: "five_hour", label: "5h", windowMinutes: 300,
                    usedPercent: 20, remainingPercent: 80, resetsAt: now.addingTimeInterval(1_800)
                )]
            ))
        }
        let snapshot = ProviderUsage(
            provider: provider,
            status: status,
            source: "fixture",
            fetchedAt: now,
            error: UsageIssue(code: status.rawValue, message: "fixture failure")
        )
        return ProviderFetchResult(
            snapshot: snapshot,
            retryAfter: status == .rateLimited ? now.addingTimeInterval(900) : nil
        )
    }
}

private struct ScriptedProvider: UsageProvider {
    let id: String
    let state: ScriptedProviderState
    func fetch(options: UsageProviderOptions, now: Date) async -> ProviderFetchResult {
        await state.next(provider: id, now: now)
    }
}

@Test func cooldownBlocksForcedRefreshThenRecoversAfterSuccess() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("limitbar-cooldown-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = MutableClock(now)
    let state = ScriptedProviderState([.rateLimited, .ok])
    let service = UsageService(
        providers: [ScriptedProvider(id: "claude", state: state)],
        cache: SnapshotCache(directory: directory),
        clock: { clock.read() }
    )
    let forced = UsageRequest(providers: ["claude"], refresh: true)
    #expect(await service.collect(forced).providers[0].status == .rateLimited)
    #expect(await service.collect(forced).providers[0].status == .rateLimited)
    #expect(await state.calls == 1)
    clock.advance(901)
    #expect(await service.collect(forced).ok)
    #expect(await state.calls == 2)
    #expect(await service.collect(UsageRequest(providers: ["claude"])).ok)
    #expect(await state.calls == 2)
}

@Test func refreshFailureRetainsLastGoodValuesAsStale() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("limitbar-fallback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = MutableClock(now)
    let state = ScriptedProviderState([.ok, .offline])
    let service = UsageService(
        providers: [ScriptedProvider(id: "claude", state: state)],
        cache: SnapshotCache(directory: directory),
        clock: { clock.read() }
    )
    #expect(await service.collect(UsageRequest(providers: ["claude"])).ok)
    clock.advance(301)
    let failed = await service.collect(UsageRequest(providers: ["claude"]))
    #expect(failed.ok == false)
    #expect(failed.providers[0].status == .offline)
    #expect(failed.providers[0].stale)
    #expect(failed.providers[0].windows[0].remainingPercent == 80)
    #expect(failed.providers[0].error?.code == "offline")
}

@Test func noCacheNeverReadsOrWritesSnapshotOrState() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("limitbar-no-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = ScriptedProviderState([.ok])
    let cache = SnapshotCache(directory: directory)
    let service = UsageService(
        providers: [ScriptedProvider(id: "codex", state: state)], cache: cache, clock: { now }
    )
    #expect(await service.collect(UsageRequest(providers: ["codex"], noCache: true)).ok)
    #expect(FileManager.default.fileExists(atPath: cache.snapshotURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("refresh-state.json").path) == false)
}

// MARK: - Renewal through `claude`

private func unusedTransport() -> FixedTransport {
    FixedTransport(response: HTTPTransportResponse(
        statusCode: 200, headers: [:], data: Data(),
        finalURL: URL(string: "https://api.anthropic.com/api/oauth/usage")
    ))
}

private func usageTransport() -> FixedTransport {
    FixedTransport(response: HTTPTransportResponse(
        statusCode: 200, headers: [:],
        data: Data(#"{"five_hour":{"utilization":10,"resets_at":"2026-08-08T20:00:00Z"}}"#.utf8),
        finalURL: URL(string: "https://api.anthropic.com/api/oauth/usage")
    ))
}

private func temporaryCacheDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("limitbar-cli-gate-\(UUID().uuidString)", isDirectory: true)
}

/// Stands in for `claude`: counts launches and, once "run", flips the reader to a
/// renewed token, the way Claude Code rewrites its Keychain item on startup.
private final class FakeClaudeCLI: ClaudeCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var renewCount = 0
    private var usageCount = 0
    let reader: RenewableReader?
    let screen: String?

    init(reader: RenewableReader? = nil, screen: String? = nil) {
        self.reader = reader
        self.screen = screen
    }

    var renews: Int { lock.withLock { renewCount } }
    var usageReads: Int { lock.withLock { usageCount } }

    func renewLogin(timeout: TimeInterval, renewed: @escaping @Sendable () -> Bool) async -> Bool {
        lock.withLock { renewCount += 1 }
        reader?.renew()
        return true
    }

    func readUsageScreen(timeout: TimeInterval) async -> String? {
        lock.withLock { usageCount += 1 }
        return screen
    }
}

private final class RenewableReader: ClaudeCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private var renewed = false

    func renew() { lock.withLock { renewed = true } }

    func read(claudeHome: URL?, environment: [String: String]) async throws -> ClaudeCredential {
        let fresh = lock.withLock { renewed }
        return ClaudeCredential(
            accessToken: Secret(fresh ? "sk-ant-oat01-renewed-token" : "sk-ant-oat01-stale-token", label: "test"),
            source: "keychain",
            expiresAtMilliseconds: Int64(now.addingTimeInterval(fresh ? 28_800 : -3_600).timeIntervalSince1970 * 1_000),
            subscriptionType: "pro",
            rateLimitTier: nil
        )
    }
}

@Test func expiredKeychainTokenIsRenewedByLaunchingClaude() async {
    let directory = temporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = RenewableReader()
    let cli = FakeClaudeCLI(reader: reader)
    let provider = ClaudeProvider(
        credentials: reader, transport: usageTransport(),
        cli: cli, gate: ClaudeCLIGate(cacheDirectory: directory)
    )
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    #expect(result.snapshot.status == .ok)
    #expect(cli.renews == 1)
    #expect(cli.usageReads == 0)
}

@Test func backgroundLaunchesAreThrottledButRefreshIsNot() async {
    let directory = temporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = ClaudeCLIGate(cacheDirectory: directory)
    #expect(gate.claim(userInitiated: false, now: now))
    #expect(!gate.claim(userInitiated: false, now: now.addingTimeInterval(60)))
    #expect(gate.claim(userInitiated: true, now: now.addingTimeInterval(61)))
    #expect(gate.claim(userInitiated: false, now: now.addingTimeInterval(61 + ClaudeCLIGate.backgroundInterval)))
}

@Test func throttledExpiredTokenFallsBackToAuthExpiredWithoutLaunching() async {
    let directory = temporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = ClaudeCLIGate(cacheDirectory: directory)
    _ = gate.claim(userInitiated: false, now: Date())
    let cli = FakeClaudeCLI(reader: RenewableReader())
    let provider = ClaudeProvider(credentials: RenewableReader(), transport: unusedTransport(), cli: cli, gate: gate)
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    #expect(result.snapshot.status == .authExpired)
    #expect(cli.renews == 0)
    #expect(cli.usageReads == 0)
}

@Test func unreadableLoginFallsBackToTheUsageScreen() async {
    let directory = temporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = FakeClaudeCLI(screen: """
    Current session
    12% used  (Resets 11am)
    Current week (all models)
    40% used  (Resets Nov 21)
    Current week (Sonnet only)
    5% used (Resets Nov 21)
    """)
    let provider = ClaudeProvider(
        credentials: ThrowingCredentialReader(error: .blocked), transport: unusedTransport(),
        cli: cli, gate: ClaudeCLIGate(cacheDirectory: directory)
    )
    let result = await provider.fetch(options: UsageProviderOptions(userInitiated: true), now: now)
    #expect(result.snapshot.status == .ok)
    #expect(result.snapshot.source == "claude-cli-usage")
    #expect(result.snapshot.windows.map(\.key) == ["five_hour", "weekly", "weekly_scoped_sonnet"])
    #expect(result.snapshot.windows.map(\.remainingPercent) == [88, 60, 95])
}

@Test func usageScreenParsesLeftAndUsedThroughTerminalNoise() {
    let left = ClaudeUsageScreen.parse("Current session\n93% left\nDec 23 at 4:00PM\nCurrent week (all models)\n79% left")
    #expect(left.map(\.usedPercent) == [7, 21])

    let raw = Data("\u{1B}[2J\u{1B}[1;1HCurrent\u{1B}[1Csession\u{1B}[0m\r\n\u{1B}[32m57% used\u{1B}[39m".utf8)
    let noisy = ClaudeUsageScreen.parse(ClaudeUsageScreen.plainText(raw))
    #expect(noisy.first?.key == "five_hour")
    #expect(noisy.first?.usedPercent == 57)

    #expect(ClaudeUsageScreen.parse("Error: Failed to load usage data").isEmpty)
}

@Test func childClaudeDropsInheritedSessionCredentials() {
    let child = claudeChildEnvironment(
        ["CLAUDE_CODE_OAUTH_TOKEN": "x", "CLAUDECODE": "1", "ANTHROPIC_API_KEY": "k",
         "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h", "PATH": "/usr/bin"],
        executable: URL(fileURLWithPath: "/opt/bin/claude")
    )
    #expect(child["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(child["CLAUDECODE"] == nil)
    #expect(child["ANTHROPIC_API_KEY"] == nil)
    #expect(child["CLAUDE_CONFIG_DIR"] == "/c")
    #expect(child["PATH"]?.hasPrefix("/opt/bin:") == true)
}

// MARK: - Credential cache

private func keychainCredential(expiresAt: Date?) -> ClaudeCredential {
    ClaudeCredential(
        accessToken: Secret("sk-ant-oat01-cache-test-token", label: "test"),
        source: "keychain",
        expiresAtMilliseconds: expiresAt.map { Int64($0.timeIntervalSince1970 * 1_000) },
        subscriptionType: "max",
        rateLimitTier: nil
    )
}

@Test func cachedCredentialIsReusedUntilItNearsExpiry() {
    let cache = ClaudeCredentialCache()
    cache.store(keychainCredential(expiresAt: now.addingTimeInterval(3_600)))
    #expect(cache.value(at: now) != nil)
    #expect(cache.value(at: now.addingTimeInterval(3_000)) != nil)
}

@Test func cachedCredentialRetiresBeforeItExpires() {
    let cache = ClaudeCredentialCache()
    let expiry = now.addingTimeInterval(3_600)
    cache.store(keychainCredential(expiresAt: expiry))
    // Inside the safety margin the token could die mid-request, so we stop serving it.
    #expect(cache.value(at: expiry.addingTimeInterval(-ClaudeCredentialCache.margin + 1)) == nil)
    #expect(cache.value(at: expiry.addingTimeInterval(60)) == nil)
}

@Test func onlyKeychainCredentialsWithKnownExpiryAreCached() {
    let noExpiry = ClaudeCredentialCache()
    noExpiry.store(keychainCredential(expiresAt: nil))
    #expect(noExpiry.value(at: now) == nil)

    let fromFile = ClaudeCredentialCache()
    fromFile.store(ClaudeCredential(
        accessToken: Secret("sk-ant-oat01-file-token", label: "test"),
        source: "credentials-file",
        expiresAtMilliseconds: Int64(now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
        subscriptionType: nil,
        rateLimitTier: nil
    ))
    #expect(fromFile.value(at: now) == nil)
}

/// Serves a credential and records whether the provider dropped it after a rejection.
private final class InvalidationSpy: ClaudeCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    var didInvalidate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func read(claudeHome: URL?, environment: [String: String]) async throws -> ClaudeCredential {
        ClaudeCredential(
            accessToken: Secret("sk-ant-oat01-rotation-test", label: "test"),
            source: "keychain",
            expiresAtMilliseconds: Int64(now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
            subscriptionType: "pro",
            rateLimitTier: nil
        )
    }

    private func markInvalidated() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func invalidate() async { markInvalidated() }
}

@Test(arguments: [401, 403])
func rejectedTokenDropsTheCachedCredential(status: Int) async {
    let spy = InvalidationSpy()
    let provider = ClaudeProvider(
        credentials: spy,
        transport: FixedTransport(response: HTTPTransportResponse(
            statusCode: status, headers: [:], data: Data(),
            finalURL: URL(string: "https://api.anthropic.com/api/oauth/usage")
        ))
    )
    _ = await provider.fetch(options: UsageProviderOptions(), now: now)
    // Without this the cache would replay a revoked token until its stated expiry.
    #expect(spy.didInvalidate)
}

@Test func clearingTheCacheForcesAFreshRead() {
    let cache = ClaudeCredentialCache()
    cache.store(keychainCredential(expiresAt: now.addingTimeInterval(3_600)))
    #expect(cache.value(at: now) != nil)
    cache.clear()
    #expect(cache.value(at: now) == nil)
}

@Test func explicitNoSubscriptionHidesClaudeWithoutRequestingUsage() async throws {
    let credential = ClaudeCredential(accessToken: Secret("fixture", label: "test"), source: "test", expiresAtMilliseconds: nil, subscriptionType: "pro", rateLimitTier: nil)
    let transport = ProfileOnlyTransport()
    let provider = ClaudeProvider(credentials: FixedCredentialReader(credential: credential), transport: transport)
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    #expect(result.snapshot.status == .noSubscription)
    #expect(result.snapshot.windows.isEmpty)
}

private struct ProfileOnlyTransport: HTTPTransport {
    func send(_ request: URLRequest, timeout: TimeInterval, allowedHost: String) async throws -> HTTPTransportResponse {
        #expect(request.url?.path == "/api/oauth/profile")
        return HTTPTransportResponse(statusCode: 200, headers: [:], data: Data("{\"organization\":{\"organization_type\":\"claude_free\",\"subscription_status\":\"canceled\"}}".utf8), finalURL: request.url)
    }
}

@Test func paidAndUnknownProfilesDoNotHideClaude() {
    for type in ["claude_pro", "claude_max", "claude_team", "claude_enterprise", "unknown"] {
        #expect(!ClaudeProvider.hasNoSubscription(["organization": ["organization_type": type]]))
    }
    #expect(!ClaudeProvider.hasNoSubscription([:]))
    #expect(!ClaudeProvider.hasNoSubscription(["organization": ["subscription_status": "canceled"]]))
}

@Test func absentSubscriptionMetadataStillFetchesUsage() async throws {
    let credential = try #require(parseCredential("{\"claudeAiOauth\":{\"accessToken\":\"fixture\"}}", source: "test"))
    let provider = ClaudeProvider(credentials: FixedCredentialReader(credential: credential), transport: unusedTransport())
    let result = await provider.fetch(options: UsageProviderOptions(), now: now)
    #expect(result.snapshot.status.rawValue != "no_subscription")
}

@Test func subscriptionLossReplacesCachedQuotaAndResubscriptionRecovers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inactive = try #require(UsageStatus(rawValue: "no_subscription"))
    let state = ScriptedProviderState([.ok, inactive, .offline, .ok])
    let service = UsageService(providers: [ScriptedProvider(id: "claude", state: state)], cache: SnapshotCache(directory: directory), clock: { now })
    let request = UsageRequest(providers: ["claude"], refresh: true)
    #expect(await service.collect(request).providers[0].windows.count == 1)
    let lost = await service.collect(request)
    #expect(lost.providers[0].status == inactive)
    #expect(lost.providers[0].windows.isEmpty)
    #expect(!lost.providers[0].stale)
    let cached = await service.collect(UsageRequest(providers: ["claude"], cacheOnly: true))
    #expect(cached.providers[0].status == inactive)
    #expect(cached.providers[0].windows.isEmpty)
    #expect(await service.collect(request).providers[0].windows.isEmpty)
    #expect(await service.collect(request).providers[0].windows.count == 1)
}

@Test func newerCredentialFileOverridesStaleKeychainPlan() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let expiry = Int64(now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    let keychain = ClaudeCredential(accessToken: Secret("fixture", label: "test"), source: "keychain", expiresAtMilliseconds: expiry, subscriptionType: "pro", rateLimitTier: nil)
    let file = directory.appendingPathComponent(".credentials.json")
    for offset: Int64 in [-1000, 1000] {
        let raw = "{\"claudeAiOauth\":{\"accessToken\":\"fixture\",\"expiresAt\":\(expiry + offset),\"subscriptionType\":null}}"
        try raw.write(to: file, atomically: true, encoding: .utf8)
        let selected = preferNewerFileCredential(to: keychain, home: directory, now: now)
        #expect((selected.source == "credentials-file") == (offset > 0))
    }
    #expect(preferNewerFileCredential(to: keychain, home: directory, now: now.addingTimeInterval(7200)).source == "keychain")
}
