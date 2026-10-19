import Foundation

let redactedSecret = "<redacted>"

private final class SecretRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()

    func register(_ value: String) {
        guard value.count >= 8 else { return }
        lock.lock()
        values.insert(value)
        lock.unlock()
    }

    func scrub(_ text: String) -> String {
        lock.lock()
        let registered = values
        lock.unlock()
        return registered.reduce(text) { $0.replacingOccurrences(of: $1, with: redactedSecret) }
    }
}

enum SecretScrubber {
    private static let registry = SecretRegistry()

    static func register(_ value: String) { registry.register(value) }
    static func scrub(_ text: String) -> String { registry.scrub(text) }
}

/// Final boundary scrubber for complete CLI documents and user-facing errors.
public enum OutputScrubber {
    public static func scrub(_ text: String) -> String { SecretScrubber.scrub(text) }
}

/// Deliberately has no Codable conformance and no public unwrapping API.
struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String
    let label: String

    init(_ value: String, label: String = "secret") {
        self.value = value
        self.label = label
        SecretScrubber.register(value)
    }

    var description: String { redactedSecret }
    var debugDescription: String { "Secret(\(label): \(redactedSecret))" }

    /// Compares without exposing either value.
    func hasSameValue(as other: Secret) -> Bool { value == other.value }

    /// This call site is intentionally used only by `ClaudeProvider`.
    func withValue<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(value)
    }
}
