import LimitBarDomain
import Foundation

public struct UsageProviderOptions: Sendable {
    public let timeout: TimeInterval
    public let codexHome: URL?
    public let claudeHome: URL?
    /// A person clicked Refresh and is waiting on this reading. Nothing ever shows
    /// a dialog either way; this only lifts the throttle on launching `claude`.
    public let userInitiated: Bool

    public init(
        timeout: TimeInterval = 20,
        codexHome: URL? = nil,
        claudeHome: URL? = nil,
        userInitiated: Bool = false
    ) {
        self.timeout = timeout
        self.codexHome = codexHome
        self.claudeHome = claudeHome
        self.userInitiated = userInitiated
    }
}

public struct ProviderFetchResult: Sendable {
    public let snapshot: ProviderUsage
    public let retryAfter: Date?

    public init(snapshot: ProviderUsage, retryAfter: Date? = nil) {
        self.snapshot = snapshot
        self.retryAfter = retryAfter
    }
}

public protocol UsageProvider: Sendable {
    var id: String { get }
    func fetch(options: UsageProviderOptions, now: Date) async -> ProviderFetchResult
}

enum ProviderFailure {
    static func snapshot(
        provider: String,
        status: UsageStatus,
        source: String,
        message: String,
        now: Date,
        plan: String? = nil
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            status: status,
            plan: plan,
            source: source,
            fetchedAt: now,
            error: UsageIssue(code: status.rawValue, message: SecretScrubber.scrub(message))
        )
    }
}
