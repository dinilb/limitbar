import Foundation
import Testing
@testable import LimitBarProviders

private func makeExecutable(_ path: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
}

@Test func fnmDiscoveryWorksWithoutShellInitialization() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent(".local/share/fnm")
    let installation = root.appendingPathComponent("node-versions/v24.21.0/installation")
    try makeExecutable(installation.appendingPathComponent("bin/codex"), contents: "#!/usr/bin/env node\n")
    try makeExecutable(installation.appendingPathComponent("bin/node"), contents: "#!/bin/sh\nprintf MATCHING_NODE\n")
    try makeExecutable(root.appendingPathComponent("node-versions/v26.0.0/installation/bin/codex"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("aliases"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("aliases/default"), withDestinationURL: installation)

    let binary = try resolveCodexBinary(environment: ["PATH": "/usr/bin:/bin"], home: home, standardLocations: [])
    #expect(binary.path == root.appendingPathComponent("aliases/default/bin/codex").path)
    let process = Process()
    process.executableURL = binary
    process.environment = ["PATH": augmentedExecutablePath("/usr/bin:/bin", executable: binary)]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "MATCHING_NODE")
}

@Test func fnmDiscoverySupportsCustomRootsAndNumericVersionFallback() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent("custom/fnm")
    for version in ["v9.0.0", "v24.9.0", "v24.10.0"] {
        try makeExecutable(root.appendingPathComponent("node-versions/\(version)/installation/bin/codex"))
    }
    let expected = root.appendingPathComponent("node-versions/v24.10.0/installation/bin/codex")
    for environment in [["FNM_DIR": root.path], ["XDG_DATA_HOME": root.deletingLastPathComponent().path]] {
        let actual = try resolveCodexBinary(environment: environment, home: home, standardLocations: [])
        #expect(actual.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path)
    }
    let override = home.appendingPathComponent("override/codex")
    try makeExecutable(override)
    #expect(try resolveCodexBinary(environment: ["CODEX_BINARY": override.path, "FNM_DIR": root.path], home: home, standardLocations: []) == override)
    #expect(try resolveCodexBinary(environment: ["PATH": override.deletingLastPathComponent().path, "FNM_DIR": root.path], home: home, standardLocations: []) == override)
}
