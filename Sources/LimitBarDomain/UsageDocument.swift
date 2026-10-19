import Foundation

/// The token-free normalized document shared by the app, CLI, and widget.
public struct UsageDocument: Codable, Equatable, Sendable {
    /// The schema this build understands. A newer CLI is tolerated (unknown
    /// fields are ignored); an older one is flagged rather than mis-rendered.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date?
    public let ok: Bool
    public let providers: [ProviderUsage]
    public let tightest: TightestWindow?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case ok
        case providers
        case tightest
    }

    public init(
        schemaVersion: Int = UsageDocument.supportedSchemaVersion,
        generatedAt: Date?,
        ok: Bool,
        providers: [ProviderUsage],
        tightest: TightestWindow? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.ok = ok
        self.providers = providers
        self.tightest = tightest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        generatedAt = UsageDate.parse(try container.decodeIfPresent(String.self, forKey: .generatedAt))
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        providers = try container.decodeIfPresent([ProviderUsage].self, forKey: .providers) ?? []
        tightest = try container.decodeIfPresent(TightestWindow.self, forKey: .tightest)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(UsageDate.format(generatedAt), forKey: .generatedAt)
        try container.encode(ok, forKey: .ok)
        try container.encode(providers, forKey: .providers)
        try container.encode(tightest, forKey: .tightest)
    }

    public var isSchemaSupported: Bool {
        schemaVersion == Self.supportedSchemaVersion
    }

    public static let empty = UsageDocument(generatedAt: nil, ok: false, providers: [])

    /// Providers in the order every surface displays them: Claude Code first,
    /// then everything else as the CLI reported it.
    ///
    /// The CLI's own order is whichever provider answered first, which is
    /// usually Codex. The menu bar has always pinned Claude to the leading
    /// column; this is the same rule, stated once, so the popover and the
    /// widget cannot drift away from it.
    public var providersInDisplayOrder: [ProviderUsage] {
        // Missing credentials or an unavailable CLI mean the provider is not
        // configured. Keep transient failures visible so they can be resolved.
        let visible = providers.filter {
            ![UsageStatus.authMissing, .unsupported, .noSubscription].contains($0.status)
        }
        let claude = visible.filter { $0.provider == MenuBarStatus.claudeProviderID }
        return claude + visible.filter { $0.provider != MenuBarStatus.claudeProviderID }
    }

    public static func decode(from data: Data) throws -> UsageDocument {
        try JSONDecoder().decode(UsageDocument.self, from: data)
    }

    public static func make(providers: [ProviderUsage], generatedAt: Date = Date()) -> UsageDocument {
        let usable = !providers.isEmpty && providers.allSatisfy { $0.status == .ok && !$0.stale }
        let candidates = providers.compactMap { provider -> (ProviderUsage, UsageWindow)? in
            provider.tightestWindow.map { (provider, $0) }
        }
        let tightest = candidates.min {
            ($0.1.remainingPercent ?? 0) < ($1.1.remainingPercent ?? 0)
        }.map { provider, window in
            TightestWindow(
                provider: provider.provider,
                windowKey: window.key,
                remainingPercent: window.remainingPercent,
                resetsAt: window.resetsAt
            )
        }
        return UsageDocument(
            generatedAt: generatedAt,
            ok: usable,
            providers: providers.map { $0.rebased(at: generatedAt) },
            tightest: tightest
        )
    }
}

public struct TightestWindow: Codable, Equatable, Sendable {
    public let provider: String
    public let windowKey: String
    public let remainingPercent: Int?
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case provider
        case windowKey = "window_key"
        case remainingPercent = "remaining_percent"
        case resetsAt = "resets_at"
    }

    public init(provider: String, windowKey: String, remainingPercent: Int?, resetsAt: Date?) {
        self.provider = provider
        self.windowKey = windowKey
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        windowKey = try container.decodeIfPresent(String.self, forKey: .windowKey) ?? "unknown"
        remainingPercent = try container.decodeIfPresent(Int.self, forKey: .remainingPercent)
        resetsAt = UsageDate.parse(try container.decodeIfPresent(String.self, forKey: .resetsAt))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(windowKey, forKey: .windowKey)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encode(UsageDate.format(resetsAt), forKey: .resetsAt)
    }
}

