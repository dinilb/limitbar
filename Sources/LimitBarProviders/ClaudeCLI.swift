import LimitBarDomain
import Darwin
import Foundation

/// Runs the user's own `claude` in a hidden pseudo-terminal.
///
/// Claude Code is the only process that can keep its login alive: it refreshes the
/// access token in `Claude Code-credentials` when it starts, and nothing else does.
/// Someone who lives in the desktop app (which hands its sessions a separate token)
/// can go days without starting the terminal CLI, and the Keychain token goes stale
/// in eight hours. Starting `claude` for a few seconds renews it, with no dialog,
/// because Claude Code reads and writes its own item through `/usr/bin/security`.
///
/// The same session can also type `/usage` and read the screen, which needs no
/// credential handling on our side at all. That is the fallback when the token
/// cannot be read or renewed.
protocol ClaudeCLIRunning: Sendable {
    /// Start `claude` and let it refresh its login. Returns when `renewed` reports
    /// true or the timeout passes; the return value is `renewed`'s last answer.
    func renewLogin(timeout: TimeInterval, renewed: @escaping @Sendable () -> Bool) async -> Bool

    /// Start `claude`, run `/usage`, and return the visible text, or nil.
    func readUsageScreen(timeout: TimeInterval) async -> String?
}

struct ClaudeCLIRunner: ClaudeCLIRunning {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func renewLogin(timeout: TimeInterval, renewed: @escaping @Sendable () -> Bool) async -> Bool {
        let environment = self.environment
        return await Task.detached(priority: .utility) {
            guard let session = ClaudePTYSession(environment: environment) else { return false }
            defer { session.finish() }
            let deadline = Date().addingTimeInterval(timeout)
            var lastCheck = Date.distantPast
            while Date() < deadline, session.isRunning {
                session.pump(for: 0.2)
                if Date().timeIntervalSince(lastCheck) >= 0.5 {
                    lastCheck = Date()
                    if renewed() { return true }
                }
            }
            return renewed()
        }.value
    }

    func readUsageScreen(timeout: TimeInterval) async -> String? {
        let environment = self.environment
        return await Task.detached(priority: .utility) {
            guard let session = ClaudePTYSession(environment: environment) else { return nil }
            defer { session.finish() }
            let deadline = Date().addingTimeInterval(timeout)
            var trustAnswered = false
            var sentAt: Date?
            while Date() < deadline, session.isRunning {
                session.pump(for: 0.2)
                let screen = session.screen
                if sentAt == nil {
                    // First run in the probe folder asks whether to trust it. Pick
                    // "Yes" so Claude Code records that itself, once.
                    if !trustAnswered, screen.localizedCaseInsensitiveContains("trust this folder") {
                        session.send("\u{1B}[B")
                        session.pump(for: 0.3)
                        session.send("\r")
                        trustAnswered = true
                        session.clearScreen()
                        continue
                    }
                    // Type once the UI has started and gone quiet.
                    if session.age > 2, session.quietFor > 1 {
                        session.clearScreen()
                        session.send("/usage")
                        session.pump(for: 0.8)
                        session.send("\r")
                        sentAt = Date()
                    }
                    continue
                }
                if screen.contains("Failed to load usage data") { return nil }
                if ClaudeUsageScreen.hasReadings(screen) {
                    // Let the rest of the panel finish drawing.
                    session.pump(for: 0.7)
                    return session.screen
                }
            }
            return nil
        }.value
    }
}

/// One `claude` process attached to a pseudo-terminal we own.
private final class ClaudePTYSession {
    private let process = Process()
    private let master: Int32
    private var raw = Data()
    private let started = Date()
    private var lastOutput = Date()
    private var probeFolder: URL

    init?(environment: [String: String]) {
        guard let binary = resolveClaudeBinary(environment: environment) else { return nil }
        probeFolder = claudeProbeFolder()
        try? FileManager.default.createDirectory(at: probeFolder, withIntermediateDirectories: true)

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        self.master = master
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        process.executableURL = binary
        process.arguments = [
            // No MCP servers, hooks or plugins' startup scripts: this session only
            // exists to start up (and maybe show /usage), never to do work.
            "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true}"#
        ]
        process.currentDirectoryURL = probeFolder
        process.environment = claudeChildEnvironment(environment, executable: binary)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do {
            try process.run()
        } catch {
            close(slave)
            close(master)
            return nil
        }
        close(slave)
    }

    var isRunning: Bool { process.isRunning }
    var age: TimeInterval { Date().timeIntervalSince(started) }
    var quietFor: TimeInterval { Date().timeIntervalSince(lastOutput) }
    var screen: String { ClaudeUsageScreen.plainText(raw) }

