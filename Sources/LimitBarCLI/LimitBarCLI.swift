import LimitBarDomain
import LimitBarProviders
import Darwin
import Foundation

private let cliVersion = "1.0.0"

private struct CLIOptions {
    var providers: [String] = []
    var timeout: TimeInterval = 20
    var maxAge: TimeInterval = 300
    var refresh = false
    var cacheOnly = false
    var noCache = false
    var compact = false
    var includeSpend = false
    var codexHome: URL?
    var claudeHome: URL?
    var version = false
}

private enum CLIParseError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

@main
struct LimitBarCLI {
    static func main() async {
        let options: CLIOptions
        do {
            options = try parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            writeError("limitbar: \(error.localizedDescription)\n")
            emit(UsageDocument.make(providers: []), compact: true)
            Darwin.exit(2)
        }
        if options.version {
            FileHandle.standardOutput.write(Data("limitbar \(cliVersion)\n".utf8))
            return
        }

        let providers = selectedProviders(options.providers)
        let request = UsageRequest(
            providers: providers,
            timeout: options.timeout,
            maxAge: options.maxAge,
            refresh: options.refresh,
            cacheOnly: options.cacheOnly,
            noCache: options.noCache,
            includeSpend: options.includeSpend,
            codexHome: options.codexHome,
            claudeHome: options.claudeHome
        )
        let document = await UsageService().collect(request)
        emit(document, compact: options.compact)
        Darwin.exit(document.ok ? 0 : 1)
    }

    private static func parse(_ arguments: [String]) throws -> CLIOptions {
        var result = CLIOptions()
        var index = 0
        func requiredValue(for option: String) throws -> String {
            guard index + 1 < arguments.count else { throw CLIParseError.message("\(option) requires a value") }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": break
            case "--compact": result.compact = true
            case "--refresh": result.refresh = true
            case "--cache-only": result.cacheOnly = true
            case "--no-cache": result.noCache = true
            case "--include-spend": result.includeSpend = true
            case "--version": result.version = true
            case "--provider": result.providers.append(try requiredValue(for: argument))
            case "--timeout":
                let raw = try requiredValue(for: argument)
                guard let value = TimeInterval(raw), value > 0 else {
                    throw CLIParseError.message("--timeout must be positive")
                }
                result.timeout = value
            case "--max-age":
                let raw = try requiredValue(for: argument)
                guard let value = TimeInterval(raw), value >= 0 else {
                    throw CLIParseError.message("--max-age must be non-negative")
                }
                result.maxAge = value
            case "--codex-home":
                result.codexHome = fileURL(try requiredValue(for: argument))
            case "--claude-home":
                result.claudeHome = fileURL(try requiredValue(for: argument))
            case "-h", "--help":
                writeError(usage)
                Darwin.exit(0)
            default:
                if argument.hasPrefix("--provider=") {
                    result.providers.append(String(argument.dropFirst("--provider=".count)))
                } else {
                    throw CLIParseError.message("unknown option: \(argument)")
                }
            }
            index += 1
        }
        let allowed = Set(["codex", "claude", "all"])
        guard result.providers.allSatisfy(allowed.contains) else {
            throw CLIParseError.message("--provider must be codex, claude, or all")
        }
        if result.cacheOnly && result.noCache {
            throw CLIParseError.message("--cache-only and --no-cache are mutually exclusive")
        }
        if result.refresh && result.cacheOnly {
            throw CLIParseError.message("--refresh and --cache-only are mutually exclusive")
        }
        return result
    }

    private static func selectedProviders(_ values: [String]) -> [String] {
        if values.isEmpty || values.contains("all") { return ["codex", "claude"] }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func fileURL(_ value: String) -> URL {
        URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
    }

    private static func emit(_ document: UsageDocument, compact: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document),
              let text = String(data: data, encoding: .utf8)
        else {
            FileHandle.standardOutput.write(Data("{\"schema_version\":1,\"generated_at\":null,\"ok\":false,\"providers\":[],\"tightest\":null}\n".utf8))
            return
        }
        FileHandle.standardOutput.write(Data((OutputScrubber.scrub(text) + "\n").utf8))
    }
}

private let usage = """
Usage: limitbar [--json] [--provider codex|claude|all] [--compact]
                [--cache-only | --no-cache | --refresh] [--max-age SECONDS]
                [--timeout SECONDS] [--codex-home PATH] [--claude-home PATH]
                [--include-spend] [--version]
"""

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data(OutputScrubber.scrub(text).utf8))
}