/// Per-provider outcome. Mirrors `the original schema`.
public enum UsageStatus: String, Codable, Equatable, Sendable {
    case ok
    case unknown
    case authMissing = "auth_missing"
    case authExpired = "auth_expired"
    /// The credential exists but could not be read without a dialog, and the
    /// `claude` fallback did not produce a reading either.
    case authBlocked = "auth_blocked"
    case rateLimited = "rate_limited"
    case offline
    case upstreamError = "upstream_error"
    case unsupported
    case noSubscription = "no_subscription"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // A status this build has never heard of degrades to `unknown` rather
        // than failing the whole document.
        self = UsageStatus(rawValue: raw) ?? .unknown
    }

    /// Short text for the menu-bar grid when there is no number to show.
    public var badge: String {
        switch self {
        case .ok, .unknown: return "?"
        case .authMissing, .authExpired, .authBlocked: return "!"
        case .rateLimited: return "~"
        case .offline: return "×"
        case .upstreamError: return "!"
        case .unsupported, .noSubscription: return "–"
        }
    }

    /// What the user should actually do about it.
    public func remedy(for provider: String) -> String? {
        switch self {
        case .authMissing:
            return provider == "codex" ? "Run `codex login`." : "Run `claude` once to sign in."
        case .authExpired:
            // Refresh launches `claude` to renew the login, so it is the first thing
            // to try; a login Claude Code itself cannot renew needs `claude` run by hand.
            return provider == "codex" ? "Run `codex login`." : "Click Refresh, or run `claude` once to refresh its login."
        case .authBlocked:
            return "Keychain access was not available; click Refresh to read usage through `claude`."
        case .rateLimited:
            return "The provider is rate limiting; showing the last known values."
        case .offline:
            return "No network connection."
        case .noSubscription:
            return "No active subscription."
        case .unsupported:
            return provider == "codex" ? "The `codex` CLI was not found." : "Not available."
        case .ok, .unknown, .upstreamError:
            return nil
        }
    }
}

public struct UsageIssue: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct UsageCredits: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    public init(hasCredits: Bool?, unlimited: Bool?, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasCredits, forKey: .hasCredits)
        try container.encode(unlimited, forKey: .unlimited)
        try container.encode(balance, forKey: .balance)
    }
}

public struct UsageMoney: Codable, Equatable, Sendable {
    public let amountMinor: Int
    public let currency: String?
    public let exponent: Int?

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency
        case exponent
    }

    public init(amountMinor: Int, currency: String?, exponent: Int?) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.exponent = exponent
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amountMinor, forKey: .amountMinor)
        try container.encode(currency, forKey: .currency)
        try container.encode(exponent, forKey: .exponent)
    }
}

public struct UsageSpend: Codable, Equatable, Sendable {
    public let used: UsageMoney?
    public let limit: UsageMoney?
    public let percent: Int?
    public let enabled: Bool?