    func clearScreen() { raw.removeAll() }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
    }

    func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        repeat {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard poll(&descriptor, 1, Int32(min(remaining, 0.2) * 1_000)) > 0 else { continue }
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                raw.append(contentsOf: buffer[0..<count])
                lastOutput = Date()
                // A runaway screen should never grow without bound.
                if raw.count > 2_000_000 { raw.removeFirst(raw.count - 1_000_000) }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                return
            }
        } while Date() < deadline
    }

    func finish() {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { pump(for: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        close(master)
        removeProbeTranscripts()
    }

    /// Keep these throwaway sessions out of the user's `--resume` list.
    private func removeProbeTranscripts() {
        let home = defaultClaudeHome(environment: ProcessInfo.processInfo.environment)
        let encoded = String(probeFolder.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let folder = home.appendingPathComponent("projects/\(encoded)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "jsonl" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

func claudeProbeFolder() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LimitBar/ClaudeProbe", isDirectory: true)
}

/// The child must sign in the way a terminal `claude` would, from its own Keychain
/// item. Inherited Claude Code session variables (present when this runs inside a
/// Claude Code session, including the desktop app's) would make it use that
/// session's token instead and leave the Keychain one stale.
func claudeChildEnvironment(_ environment: [String: String], executable: URL) -> [String: String] {
    var child = environment.filter { key, _ in
        !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("ANTHROPIC_"))
    }
    child["TERM"] = "xterm-256color"
    child["PATH"] = augmentedExecutablePath(environment["PATH"], executable: executable)
    return child
}

func resolveClaudeBinary(
    environment: [String: String],
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL? {
    resolveCLIBinary(
        named: "claude",
        overrideVariable: "CLAUDE_BINARY",
        environment: environment,
        home: home,
        standardLocations: [
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
    )
}

/// Throttles background `claude` launches across the app and the CLI.
///
/// A launch costs a few seconds and touches the user's Claude Code state, so a
/// background poll gets at most one per window. A person clicking Refresh is not
/// throttled: that click is the request.
struct ClaudeCLIGate: Sendable {
    static let backgroundInterval: TimeInterval = 15 * 60
    let marker: URL

    init(cacheDirectory: URL = SnapshotCache.defaultDirectory(environment: ProcessInfo.processInfo.environment)) {
        marker = cacheDirectory.appendingPathComponent("claude-cli-launch")
    }

    /// Claims a launch if one is allowed now.
    func claim(userInitiated: Bool, now: Date = Date()) -> Bool {
        if !userInitiated,
           let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
           let last = attributes[.modificationDate] as? Date,
           now.timeIntervalSince(last) < Self.backgroundInterval,
           now >= last {
            return false
        }
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: marker.path)
        return true
    }
}

/// One fetch gets at most one `claude` launch, claimed by whichever step needs it
/// first: renewing a stale token, renewing after a rejection, or reading `/usage`.
final class LaunchBudget: @unchecked Sendable {
    private let gate: ClaudeCLIGate?
    private let userInitiated: Bool
    private(set) var usedThisFetch = false
    private var claimed = false

    init(gate: ClaudeCLIGate?, userInitiated: Bool) {
        self.gate = gate
        self.userInitiated = userInitiated
    }

    func claim() -> Bool {
        guard !claimed, let gate else { return false }
        claimed = true
        usedThisFetch = gate.claim(userInitiated: userInitiated)
        return usedThisFetch
    }
}

/// Reads the `/usage` panel Claude Code draws in a terminal.
enum ClaudeUsageScreen {
    /// Terminal output with escape sequences removed. Cursor-forward moves become
    /// spaces, since Claude Code draws gaps that way rather than with spaces.
    static func plainText(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(
            of: #"\x{1B}\[(\d*)C"#, with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)|\x{1B}[()][A-Za-z0-9]|\x{1B}[=>78]"#,
            with: " ", options: .regularExpression
        )
        return text.replacingOccurrences(of: "\r", with: "\n")
    }

    static func hasReadings(_ text: String) -> Bool {
        !parse(text).isEmpty
    }

    /// Each "Current session" / "Current week (...)" heading followed by its
    /// "N% used" or "N% left". Reset times are free text in the user's locale
    /// ("Resets 11am", "Dec 23 at 4:00PM"), so they are left unknown rather than
    /// guessed.
    static func parse(_ text: String) -> [UsageWindow] {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let pattern = try? NSRegularExpression(
            pattern: #"Current (session|week(?: \(([^)]{1,40})\))?)(?:(?!Current ).){0,200}?(\d{1,3}) ?% ?(used|left)"#,
            options: [.caseInsensitive]
        ) else { return [] }
        var windows: [UsageWindow] = []
        var seen = Set<String>()
        let range = NSRange(flat.startIndex..., in: flat)
        for match in pattern.matches(in: flat, range: range) {
            guard let kindRange = Range(match.range(at: 1), in: flat),
                  let numberRange = Range(match.range(at: 3), in: flat),
                  let modeRange = Range(match.range(at: 4), in: flat),
                  let number = Int(flat[numberRange]), number <= 100
            else { continue }
            let kind = flat[kindRange].lowercased()
            let qualifier = Range(match.range(at: 2), in: flat).map { String(flat[$0]) }
            let used = flat[modeRange].lowercased() == "used" ? number : 100 - number

            let key: String
            let label: String
            let minutes: Int?
            if kind == "session" {
                (key, label, minutes) = ("five_hour", "5h", 300)
            } else if let qualifier, !qualifier.lowercased().contains("all") {
                let name = qualifier
                    .replacingOccurrences(of: #"(?i)\s*only\s*$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let safe = String(SecretScrubber.scrub(name).prefix(24))
                let slug = safe.lowercased().filter { $0.isLetter || $0.isNumber }
                (key, label, minutes) = (slug.isEmpty ? "weekly_scoped" : "weekly_scoped_\(slug)", "\(safe) 7d", nil)
            } else {
                (key, label, minutes) = ("weekly", "7d", nil)
            }
            guard seen.insert(key).inserted else { continue }
            windows.append(UsageWindow(
                key: key,
                label: label,
                windowMinutes: minutes,
                usedPercent: used,
                remainingPercent: 100 - used,
                resetsAt: nil,
                resetsInSeconds: nil
            ))
        }
        return windows
    }
}
