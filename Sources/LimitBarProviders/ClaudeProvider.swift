import LimitBarDomain
import Foundation

public struct HTTPTransportResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data
    public let finalURL: URL?

    public init(statusCode: Int, headers: [String: String], data: Data, finalURL: URL?) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
        self.finalURL = finalURL
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, timeout: TimeInterval, allowedHost: String) async throws -> HTTPTransportResponse
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowedHost: String

    init(allowedHost: String) { self.allowedHost = allowedHost }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == allowedHost.lowercased()
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public struct EphemeralHTTPTransport: HTTPTransport {
    public init() {}

    public func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        allowedHost: String
    ) async throws -> HTTPTransportResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let delegate = RedirectGuard(allowedHost: allowedHost)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPTransportResponse(
            statusCode: http.statusCode,
            headers: headers,
            data: data,
            finalURL: http.url
        )
    }
}

public struct ClaudeProvider: UsageProvider {
    public let id = "claude"
    public static let networkDestinations = ["api.anthropic.com"]

    private let credentials: any ClaudeCredentialReading
    private let transport: any HTTPTransport
    private let environment: [String: String]
    private let cli: any ClaudeCLIRunning
    private let gate: ClaudeCLIGate?

    public init(transport: any HTTPTransport = EphemeralHTTPTransport()) {
        self.credentials = DefaultClaudeCredentialReader()
        self.transport = transport
        self.environment = ProcessInfo.processInfo.environment
        self.cli = ClaudeCLIRunner()
        self.gate = ClaudeCLIGate()
    }

    /// `gate: nil` never launches `claude`, which is what tests that are not about
    /// the CLI want.
    init(
        credentials: any ClaudeCredentialReading,
        transport: any HTTPTransport,
        environment: [String: String] = [:],
        cli: any ClaudeCLIRunning = ClaudeCLIRunner(environment: [:]),
        gate: ClaudeCLIGate? = nil
    ) {
        self.credentials = credentials
        self.transport = transport
        self.environment = environment
        self.cli = cli
        self.gate = gate
    }

    /// Claude Code refreshes a token that is close to lapsing when it starts, so
    /// renewal is worth a launch slightly before the hard expiry.
    static let renewalMargin: TimeInterval = 5 * 60

    public func fetch(options: UsageProviderOptions, now: Date) async -> ProviderFetchResult {
        // At most one `claude` launch per fetch, whichever step needs it first.
        let launch = LaunchBudget(gate: gate, userInitiated: options.userInitiated)

        var credential: ClaudeCredential?
        var readError: CredentialReadError?
        do {
            credential = try await credentials.read(claudeHome: options.claudeHome, environment: environment)
        } catch {
            readError = error as? CredentialReadError ?? .missing
        }

        // Nobody else keeps the Keychain token alive for someone who works in the
        // desktop app, so a stale one is renewed by starting `claude`.
        if let current = credential, current.source == "keychain",
           current.isExpired(at: now.addingTimeInterval(Self.renewalMargin)),
           launch.claim() {
            if let renewed = await renew(options: options, now: now) { credential = renewed }
        }

        if let credential, !credential.isExpired(at: now) {
            let result = await requestUsage(credential: credential, options: options, now: now)
            guard result.snapshot.status == .authExpired else { return result }
            // Claude Code can rotate the token before the expiry it advertised.
            // The rotated one is usually already in the Keychain, so re-read first.
            await credentials.invalidate()
            if let reread = try? await credentials.read(claudeHome: options.claudeHome, environment: environment),
               !reread.accessToken.hasSameValue(as: credential.accessToken) {
                let retry = await requestUsage(credential: reread, options: options, now: now)
                if retry.snapshot.status != .authExpired { return retry }
            }
            if launch.claim(), let renewed = await renew(options: options, now: now) {
                let retry = await requestUsage(credential: renewed, options: options, now: now)
                if retry.snapshot.status != .authExpired { return retry }
            }
            return result
        }

        // No usable token: let Claude Code read its own login and show /usage.
        if launch.claim() || launch.usedThisFetch,
           let screen = await cli.readUsageScreen(timeout: 30) {
            let windows = ClaudeUsageScreen.parse(screen)
            if !windows.isEmpty {
                return ProviderFetchResult(snapshot: ProviderUsage(
                    provider: id,
                    status: .ok,
                    plan: credential?.subscriptionType.map { safeUpstreamText($0, maximumLength: 64) },
                    source: "claude-cli-usage",
                    fetchedAt: now,
                    windows: windows,
                    notes: ["read from claude /usage"]
                ))
            }
        }

        if let credential {
            return ProviderFetchResult(snapshot: ProviderFailure.snapshot(
                provider: id,
                status: .authExpired,
                source: "anthropic-oauth-usage",
                message: "Claude Code login has expired and could not be renewed; run: claude",
                now: now,
                plan: credential.subscriptionType
            ))
        }
        let status: UsageStatus = readError == .blocked ? .authBlocked : .authMissing
        return ProviderFetchResult(snapshot: ProviderFailure.snapshot(
            provider: id,
            status: status,
            source: "anthropic-oauth-usage",
            message: (readError ?? .missing).errorDescription ?? "Claude Code credentials not found; run: claude",
            now: now
        ))
    }

