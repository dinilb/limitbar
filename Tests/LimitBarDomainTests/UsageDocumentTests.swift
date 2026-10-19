import Foundation
import Testing
@testable import LimitBarDomain

/// `Fixtures/sample.json` is the frozen schema-v1 compatibility fixture.
private func loadFixture() throws -> Data {
    guard let url = Bundle.module.url(forResource: "sample", withExtension: "json", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: "sample", withExtension: "json")
    else {
        throw TestFailure.fixtureMissing
    }
    return try Data(contentsOf: url)
}

private enum TestFailure: Error { case fixtureMissing }

// MARK: - Golden fixture

@Test func decodesGoldenFixtureFromPythonSerializer() throws {
    let document = try UsageDocument.decode(from: try loadFixture())

    #expect(document.schemaVersion == 1)
    #expect(document.isSchemaSupported)
    #expect(document.ok == false)  // claude is rate_limited
    #expect(document.providers.count == 2)
    #expect(document.generatedAt != nil)

    let codex = try #require(document.providers.first { $0.provider == "codex" })
    #expect(codex.status == .ok)
    #expect(codex.plan == "pro")
    #expect(codex.stale == false)
    #expect(codex.windows.count == 2)
    #expect(codex.credits?.hasCredits == false)
    #expect(codex.error == nil)

    let claude = try #require(document.providers.first { $0.provider == "claude" })
    #expect(claude.status == .rateLimited)
    #expect(claude.stale)
    #expect(claude.error?.code == "rate_limited")
}

@Test func tightestWindowMatchesTheCLIsOwnChoice() throws {
    let document = try UsageDocument.decode(from: try loadFixture())

    // The CLI computes `tightest` itself; the Swift side must agree, or the menu
    // bar and an automation agent would gate on different numbers.
    let tightest = try #require(document.tightest)
    #expect(tightest.provider == "codex")
    #expect(tightest.windowKey == "weekly")
    #expect(tightest.remainingPercent == 12)

    let codex = try #require(document.providers.first { $0.provider == "codex" })
    #expect(codex.tightestWindow?.key == tightest.windowKey)
    #expect(codex.tightestWindow?.remainingPercent == tightest.remainingPercent)
}

@Test func decodesTimestampsAsUTC() throws {
    let document = try UsageDocument.decode(from: try loadFixture())
    let expected = Date(timeIntervalSince1970: 1_786_118_400)  // 2026-08-07T16:00:00Z
    #expect(abs((document.generatedAt ?? .distantPast).timeIntervalSince(expected)) < 1)
}

// MARK: - Defensive decoding

