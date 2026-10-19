import LimitBarDomain
import Darwin
import Foundation

public protocol CodexRPCClient: Sendable {
    func readRateLimits(options: UsageProviderOptions) async throws -> Data
}

public enum CodexRPCError: LocalizedError, Sendable {
    case unavailable
    case timeout(String)
    case launch(String)
    case response(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "codex CLI not found"
        case .timeout(let stage): return "codex app-server \(stage) timed out"
        case .launch(let message): return "could not launch codex app-server: \(message)"
        case .response(let message): return message
        }
    }
}

private final class RPCMessageState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [[String: Any]] = []
    let initialized = DispatchSemaphore(value: 0)
    let receivedLimits = DispatchSemaphore(value: 0)

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            messages.append(object)
            if (object["id"] as? NSNumber)?.intValue == 1 { initialized.signal() }
            if (object["id"] as? NSNumber)?.intValue == 2 { receivedLimits.signal() }
        }
        lock.unlock()
    }

    func rateLimitResult() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        for message in messages.reversed() where (message["id"] as? NSNumber)?.intValue == 2 {
            if let error = message["error"] as? [String: Any] {
                throw CodexRPCError.response(error["message"] as? String ?? "codex app-server returned an error")
            }
            if let result = message["result"] as? [String: Any] {
                return try JSONSerialization.data(withJSONObject: result)
            }
        }
        throw CodexRPCError.response("codex app-server returned no rate limit result")
    }
}

public struct CodexAppServerClient: CodexRPCClient {
    public init() {}

    public func readRateLimits(options: UsageProviderOptions) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try readRateLimitsSynchronously(options: options)
        }.value
    }
}

private func readRateLimitsSynchronously(options: UsageProviderOptions) throws -> Data {
    let environment = ProcessInfo.processInfo.environment
    let executable = try resolveCodexBinary(environment: environment)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["app-server", "--listen", "stdio://"]
    var childEnvironment = environment
    if let codexHome = options.codexHome { childEnvironment["CODEX_HOME"] = codexHome.path }
    childEnvironment["PATH"] = augmentedExecutablePath(childEnvironment["PATH"], executable: executable)
    process.environment = childEnvironment

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    let state = RPCMessageState()
    output.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty { state.consume(data) }
    }
    // Always drain stderr concurrently. Its content is intentionally discarded.
    errors.fileHandleForReading.readabilityHandler = { handle in
        _ = handle.availableData
    }

    do {
        try process.run()
    } catch {
        throw CodexRPCError.launch(SecretScrubber.scrub(error.localizedDescription))
    }
    defer { terminateAndReap(process, input: input, output: output, errors: errors) }

    try writeRPC([
        "id": 1,
        "method": "initialize",
        "params": [
            "clientInfo": ["name": "limitbar", "title": "LimitBar", "version": "1.0.0"],
            "capabilities": ["experimentalApi": true, "requestAttestation": false]
        ]
    ], to: input.fileHandleForWriting)

    let handshakeBudget = max(2, options.timeout * 0.4)
    guard state.initialized.wait(timeout: .now() + handshakeBudget) == .success else {
        throw CodexRPCError.timeout("initialize")
    }
    try writeRPC(["id": 2, "method": "account/rateLimits/read"], to: input.fileHandleForWriting)
    let readBudget = max(2, options.timeout - handshakeBudget)
    guard state.receivedLimits.wait(timeout: .now() + readBudget) == .success else {
        throw CodexRPCError.timeout("rate limit read")
    }
    return try state.rateLimitResult()
}

private func writeRPC(_ object: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    try handle.write(contentsOf: data)
}

private func terminateAndReap(_ process: Process, input: Pipe, output: Pipe, errors: Pipe) {
    output.fileHandleForReading.readabilityHandler = nil
    errors.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if process.isRunning {
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }
    if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }
    if process.isRunning == false { process.waitUntilExit() }
    try? output.fileHandleForReading.close()
    try? errors.fileHandleForReading.close()
}

