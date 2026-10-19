import Foundation

let claudeKeychainService = "Claude Code-credentials"

struct ClaudeCredential: Sendable {
    let accessToken: Secret
    let source: String
    let expiresAtMilliseconds: Int64?
    let subscriptionType: String?
    let rateLimitTier: String?

    func isExpired(at date: Date) -> Bool {
        guard let expiresAtMilliseconds else { return false }
        return Int64(date.timeIntervalSince1970 * 1_000) >= expiresAtMilliseconds
    }
}

enum CredentialReadError: LocalizedError, Sendable {
    /// The item exists but `security` could not read it without a dialog.
    case blocked
    case missing

    var errorDescription: String? {
        switch self {
        case .blocked:
            return "Claude Code's Keychain login could not be read silently."
        case .missing:
            return "Claude Code credentials not found; run: claude"
        }
    }
}

protocol ClaudeCredentialReading: Sendable {
    func read(claudeHome: URL?, environment: [String: String]) async throws -> ClaudeCredential

    /// Discard any cached credential because upstream rejected the last one, or
    /// because Claude Code has just been asked to renew it.
    func invalidate() async
}

extension ClaudeCredentialReading {
    /// Readers that hold nothing have nothing to drop.
    func invalidate() async {}
}

/// Holds the last good Keychain credential so a long-running app reads the Keychain
/// once per token lifetime instead of once per refresh.
///
/// Only Keychain-sourced credentials are worth caching: the file and environment
/// sources are already free to re-read, and a credential with no known expiry has no
/// point at which we could safely retire it.
final class ClaudeCredentialCache: @unchecked Sendable {
    /// Claude Code rotates tokens well before they lapse. Retiring ours a minute early
    /// keeps us from starting a request with a token that dies in flight.
    static let margin: TimeInterval = 60

    private let lock = NSLock()
    private var stored: ClaudeCredential?

    func value(at date: Date) -> ClaudeCredential? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored, !stored.isExpired(at: date.addingTimeInterval(Self.margin)) else { return nil }
        return stored
    }

    func store(_ credential: ClaudeCredential) {
        guard credential.source == "keychain", credential.expiresAtMilliseconds != nil else { return }
        lock.lock()
        stored = credential
        lock.unlock()
    }

    func clear() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}

/// Reads Claude Code's login without ever putting a dialog on screen.
///
/// The app never queries `Claude Code-credentials` itself. That item is a legacy
/// login-keychain password whose ACL Claude Code rewrites on every token rotation,
/// so any grant this app earns ("Always Allow" included) is revoked within hours
/// and the next in-process read asks for the login password again. Claude Code
/// writes the item through `/usr/bin/security`, which keeps that tool on the ACL
/// across rotations, so reading through it is silent. When it is not, the answer
/// is to let `claude` do the work (see `ClaudeCLI.swift`), never to prompt.
struct DefaultClaudeCredentialReader: ClaudeCredentialReading {
    private let cache: ClaudeCredentialCache

    init(cache: ClaudeCredentialCache = ClaudeCredentialCache()) {
        self.cache = cache
    }

    func invalidate() async { cache.clear() }

    func read(claudeHome: URL?, environment: [String: String]) async throws -> ClaudeCredential {
        let home = claudeHome ?? defaultClaudeHome(environment: environment)
        if let cached = cache.value(at: Date()) {
            return preferNewerFileCredential(to: cached, home: home)
        }

        let cache = self.cache
        return try await Task.detached(priority: .utility) {
            var failure = CredentialReadError.missing
            switch readClaudeKeychainItem() {
            case .success(let raw):
                if let credential = parseCredential(raw, source: "keychain") {
                    cache.store(credential)
                    return preferNewerFileCredential(to: credential, home: home)
                }
            case .failure(let error):
                failure = error
            }

            if let raw = try? String(contentsOf: home.appendingPathComponent(".credentials.json"), encoding: .utf8),
               let credential = parseCredential(raw, source: "credentials-file") {
                return credential
            }

            if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                return ClaudeCredential(
                    accessToken: Secret(token, label: "claude-oauth-env"),
                    source: "environment",
                    expiresAtMilliseconds: nil,
                    subscriptionType: nil,
                    rateLimitTier: nil
                )
            }
            throw failure
        }.value
    }
}

/// The secret, read through `/usr/bin/security`. A run that has not finished in a
/// few seconds is waiting on a dialog, so it is killed: that dismisses the dialog
/// and reports `.blocked`.
private func readClaudeKeychainItem() -> Result<String, CredentialReadError> {
    if let raw = runSecurity(["find-generic-password", "-s", claudeKeychainService, "-w"], timeout: 5) {
        return .success(raw)
    }
    return claudeKeychainItemModified() == nil ? .failure(.missing) : .failure(.blocked)
}

/// When Claude Code last wrote its Keychain item, read from the item's attributes
/// only. That never touches the secret, so it never needs authorization; it is how
/// a renewal is noticed without reading the token over and over.
func claudeKeychainItemModified() -> String? {
    guard let attributes = runSecurity(["find-generic-password", "-s", claudeKeychainService], timeout: 5) else {
        return nil
    }
    return attributes
        .split(separator: "\n")
        .first { $0.contains("\"mdat\"") }
        .map(String.init)
}

private func runSecurity(_ arguments: [String], timeout: TimeInterval) -> String? {
    let executable = URL(fileURLWithPath: "/usr/bin/security")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    let drained = DispatchGroup()
    var data = Data()
    do {
        try process.run()
    } catch {
        return nil
    }
    // Drain concurrently so a large item can never stall the child on a full pipe.
    DispatchQueue.global(qos: .utility).async(group: drained) {
        data = output.fileHandleForReading.readDataToEndOfFile()
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return nil
    }
    drained.wait()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func parseCredential(_ raw: String, source: String) -> ClaudeCredential? {
    guard let data = raw.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty
    else { return nil }

    let expires: Int64?
    if let number = oauth["expiresAt"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        expires = number.int64Value
    } else {
        expires = nil
    }
    return ClaudeCredential(
        accessToken: Secret(token, label: "claude-oauth"),
        source: source,
        expiresAtMilliseconds: expires,
        subscriptionType: oauth["subscriptionType"] as? String,
        rateLimitTier: oauth["rateLimitTier"] as? String
    )
}

func defaultClaudeHome(environment: [String: String]) -> URL {
    if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty {
        return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
}

/// Claude Code may update its file while an older login remains in Keychain.
/// Prefer only a demonstrably newer, unexpired credential. This runs after
/// Keychain authorization, so an explicit denial still stops lookup.
func preferNewerFileCredential(to credential: ClaudeCredential, home: URL, now: Date = Date()) -> ClaudeCredential {
    guard let raw = try? String(contentsOf: home.appendingPathComponent(".credentials.json"), encoding: .utf8),
          let file = parseCredential(raw, source: "credentials-file"),
          let fileExpiry = file.expiresAtMilliseconds,
          let currentExpiry = credential.expiresAtMilliseconds,
          fileExpiry > currentExpiry, !file.isExpired(at: now)
    else { return credential }
    return file
}