@Test func decodesMinimalDocument() throws {
    let data = Data(#"{"schema_version":1,"ok":true,"providers":[]}"#.utf8)
    let document = try UsageDocument.decode(from: data)
    #expect(document.providers.isEmpty)
    #expect(document.tightest == nil)
    #expect(document.generatedAt == nil)
}

@Test func unknownStatusDegradesToUnknownRatherThanFailing() throws {
    let data = Data(#"{"schema_version":1,"ok":false,"providers":[{"provider":"claude","status":"future_status","windows":[]}]}"#.utf8)
    let document = try UsageDocument.decode(from: data)
    #expect(document.providers.first?.status == .unknown)
    #expect(document.providers.first?.tightestWindow == nil)
}

@Test func unknownTopLevelFieldsAreIgnored() throws {
    // A newer CLI adding fields must not break an older app.
    let data = Data(#"{"schema_version":1,"ok":true,"providers":[],"future_field":{"a":1},"tightest":null}"#.utf8)
    let document = try UsageDocument.decode(from: data)
    #expect(document.ok)
}

@Test func olderSchemaIsFlaggedNotMisRendered() throws {
    let data = Data(#"{"schema_version":0,"ok":true,"providers":[]}"#.utf8)
    let document = try UsageDocument.decode(from: data)
    #expect(document.isSchemaSupported == false)
}

@Test func missingSchemaVersionIsUnsupported() throws {
    let document = try UsageDocument.decode(from: Data(#"{"ok":true,"providers":[]}"#.utf8))
    #expect(document.schemaVersion == 0)
    #expect(document.isSchemaSupported == false)
}

// MARK: - Unknown must never look like a number

@Test func windowWithNoReadingRendersAsQuestionMark() throws {
    let data = Data(#"{"schema_version":1,"ok":true,"providers":[{"provider":"codex","status":"ok","windows":[{"key":"weekly","label":"7d"}]}]}"#.utf8)
    let document = try UsageDocument.decode(from: data)
    let window = try #require(document.providers.first?.windows.first)
    #expect(window.remainingPercent == nil)
    #expect(window.remainingText == "?")
    #expect(window.countdownText() == "?")
    // An unreadable window must not win the "tightest" contest, or the UI would
    // report an unknown as though it were nearly exhausted.
    #expect(document.providers.first?.tightestWindow == nil)
    #expect(document.providers.first?.isUsable == false)
}

@Test func severityTreatsUnknownAsUnknownNotHealthy() {
    #expect(UsageSeverity(remainingPercent: nil) == .unknown)
    #expect(UsageSeverity(remainingPercent: 0) == .critical)
    #expect(UsageSeverity(remainingPercent: 4) == .critical)
    #expect(UsageSeverity(remainingPercent: 5) == .warning)
    #expect(UsageSeverity(remainingPercent: 14) == .warning)
    #expect(UsageSeverity(remainingPercent: 15) == .caution)
    #expect(UsageSeverity(remainingPercent: 29) == .caution)
    #expect(UsageSeverity(remainingPercent: 30) == .normal)
    #expect(UsageSeverity(remainingPercent: 100) == .normal)
}

@Test func tightestWindowPicksTheLowestRemaining() {
    let provider = ProviderUsage(
        provider: "codex",
        status: .ok,
        windows: [
            UsageWindow(key: "a", label: "5h", remainingPercent: 80),
            UsageWindow(key: "b", label: "7d", remainingPercent: 5),
            UsageWindow(key: "c", label: "30d", remainingPercent: nil),
            UsageWindow(key: "d", label: "1h", remainingPercent: 40)
        ]
    )
    #expect(provider.tightestWindow?.key == "b")
}

// MARK: - Countdown formatting

@Test func countdownFloorsToASingleUnit() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func window(offset: TimeInterval) -> UsageWindow {
        UsageWindow(key: "k", label: "5h", remainingPercent: 50, resetsAt: now.addingTimeInterval(offset))
    }
    #expect(window(offset: 30).countdownText(now: now) == "now")
    #expect(window(offset: 90).countdownText(now: now) == "1m")
    #expect(window(offset: 3599).countdownText(now: now) == "59m")
    #expect(window(offset: 3600).countdownText(now: now) == "1h")
    #expect(window(offset: 86_399).countdownText(now: now) == "23h")
    #expect(window(offset: 86_400).countdownText(now: now) == "1d")
    // A reset already in the past clamps to "now" rather than going negative.
    #expect(window(offset: -5000).countdownText(now: now) == "now")
}

@Test func countdownFallsBackToResetsInSecondsWhenTimestampAbsent() {
    let window = UsageWindow(key: "k", label: "5h", remainingPercent: 50, resetsInSeconds: 7200)
    #expect(window.countdownText() == "2h")
}

// MARK: - Provider presentation

@Test func providerCodesAndNames() {
    #expect(ProviderUsage(provider: "codex", status: .ok).compactCode == "Cx")
    #expect(ProviderUsage(provider: "claude", status: .ok).compactCode == "Cl")
    #expect(ProviderUsage(provider: "codex", status: .ok).displayName == "Codex")
    #expect(ProviderUsage(provider: "claude", status: .ok).displayName == "Claude Code")
    // An unknown provider still renders something sane rather than crashing.
    #expect(ProviderUsage(provider: "gemini", status: .ok).compactCode == "Ge")
}

@Test func everyFailureStatusExplainsWhatToDo() {
    #expect(UsageStatus.authMissing.remedy(for: "codex")?.contains("codex login") == true)
    #expect(UsageStatus.authMissing.remedy(for: "claude")?.contains("claude") == true)
    #expect(UsageStatus.authExpired.remedy(for: "claude")?.contains("refresh") == true)
    // A blocked read is not a missing credential, and must never borrow its advice.
    #expect(UsageStatus.authBlocked.remedy(for: "claude")?.contains("Refresh") == true)
    #expect(UsageStatus.authBlocked.badge == "!")
    #expect(UsageStatus.offline.remedy(for: "claude") != nil)
    #expect(UsageStatus.rateLimited.remedy(for: "claude") != nil)
    #expect(UsageStatus.unsupported.remedy(for: "codex")?.contains("codex") == true)
    // `ok` needs no remedy.
    #expect(UsageStatus.ok.remedy(for: "codex") == nil)
}

@Test func statusBadgesAreDistinctPerFailureClass() {
    #expect(UsageStatus.authMissing.badge == "!")
    #expect(UsageStatus.rateLimited.badge == "~")
    #expect(UsageStatus.offline.badge == "×")
    #expect(UsageStatus.unsupported.badge == "–")
    #expect(UsageStatus.ok.badge == "?")
}

// MARK: - WidgetSnapshot

@Test func displayOrderLeadsWithClaudeWhateverTheCLIReported() throws {
    // The CLI orders providers by whichever answered first, which is usually
    // Codex — the fixture is exactly that case.
    let document = try UsageDocument.decode(from: try loadFixture())
    #expect(document.providers.map(\.provider) == ["codex", "claude"])
    #expect(document.providersInDisplayOrder.map(\.provider) == ["claude", "codex"])

    // Nothing is dropped or duplicated, and a Claude-less document is left
    // in the order it came in.
    let codexOnly = UsageDocument(
        generatedAt: nil,
        ok: true,
        providers: document.providers.filter { $0.provider != "claude" }
    )
    #expect(codexOnly.providersInDisplayOrder.map(\.provider) == ["codex"])
    #expect(UsageDocument.empty.providersInDisplayOrder.isEmpty)
}

@Test func widgetWindowsReadShortestFirst() throws {
    // The fixture's codex entry reports five_hour then weekly; the widget shows
    // a row per window, and the session has to come first — it is the one that
    // empties during a sitting.
    let snapshot = WidgetSnapshot(document: try UsageDocument.decode(from: try loadFixture()))
    let codex = try #require(snapshot.entries.first { $0.id == "codex" })
    #expect(codex.windowsInDisplayOrder.map(\.label) == ["5h", "7d"])
    #expect(codex.windowsInDisplayOrder.first?.isFiveHour == true)
    #expect(codex.windowsInDisplayOrder.last?.isFiveHour == false)
    // Nothing is dropped, whatever the order in.
    #expect(codex.windowsInDisplayOrder.count == codex.windows.count)

    // Claude reports only a five-hour window in this fixture.
    let claude = try #require(snapshot.entries.first { $0.id == "claude" })
    #expect(claude.windowsInDisplayOrder.map(\.label) == ["5h"])
}

@Test func widgetSnapshotProjectsTheDocument() throws {
    let document = try UsageDocument.decode(from: try loadFixture())
    let snapshot = WidgetSnapshot(document: document)

    #expect(snapshot.entries.count == 2)
    #expect(snapshot.hasUsableData)
    // Every surface leads with Claude, the widget included.
    #expect(snapshot.entries.map(\.id) == ["claude", "codex"])

    let codex = try #require(snapshot.entries.first { $0.id == "codex" })
    #expect(codex.code == "Cx")
    #expect(codex.displayName == "Codex")
    #expect(codex.plan == "pro")
    #expect(codex.status == .ok)
    #expect(codex.windows.count == 2)
    #expect(codex.tightest?.remainingPercent == 12)

    let claude = try #require(snapshot.entries.first { $0.id == "claude" })
    #expect(claude.stale)
    #expect(claude.status == .rateLimited)

    // The small family shows this one number.
    #expect(snapshot.tightestEntry?.id == "codex")
}

@Test func widgetSnapshotSurvivesAFileRoundTrip() throws {
    let document = try UsageDocument.decode(from: try loadFixture())
    let original = WidgetSnapshot(document: document)

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("limitbar-test-\(UUID().uuidString)")
        .appendingPathComponent("widget-snapshot.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try original.write(to: url)
    let reloaded = try WidgetSnapshot.read(from: url)

    // Encoder and decoder must agree on the date strategy; a mismatch silently
    // drops every timestamp, which is why this asserts full equality.
    #expect(reloaded == original)
    #expect(reloaded.entries.first?.tightest?.resetsAt != nil)
}

@Test func widgetSnapshotWriteCreatesMissingDirectories() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("limitbar-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("a/b/c/widget-snapshot.json")

    try WidgetSnapshot(updatedAt: Date(), entries: []).write(to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func emptyWidgetSnapshotHasNoUsableData() {
    #expect(WidgetSnapshot.empty.entries.isEmpty)
    #expect(WidgetSnapshot.empty.hasUsableData == false)
    #expect(WidgetSnapshot.empty.tightestEntry == nil)
}

@Test func widgetSnapshotEntryWithNoWindowsIsNotUsable() {
    let snapshot = WidgetSnapshot(
        updatedAt: Date(),
        entries: [
            WidgetSnapshot.Entry(
                id: "claude", code: "Cl", displayName: "Claude Code", plan: nil,
                statusRaw: "auth_missing", stale: false, windows: []
            )
        ]
    )
    #expect(snapshot.hasUsableData == false)
    // Still surfaced so the widget can render "Sign in required" instead of blank.
    #expect(snapshot.tightestEntry?.id == "claude")
    #expect(snapshot.entries.first?.status == .authMissing)
}

@Test func widgetSnapshotPathsAreDistinctAndUnderTheHomeDirectory() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(WidgetSnapshot.appFileURL.path.hasPrefix(home))
    #expect(WidgetSnapshot.widgetContainerFileURL.path.hasPrefix(home))
    #expect(WidgetSnapshot.appFileURL != WidgetSnapshot.widgetContainerFileURL)
}

// MARK: - Date helpers

@Test func parsesBothFractionalAndPlainISO8601() {
    // The CLI emits second precision; the endpoint upstream emits fractional.
    let plain = UsageDate.parse("2026-08-07T16:00:00Z")
    let fractional = UsageDate.parse("2026-08-07T16:00:00.081129Z")
    #expect(plain != nil)
    #expect(fractional != nil)
    #expect(abs((fractional ?? .distantPast).timeIntervalSince(plain ?? .distantFuture)) < 1)
}

@Test func rejectsUnparseableTimestamps() {
    #expect(UsageDate.parse(nil) == nil)
    #expect(UsageDate.parse("") == nil)
    #expect(UsageDate.parse("not a date") == nil)
    #expect(UsageDate.parse("1786118400") == nil)
}

@Test func formatRoundTripsThroughParse() throws {
    let date = Date(timeIntervalSince1970: 1_786_118_400)
    let text = try #require(UsageDate.format(date))
    #expect(text == "2026-08-07T16:00:00Z")
    #expect(UsageDate.parse(text) == date)
}