    public init(used: UsageMoney?, limit: UsageMoney?, percent: Int?, enabled: Bool?) {
        self.used = used
        self.limit = limit
        self.percent = percent
        self.enabled = enabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "used": used.map(SpendValue.money) ?? .null,
            "limit": limit.map(SpendValue.money) ?? .null,
            "percent": percent.map(SpendValue.integer) ?? .null,
            "enabled": enabled.map(SpendValue.boolean) ?? .null
        ])
    }

    private enum SpendValue: Encodable {
        case money(UsageMoney), integer(Int), boolean(Bool), null
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .money(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }
}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let windowMinutes: Int?
    public let usedPercent: Int?
    public let remainingPercent: Int?
    public let resetsAt: Date?
    public let resetsInSeconds: Int?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case windowMinutes = "window_minutes"
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case resetsAt = "resets_at"
        case resetsInSeconds = "resets_in_seconds"
    }

    public init(
        key: String,
        label: String,
        windowMinutes: Int? = nil,
        usedPercent: Int? = nil,
        remainingPercent: Int? = nil,
        resetsAt: Date? = nil,
        resetsInSeconds: Int? = nil
    ) {
        self.key = key
        self.label = label
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.resetsInSeconds = resetsInSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? "unknown"
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? "?"
        windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        usedPercent = try container.decodeIfPresent(Int.self, forKey: .usedPercent)
        remainingPercent = try container.decodeIfPresent(Int.self, forKey: .remainingPercent)
        resetsAt = UsageDate.parse(try container.decodeIfPresent(String.self, forKey: .resetsAt))
        resetsInSeconds = try container.decodeIfPresent(Int.self, forKey: .resetsInSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(label, forKey: .label)
        try container.encode(windowMinutes, forKey: .windowMinutes)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encode(UsageDate.format(resetsAt), forKey: .resetsAt)
        try container.encode(resetsInSeconds, forKey: .resetsInSeconds)
    }

    /// Nominal length of a Claude Code / Codex session bucket.
    public static let fiveHourMinutes = 300

    /// Whether this is the five-hour session window.
    ///
    /// Identity comes from the duration, exactly as it does in the CLI's
    /// `classify_window` — never from the window's position in the list. A
    /// window that declares some other duration is not a five-hour window no
    /// matter what it is keyed as, so a free-plan 30-day bucket can never be
    /// drawn under the `5h` label.
    public var isFiveHour: Bool {
        if let windowMinutes { return windowMinutes == Self.fiveHourMinutes }
        return key == "five_hour"
    }

    /// Remaining quota as text. Unknown renders as `?`, never as a number.
    public var remainingText: String {
        guard let remainingPercent else { return "?" }
        return "\(remainingPercent)"
    }

    /// Remaining quota for a compact readout: `83%`, or `?` when unknown.
    public var remainingBadge: String {
        guard let remainingPercent else { return "?" }
        return "\(remainingPercent)%"
    }

    /// Countdown to reset, floored to a single unit: `4h`, `35m`, `now`.
    public func countdownText(now: Date = Date()) -> String {
        let seconds: Int
        if let resetsAt {
            seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        } else if let resetsInSeconds {
            seconds = max(0, resetsInSeconds)
        } else {
            return "?"
        }

        let minutes = seconds / 60
        if minutes < 1 { return "now" }
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d" }
        if hours >= 1 { return "\(hours)h" }
        return "\(minutes)m"
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable, Identifiable {
    public let provider: String
    public let status: UsageStatus
    public let plan: String?
    public let source: String?
    public let fetchedAt: Date?
    public let stale: Bool
    public let windows: [UsageWindow]
    public let credits: UsageCredits?
    public let spend: UsageSpend?
    public let notes: [String]
    public let error: UsageIssue?

    public var id: String { provider }

    enum CodingKeys: String, CodingKey {
        case provider
        case status
        case plan
        case source
        case fetchedAt = "fetched_at"
        case stale
        case windows
        case credits
        case spend
        case notes
        case error
    }

    public init(
        provider: String,
        status: UsageStatus,
        plan: String? = nil,
        source: String? = nil,
        fetchedAt: Date? = nil,
        stale: Bool = false,
        windows: [UsageWindow] = [],
        credits: UsageCredits? = nil,
        spend: UsageSpend? = nil,
        notes: [String] = [],
        error: UsageIssue? = nil
    ) {
        self.provider = provider
        self.status = status
        self.plan = plan
        self.source = source
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.windows = windows
        self.credits = credits
        self.spend = spend
        self.notes = notes
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        status = try container.decodeIfPresent(UsageStatus.self, forKey: .status) ?? .unknown
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        fetchedAt = UsageDate.parse(try container.decodeIfPresent(String.self, forKey: .fetchedAt))
        stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        windows = try container.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        credits = try container.decodeIfPresent(UsageCredits.self, forKey: .credits)
        spend = try container.decodeIfPresent(UsageSpend.self, forKey: .spend)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        error = try container.decodeIfPresent(UsageIssue.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(plan, forKey: .plan)
        try container.encode(source, forKey: .source)
        try container.encode(UsageDate.format(fetchedAt), forKey: .fetchedAt)
        try container.encode(stale, forKey: .stale)
        try container.encode(windows, forKey: .windows)
        try container.encode(credits, forKey: .credits)
        try container.encodeIfPresent(spend, forKey: .spend)
        try container.encode(notes, forKey: .notes)
        try container.encode(error, forKey: .error)
    }

    /// Two-letter code used in the menu bar. `Cx` = Codex, `Cl` = Claude.
    public var compactCode: String {
        switch provider {
        case "codex": return "Cx"
        case "claude": return "Cl"
        default: return String(provider.prefix(2)).capitalized
        }
    }

    public var displayName: String {
        switch provider {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        default: return provider.capitalized
        }
    }

    /// The window closest to exhaustion. Windows with no reading never win —
    /// an unknown must not masquerade as "plenty left" or "nearly out".
    public var tightestWindow: UsageWindow? {
        windows
            .filter { $0.remainingPercent != nil }
            .min { ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0) }
    }

    /// The five-hour session window, if this provider reports one. Returns nil
    /// rather than substituting a longer window — see `UsageWindow.isFiveHour`.
    public var fiveHourWindow: UsageWindow? {
        windows.first { $0.isFiveHour }
    }

    /// The tightest window that is *not* the five-hour one. The menu bar pins
    /// the five-hour reading, so this is what it needs in order to still warn
    /// about a weekly or monthly bucket running out.
    public var tightestNonFiveHourWindow: UsageWindow? {
        windows
            .filter { !$0.isFiveHour && $0.remainingPercent != nil }
            .min { ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0) }
    }

    public var isUsable: Bool {
        tightestWindow != nil
    }

    public func rebased(at now: Date) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            status: status,
            plan: plan,
            source: source,
            fetchedAt: fetchedAt,
            stale: stale,
            windows: windows.map { window in
                UsageWindow(
                    key: window.key,
                    label: window.label,
                    windowMinutes: window.windowMinutes,
                    usedPercent: window.usedPercent,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    resetsInSeconds: window.resetsAt.map { max(0, Int($0.timeIntervalSince(now))) }
                        ?? window.resetsInSeconds
                )
            },
            credits: credits,
            spend: spend,
            notes: notes,
            error: error
        )
    }

    public func withoutSpend() -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            status: status,
            plan: plan,
            source: source,
            fetchedAt: fetchedAt,
            stale: stale,
            windows: windows,
            credits: credits,
            spend: nil,
            notes: notes,
            error: error
        )
    }
}

/// Severity buckets shared by the menu bar and the widget so both colour the
/// same number the same way.
/// How alarming a remaining percentage is.
///
/// Four bands rather than three, because the menu bar draws every healthy
/// reading in one flat colour: the ramp is the only thing that distinguishes
/// "plenty left" from "about to be cut off", so it has to earn its steps.
/// Yellow is a nudge, orange means plan around it, red means it is nearly gone.
public enum UsageSeverity: String, Sendable {
    case critical
    case warning
    case caution
    case normal
    case unknown

    public init(remainingPercent: Int?) {
        guard let remainingPercent else {
            self = .unknown
            return
        }
        switch remainingPercent {
        case ..<5: self = .critical
        case ..<15: self = .warning
        case ..<30: self = .caution
        default: self = .normal
        }
    }
}

/// ISO-8601 helpers. The CLI always emits second-precision UTC with a `Z`
/// suffix; we still accept fractional seconds in case a future CLI emits them.
public enum UsageDate {
    // ISO8601DateFormatter is not Sendable in Swift 6. Build short-lived
    // formatters so decoding is safe from any task/actor without shared state.
    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    public static func format(_ value: Date?) -> String? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: value)
    }
}
