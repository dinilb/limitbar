import Foundation
import Testing
@testable import LimitBarProviders

/// Manual check against the real `claude`. Run with LIMITBAR_LIVE_CLAUDE=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIMITBAR_LIVE_CLAUDE"] == "1"))
func liveClaudeRenewAndUsageScreen() async {
    let runner = ClaudeCLIRunner()
    let before = claudeKeychainItemModified()
    let start = Date()
    let changed = await runner.renewLogin(timeout: 20) {
        let now = claudeKeychainItemModified()
        return now != nil && now != before
    }
    print("LIVE renew changed=\(changed) after \(Date().timeIntervalSince(start))s")
    let screen = await runner.readUsageScreen(timeout: 30)
    print("LIVE usage screen chars=\(screen?.count ?? -1) windows=\(screen.map { ClaudeUsageScreen.parse($0).map { "\($0.label)=\($0.usedPercent ?? -1)" } } ?? [])")
}