func resolveCodexBinary(
    environment: [String: String],
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    standardLocations: [String] = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
) throws -> URL {
    guard let binary = resolveCLIBinary(
        named: "codex",
        overrideVariable: "CODEX_BINARY",
        environment: environment,
        home: home,
        standardLocations: standardLocations
    ) else { throw CodexRPCError.unavailable }
    return binary
}

/// Finds a Node- or natively-installed CLI the way a login shell would, for an app
/// opened from Finder or at login that never ran the user's shell setup.
func resolveCLIBinary(
    named name: String,
    overrideVariable: String,
    environment: [String: String],
    home: URL,
    standardLocations: [String]
) -> URL? {
    let manager = FileManager.default
    if let override = environment[overrideVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
        let path = NSString(string: override).expandingTildeInPath
        if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
    }
    let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for directory in pathDirectories {
        let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
    }
    let candidates = standardLocations + [
        home.appendingPathComponent(".local/bin/\(name)").path,
        home.appendingPathComponent(".bun/bin/\(name)").path
    ]
    for candidate in candidates {
        let path = NSString(string: candidate).expandingTildeInPath
        if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
    }
    // Finder/login-item launches do not run fnm's shell initialization. Prefer
    // its default alias, then fall back to installed versions containing the CLI.
    var fnmRoots: [URL] = []
    for variable in ["FNM_DIR", "XDG_DATA_HOME"] {
        if let value = environment[variable], !value.isEmpty {
            let root = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            fnmRoots.append(variable == "XDG_DATA_HOME" ? root.appendingPathComponent("fnm") : root)
        }
    }
    fnmRoots += [".local/share/fnm", "Library/Application Support/fnm", ".fnm"]
        .map { home.appendingPathComponent($0) }
    for root in fnmRoots {
        let defaultBinary = root.appendingPathComponent("aliases/default/bin/\(name)")
        if manager.isExecutableFile(atPath: defaultBinary.path) { return defaultBinary }
        let versionsRoot = root.appendingPathComponent("node-versions")
        if let versions = try? manager.contentsOfDirectory(at: versionsRoot, includingPropertiesForKeys: nil) {
            for version in versions.sorted(by: {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }) {
                let binary = version.appendingPathComponent("installation/bin/\(name)")
                if manager.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
    }
    let nvm = home.appendingPathComponent(".nvm/versions/node")
    if let versions = try? manager.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
        for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let path = version.appendingPathComponent("bin/\(name)").path
            if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
    }
    return nil
}

func augmentedExecutablePath(_ existing: String?, executable: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let additions = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin"]
    var seen = Set<String>()
    // npm's Codex launcher uses /usr/bin/env node. Keep it paired with the Node
    // installation that owns it, even when another Node is on the GUI PATH.
    return ([executable.deletingLastPathComponent().path]
        + (existing ?? "").split(separator: ":").map(String.init) + additions)
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .joined(separator: ":")
}

public struct CodexProvider: UsageProvider {
    public let id = "codex"
    public static let networkDestinations: [String] = []
    private let client: any CodexRPCClient

    public init(client: any CodexRPCClient = CodexAppServerClient()) {
        self.client = client
    }

    public func fetch(options: UsageProviderOptions, now: Date) async -> ProviderFetchResult {
        do {
            let data = try await client.readRateLimits(options: options)
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ProviderFetchResult(snapshot: error(.upstreamError, "unrecognised codex rate limit payload", now))
            }
            return ProviderFetchResult(snapshot: Self.parseRateLimits(result, now: now))
        } catch let error as CodexRPCError {
            switch error {
            case .unavailable:
                return ProviderFetchResult(snapshot: self.error(.unsupported, error.localizedDescription, now))
            default:
                let message = error.localizedDescription
                let lowered = message.lowercased()
                let status: UsageStatus = lowered.contains("auth") || lowered.contains("login")
                    ? .authMissing : .upstreamError
                let safe = status == .authMissing
                    ? "codex is not logged in; run: codex login"
                    : "codex app-server returned an error"
                return ProviderFetchResult(snapshot: self.error(status, safe, now))
            }
        } catch {
            return ProviderFetchResult(snapshot: self.error(.upstreamError, error.localizedDescription, now))
        }
    }

    private func error(_ status: UsageStatus, _ message: String, _ now: Date) -> ProviderUsage {
        ProviderFailure.snapshot(
            provider: id,
            status: status,
            source: "codex-app-server",
            message: message,
            now: now
        )
    }

    public static func parseRateLimits(_ result: [String: Any], now: Date) -> ProviderUsage {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let source = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        guard let source else {
            return ProviderFailure.snapshot(
                provider: "codex",
                status: .upstreamError,
                source: "codex-app-server",
                message: "unrecognised codex rate limit payload",
                now: now
            )
        }
        var windows: [UsageWindow] = []
        var notes: [String] = []
        for (field, fallback) in [("primary", "primary"), ("secondary", "secondary")] {
            if let raw = source[field] as? [String: Any] {
                let minutes = integer(raw["windowDurationMins"])
                let classification = classifyWindow(minutes: minutes, fallback: fallback)
                let used = clampPercent(raw["usedPercent"])
                windows.append(UsageWindow(
                    key: classification.key,
                    label: classification.label,
                    windowMinutes: classification.minutes,
                    usedPercent: used,
                    remainingPercent: used.map { 100 - $0 },
                    resetsAt: epochDate(raw["resetsAt"]),
                    resetsInSeconds: nil
                ))
            } else if field == "secondary" {
                notes.append("secondary window not reported by upstream")
            }
        }
        var occurrences: [String: Int] = [:]
        windows = windows.map { window in
            occurrences[window.key, default: 0] += 1
            let count = occurrences[window.key, default: 1]
            guard count > 1 else { return window }
            return UsageWindow(
                key: "\(window.key)_\(count)", label: window.label,
                windowMinutes: window.windowMinutes, usedPercent: window.usedPercent,
                remainingPercent: window.remainingPercent, resetsAt: window.resetsAt
            )
        }
        let credits: UsageCredits?
        if let raw = source["credits"] as? [String: Any] {
            credits = UsageCredits(
                hasCredits: raw["hasCredits"] as? Bool,
                unlimited: raw["unlimited"] as? Bool,
                balance: (raw["balance"] as? String).flatMap(validBalance)
            )
        } else { credits = nil }
        if source["spendControlReached"] as? Bool == true { notes.append("spend control limit reached") }
        if let reached = source["rateLimitReachedType"] as? String, !reached.isEmpty {
            notes.append("rate limit reached: \(safeCodexText(reached))")
        }
        if let reset = result["rateLimitResetCredits"] as? [String: Any],
           let count = integer(reset["availableCount"]), count > 0 {
            notes.append("\(count) rate limit reset credit(s) available")
        }
        return ProviderUsage(
            provider: "codex",
            status: windows.contains { $0.usedPercent != nil } ? .ok : .unknown,
            plan: (source["planType"] as? String).map(safeCodexText),
            source: "codex-app-server",
            fetchedAt: now,
            windows: windows,
            credits: credits,
            notes: notes
        )
    }
}

private func safeCodexText(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    let filtered = value.unicodeScalars.filter { allowed.contains($0) }
    return String(String.UnicodeScalarView(filtered).prefix(64))
}

private func validBalance(_ value: String) -> String? {
    let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".,-"))
    guard !value.isEmpty, value.count <= 32,
          value.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else { return nil }
    return value
}

private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.intValue
}

private func epochDate(_ value: Any?) -> Date? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let seconds = number.doubleValue
    guard seconds > 0, seconds <= 4_102_444_800 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func classifyWindow(minutes: Int?, fallback: String) -> (key: String, label: String, minutes: Int?) {
    guard let minutes else { return (fallback, fallback == "primary" ? "P" : "S", nil) }
    let known: [Int: (String, String)] = [
        60: ("hourly", "1h"), 300: ("five_hour", "5h"), 1440: ("daily", "24h"),
        10080: ("weekly", "7d"), 43200: ("monthly", "30d")
    ]
    if let value = known[minutes] { return (value.0, value.1, minutes) }
    let label = minutes % 1440 == 0 ? "\(minutes / 1440)d"
        : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    return ("window_\(minutes)m", label, minutes)
}
