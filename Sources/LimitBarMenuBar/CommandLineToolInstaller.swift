import AppKit
import Foundation

enum CommandLineToolStatus: Equatable, CustomStringConvertible {
    case unavailable
    case notInstalled
    case installed
    case conflict

    var description: String {
        switch self {
        case .unavailable: return "Bundled command line tool unavailable"
        case .notInstalled: return "Command line tool not installed"
        case .installed: return "Command line tool installed"
        case .conflict: return "A different file exists at ~/.local/bin/limitbar"
        }
    }
}

enum CommandLineToolInstallError: LocalizedError {
    case helperMissing
    case conflict

    var errorDescription: String? {
        switch self {
        case .helperMissing: return "The bundled limitbar helper is missing. Reinstall LimitBar.app."
        case .conflict: return "The existing command line tool was left unchanged."
        }
    }
}

@MainActor
enum CommandLineToolInstaller {
    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("limitbar")
    }

    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/limitbar")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func status() -> CommandLineToolStatus {
        guard let helper else { return .unavailable }
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) || isSymbolicLink(destination) else {
            return .notInstalled
        }
        guard isSymbolicLink(destination), let resolved = resolvedSymlink(destination) else { return .conflict }
        return resolved.standardizedFileURL == helper.standardizedFileURL ? .installed : .conflict
    }

    static func installInteractively() throws {
        guard let helper else { throw CommandLineToolInstallError.helperMissing }
        let current = status()
        if current == .conflict {
            let alert = NSAlert()
            alert.messageText = "Replace the existing limitbar command?"
            alert.informativeText = "A regular file or unrelated symlink exists at ~/.local/bin/limitbar. It will only be replaced if you confirm."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { throw CommandLineToolInstallError.conflict }
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if current == .installed || current == .conflict {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: helper)
    }

    static func remove() throws {
        guard status() == .installed else { throw CommandLineToolInstallError.conflict }
        try FileManager.default.removeItem(at: destination)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func resolvedSymlink(_ url: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        if destination.hasPrefix("/") { return URL(fileURLWithPath: destination) }
        return url.deletingLastPathComponent().appendingPathComponent(destination)
    }
}