    /// Starts `claude` until its Keychain item is rewritten, then reads the result.
    private func renew(options: UsageProviderOptions, now: Date) async -> ClaudeCredential? {
        let before = claudeKeychainItemModified()
        _ = await cli.renewLogin(timeout: 20) {
            let current = claudeKeychainItemModified()
            return current != nil && current != before
        }
        await credentials.invalidate()
        guard let renewed = try? await credentials.read(claudeHome: options.claudeHome, environment: environment),
              !renewed.isExpired(at: now)
        else { return nil }
        return renewed
    }

    private func requestUsage(
        credential: ClaudeCredential,
        options: UsageProviderOptions,
        now: Date
    ) async -> ProviderFetchResult {
        let host = Self.networkDestinations[0]
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return ProviderFetchResult(snapshot: failure(.upstreamError, "invalid usage endpoint", now, credential))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("limitbar/1.0.0", forHTTPHeaderField: "User-Agent")
        credential.accessToken.withValue { token in
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Credential plan metadata can outlive a subscription or be absent.
        // The live profile is authoritative; only explicit free-account status
        // hides usage. Failed/unknown profiles fall through to the usage endpoint.
        var profileRequest = request
        profileRequest.url = URL(string: "https://api.anthropic.com/api/oauth/profile")
        if let profile = try? await transport.send(profileRequest, timeout: options.timeout, allowedHost: host),
           profile.finalURL?.scheme?.lowercased() == "https",
           profile.finalURL?.host?.lowercased() == host,
           (200..<300).contains(profile.statusCode),
           let payload = try? JSONSerialization.jsonObject(with: profile.data) as? [String: Any],
           Self.hasNoSubscription(payload) {
            return ProviderFetchResult(snapshot: ProviderUsage(
                provider: id, status: .noSubscription,
                source: "anthropic-oauth-usage", fetchedAt: now, windows: []
            ))
        }

        do {
            let response = try await transport.send(request, timeout: options.timeout, allowedHost: host)
            guard response.finalURL?.scheme?.lowercased() == "https",
                  response.finalURL?.host?.lowercased() == host
            else {
                return ProviderFetchResult(snapshot: failure(.upstreamError, "usage endpoint redirect was rejected", now, credential))
            }
            switch response.statusCode {
            case 200..<300:
                guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                    return ProviderFetchResult(snapshot: failure(
                        .upstreamError,
                        "usage endpoint returned an unparseable response",
                        now,
                        credential
                    ))
                }
                return ProviderFetchResult(snapshot: Self.parseUsage(object, credential: credential, now: now))
            case 401, 403:
                // The only way this request reports `authExpired`; callers read it
                // as "rejected" and renew.
                return ProviderFetchResult(snapshot: failure(
                    .authExpired,
                    "Claude Code credentials were rejected; run: claude",
                    now,
                    credential
                ))
            case 429:
                let retryAfter = Self.parseRetryAfter(response.headers["retry-after"], now: now)
                return ProviderFetchResult(
                    snapshot: failure(.rateLimited, "usage endpoint rate limited", now, credential),
                    retryAfter: retryAfter
                )
            default:
                // Deliberately discard the error body; only the typed status is surfaced.
                return ProviderFetchResult(snapshot: failure(
                    .upstreamError,
                    "usage endpoint returned HTTP \(response.statusCode)",
                    now,
                    credential
                ))
            }
        } catch let error as URLError {
            let message = error.code == .timedOut ? "request timed out" : "network unavailable"
            return ProviderFetchResult(snapshot: failure(.offline, message, now, credential))
        } catch {
            return ProviderFetchResult(snapshot: failure(.offline, "network unavailable", now, credential))
        }
    }

