import Foundation

/// The trimmed view of a `UsageDocument` that the menu-bar app hands to the
/// WidgetKit extension.
///
/// A widget extension runs sandboxed and cannot usefully spawn the CLI, so the
/// app writes this file after each refresh and reloads the timeline. It contains
/// nothing but display strings and integers.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let widgetKind = "com.dinilb.limitbar.usage-widget"
    public static let widgetExtensionBundleIdentifier = "com.dinilb.LimitBar.LimitBarWidgetExtension"

    public let updatedAt: Date
    public let entries: [Entry]

    public init(updatedAt: Date, entries: [Entry]) {
        self.updatedAt = updatedAt
        self.entries = entries
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let code: String
        public let displayName: String
        public let plan: String?
        public let statusRaw: String
        public let stale: Bool
        public let windows: [WindowEntry]

        public init(
            id: String,
            code: String,
            displayName: String,
            plan: String?,
            statusRaw: String,
            stale: Bool,
            windows: [WindowEntry]
        ) {
            self.id = id
            self.code = code
            self.displayName = displayName
            self.plan = plan
            self.statusRaw = statusRaw
            self.stale = stale
            self.windows = windows
        }

        public var status: UsageStatus {
            UsageStatus(rawValue: statusRaw) ?? .unknown
        }

        public var tightest: WindowEntry? {
            windows.filter { $0.remainingPercent != nil }
                .min { ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0) }
        }

        /// Windows in reading order: the five-hour session first, then the
        /// longer buckets as reported. Shortest-first matches how the numbers
        /// actually get consumed — the session is what runs out during a
        /// sitting, the weekly is the ceiling behind it.
        public var windowsInDisplayOrder: [WindowEntry] {
            windows.filter(\.isFiveHour) + windows.filter { !$0.isFiveHour }
        }
    }

    public struct WindowEntry: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let remainingPercent: Int?
        public let resetsAt: Date?

        public init(id: String, label: String, remainingPercent: Int?, resetsAt: Date?) {
            self.id = id
            self.label = label
            self.remainingPercent = remainingPercent
            self.resetsAt = resetsAt
        }

        public var remainingText: String {
            guard let remainingPercent else { return "?" }
            return "\(remainingPercent)"
        }

        /// The five-hour session window.
        ///
        /// Derived from the stable CLI key rather than a stored flag, so an
        /// older snapshot still decodes. Codex disambiguates duplicate keys by
        /// suffixing them, hence the prefix match.
        public var isFiveHour: Bool {
            id == "five_hour" || id.hasPrefix("five_hour_")
        }

        public func countdownText(now: Date = Date()) -> String {
            guard let resetsAt else { return "?" }
            let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
            let minutes = seconds / 60
            if minutes < 1 { return "now" }
            let hours = minutes / 60
            if hours >= 24 { return "\(hours / 24)d" }
            if hours >= 1 { return "\(hours)h" }
            return "\(minutes)m"
        }
    }

    public static let empty = WidgetSnapshot(updatedAt: .distantPast, entries: [])

    /// The entry closest to exhaustion — what the small widget shows.
    public var tightestEntry: Entry? {
        entries
            .filter { $0.tightest != nil }
            .min { ($0.tightest?.remainingPercent ?? 0) < ($1.tightest?.remainingPercent ?? 0) }
            ?? entries.first
    }

    public var hasUsableData: Bool {
        entries.contains { $0.tightest != nil }
    }

    // MARK: - Locations

    /// Where the app writes. Readable by the app and by an unsandboxed reader.
    public static var appFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LimitBar", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }

    /// Where the sandboxed widget extension can read. The app writes both.
    public static var widgetContainerFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(widgetExtensionBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support/LimitBar", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }

    /// Encoder/decoder pair. They must stay in lockstep: an ISO-8601 encoder
    /// with a default decoder silently fails to read back every date.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func read(from url: URL = appFileURL) throws -> WidgetSnapshot {
        try decoder.decode(WidgetSnapshot.self, from: Data(contentsOf: url))
    }

    /// Read whichever copy exists, newest first. The widget calls this.
    public static func readBestAvailable() -> WidgetSnapshot? {
        let candidates = [widgetContainerFileURL, appFileURL]
        let found = candidates.compactMap { try? read(from: $0) }
        return found.max { $0.updatedAt < $1.updatedAt }
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Write both copies. A missing widget container is not an error — it only
    /// means the widget has never been instantiated.
    @discardableResult
    public func writeForWidget() -> [URL] {
        var written: [URL] = []
        for url in [Self.appFileURL, Self.widgetContainerFileURL] {
            if (try? write(to: url)) != nil {
                written.append(url)
            }
        }
        return written
    }
}

public extension WidgetSnapshot {
    /// Project a full document down to what the widget needs.
    init(document: UsageDocument, now: Date = Date()) {
        self.init(
            updatedAt: document.generatedAt ?? now,
            entries: document.providersInDisplayOrder.map { provider in
                Entry(
                    id: provider.provider,
                    code: provider.compactCode,
                    displayName: provider.displayName,
                    plan: provider.plan,
                    statusRaw: provider.status.rawValue,
                    stale: provider.stale,
                    windows: provider.windows.map { window in
                        WindowEntry(
                            id: window.key,
                            label: window.label,
                            remainingPercent: window.remainingPercent,
                            resetsAt: window.resetsAt
                        )
                    }
                )
            }
        )
    }
}
