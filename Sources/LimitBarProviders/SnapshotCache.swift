import LimitBarDomain
import Darwin
import Foundation

struct RefreshState: Codable, Sendable {
    struct ProviderState: Codable, Sendable {
        var cooldownUntil: Date?
        var consecutiveRateLimits: Int
    }

    var providers: [String: ProviderState] = [:]
}

public struct SnapshotCache: Sendable {
    public let directory: URL
    public var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }
    var stateURL: URL { directory.appendingPathComponent("refresh-state.json") }
    var lockURL: URL { directory.appendingPathComponent("refresh.lock") }

    public init(directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.directory = directory ?? Self.defaultDirectory(environment: environment)
    }

    public static func defaultDirectory(environment: [String: String]) -> URL {
        if let override = environment["LIMITBAR_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }
        if let xdg = environment["XDG_CACHE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("limitbar", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/limitbar", isDirectory: true)
    }

    func acquireLock() throws -> FileLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        return FileLock(descriptor: descriptor)
    }

    func loadProviders() -> [String: ProviderUsage] {
        guard let data = try? Data(contentsOf: snapshotURL),
              let document = try? UsageDocument.decode(from: data),
              document.schemaVersion == UsageDocument.supportedSchemaVersion
        else { return [:] }
        var result: [String: ProviderUsage] = [:]
        for provider in document.providers where (provider.status == .ok || provider.status == .noSubscription) && provider.fetchedAt != nil {
            result[provider.provider] = provider.withoutSpend()
        }
        return result
    }

    func storeProviders(_ providers: [String: ProviderUsage], now: Date) {
        let safe = providers.values
            .filter { ($0.status == .ok || $0.status == .noSubscription) && !$0.stale }
            .map { $0.withoutSpend() }
            .sorted { $0.provider < $1.provider }
        guard !safe.isEmpty else { return }
        write(try? JSONEncoder().encode(UsageDocument.make(providers: safe, generatedAt: now)), to: snapshotURL)
    }

    func loadState() -> RefreshState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(RefreshState.self, from: data)
        else { return RefreshState() }
        return state
    }

    func storeState(_ state: RefreshState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        write(try? encoder.encode(state), to: stateURL)
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let scrubbed: Data
            if url == snapshotURL, let text = String(data: data, encoding: .utf8) {
                scrubbed = Data(OutputScrubber.scrub(text).utf8)
            } else {
                scrubbed = data
            }
            let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return }
            var writeSucceeded = true
            scrubbed.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { writeSucceeded = false; break }
                    offset += written
                }
            }
            if writeSucceeded { _ = fsync(descriptor) }
            Darwin.close(descriptor)
            guard writeSucceeded, Darwin.rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
        } catch {
            // Cache/state persistence is best effort; it must never suppress output.
        }
    }
}

final class FileLock: @unchecked Sendable {
    private var descriptor: Int32
    private let mutex = NSLock()

    init(descriptor: Int32) { self.descriptor = descriptor }

    func unlock() {
        mutex.lock()
        defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }
}