    private func failure(
        _ status: UsageStatus,
        _ message: String,
        _ now: Date,
        _ credential: ClaudeCredential
    ) -> ProviderUsage {
        ProviderFailure.snapshot(
            provider: id,
            status: status,
            source: "anthropic-oauth-usage",
            message: message,
            now: now,
            plan: credential.subscriptionType
        )
    }

    static func hasNoSubscription(_ profile: [String: Any]) -> Bool {
        guard let organization = profile["organization"] as? [String: Any],
              organization["organization_type"] as? String == "claude_free"
        else { return false }
        return true
    }

    static func parseUsage(
        _ payload: [String: Any],
        credential: ClaudeCredential? = nil,
        now: Date
    ) -> ProviderUsage {
        var windows: [UsageWindow] = []
        var notes: [String] = []
        if let limits = payload["limits"] as? [[String: Any]], !limits.isEmpty {
            for entry in limits {
                guard let kind = entry["kind"] as? String, !kind.isEmpty else { continue }
                let safeKind = safeUpstreamText(kind, maximumLength: 64)
                let classification = classifyClaudeLimit(safeKind, scope: entry["scope"])
                windows.append(UsageWindow(
                    key: classification.key,
                    label: classification.label,
                    windowMinutes: classification.minutes,
                    usedPercent: clampPercent(entry["percent"]),
                    remainingPercent: clampPercent(entry["percent"]).map { 100 - $0 },
                    resetsAt: parseDate(entry["resets_at"]),
                    resetsInSeconds: nil
                ))
                if let severity = entry["severity"] as? String,
                   severity == "warning" || severity == "critical" {
                    notes.append("\(safeKind): \(severity)")
                }
            }
        } else {
            let fields = [
                "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
                "seven_day_cowork", "seven_day_oauth_apps"
            ]
            let values = fields.compactMap { field -> Double? in
                guard let block = payload[field] as? [String: Any] else { return nil }
                return numeric(block["utilization"])
            }
            let nonzero = values.filter { $0 > 0 }
            let scale = !nonzero.isEmpty && nonzero.allSatisfy { $0 <= 1 } ? 100.0 : 1.0
            for field in fields {
                guard let block = payload[field] as? [String: Any],
                      let utilization = numeric(block["utilization"])
                else { continue }
                let classification = classifyClaudeLimit(field)
                let used = clampPercent(utilization * scale)
                windows.append(UsageWindow(
                    key: classification.key,
                    label: classification.label,
                    windowMinutes: classification.minutes,
                    usedPercent: used,
                    remainingPercent: used.map { 100 - $0 },
                    resetsAt: parseDate(block["resets_at"]),
                    resetsInSeconds: nil
                ))
            }
        }

        guard !windows.isEmpty else {
            return ProviderFailure.snapshot(
                provider: "claude",
                status: .upstreamError,
                source: "anthropic-oauth-usage",
                message: "unrecognised usage payload",
                now: now,
                plan: credential?.subscriptionType.map { safeUpstreamText($0, maximumLength: 64) }
            )
        }
        return ProviderUsage(
            provider: "claude",
            status: .ok,
            plan: credential?.subscriptionType.map { safeUpstreamText($0, maximumLength: 64) },
            source: "anthropic-oauth-usage",
            fetchedAt: now,
            windows: windows,
            spend: parseSpend(payload["spend"]),
            notes: notes
        )
    }

    static func parseRetryAfter(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

private func numeric(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    return value.isFinite ? value : nil
}

func clampPercent(_ value: Any?) -> Int? {
    guard let number = numeric(value) else { return nil }
    return max(0, min(100, Int(number.rounded())))
}

private func parseDate(_ value: Any?) -> Date? {
    UsageDate.parse(value as? String)
}

/// `weekly_scoped` is a separate weekly cap on one model (or surface), on top of
/// the all-models weekly. Which one lives in `scope`, e.g. `{"model": {"display_name": "Fable"}}`,
/// so name the window after it instead of the opaque kind.
private func scopedWeeklyName(_ scope: Any?) -> String? {
    guard let scope = scope as? [String: Any] else { return nil }
    for field in ["model", "surface"] {
        if let block = scope[field] as? [String: Any],
           let name = (block["display_name"] as? String) ?? (block["id"] as? String),
           !name.isEmpty {
            return safeUpstreamText(name, maximumLength: 24)
        }
        if let name = scope[field] as? String, !name.isEmpty {
            return safeUpstreamText(name, maximumLength: 24)
        }
    }
    return nil
}

private func classifyClaudeLimit(_ kind: String, scope: Any? = nil) -> (key: String, label: String, minutes: Int?) {
    if kind == "weekly_scoped" {
        guard let name = scopedWeeklyName(scope) else { return ("weekly_scoped", "Model 7d", nil) }
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return (slug.isEmpty ? "weekly_scoped" : "weekly_scoped_\(slug)", "\(name) 7d", nil)
    }
    let known: [String: (String, String, Int?)] = [
        "session": ("five_hour", "5h", 300),
        "five_hour": ("five_hour", "5h", 300),
        "weekly_all": ("weekly", "7d", nil),
        "seven_day": ("weekly", "7d", nil),
        "weekly_opus": ("weekly_opus", "7d Opus", nil),
        "seven_day_opus": ("weekly_opus", "7d Opus", nil),
        "weekly_sonnet": ("weekly_sonnet", "7d Sonnet", nil),
        "seven_day_sonnet": ("weekly_sonnet", "7d Sonnet", nil),
        "weekly_cowork": ("weekly_cowork", "7d Cowork", nil),
        "seven_day_cowork": ("weekly_cowork", "7d Cowork", nil),
        "weekly_oauth_apps": ("weekly_oauth_apps", "7d Apps", nil),
        "seven_day_oauth_apps": ("weekly_oauth_apps", "7d Apps", nil)
    ]
    if let value = known[kind] { return value }
    return (kind, String(kind.replacingOccurrences(of: "_", with: " ").prefix(16)), nil)
}

private func parseSpend(_ value: Any?) -> UsageSpend? {
    guard let spend = value as? [String: Any] else { return nil }
    func money(_ value: Any?) -> UsageMoney? {
        guard let raw = value as? [String: Any], let amount = numeric(raw["amount_minor"]) else { return nil }
        let exponent = numeric(raw["exponent"]).map(Int.init)
        return UsageMoney(
            amountMinor: Int(amount),
            currency: (raw["currency"] as? String).flatMap(validCurrency),
            exponent: exponent
        )
    }
    return UsageSpend(
        used: money(spend["used"]),
        limit: money(spend["limit"]),
        percent: clampPercent(spend["percent"]),
        enabled: spend["enabled"] as? Bool
    )
}

private func safeUpstreamText(_ value: String, maximumLength: Int) -> String {
    String(SecretScrubber.scrub(value).prefix(maximumLength))
}

private func validCurrency(_ value: String) -> String? {
    let upper = value.uppercased()
    guard upper.count == 3,
          upper.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) })
    else { return nil }
    return upper
}
