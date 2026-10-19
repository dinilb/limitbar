import Foundation
import Testing
@testable import LimitBarDomain

/// The menu bar's contract: one column per provider, Claude Code first, its
/// five-hour window always on the top row with a remaining percentage, whatever
/// any other provider is doing.
///
///     Cl 3h 30%   Cx
///        3d 20%      6d 40%
private let now = Date(timeIntervalSince1970: 1_786_118_400)  // 2026-08-07T16:00:00Z

private func window(
    key: String,
    label: String,
    minutes: Int?,
    remaining: Int?,
    resetsIn: TimeInterval? = 3600
) -> UsageWindow {
    UsageWindow(
        key: key,
        label: label,
        windowMinutes: minutes,
        usedPercent: remaining.map { 100 - $0 },
        remainingPercent: remaining,
        resetsAt: resetsIn.map { now.addingTimeInterval($0) }
    )
}

private func fiveHour(remaining: Int?, resetsIn: TimeInterval? = 4 * 3600) -> UsageWindow {
    window(key: "five_hour", label: "5h", minutes: 300, remaining: remaining, resetsIn: resetsIn)
}

private func weekly(remaining: Int?, resetsIn: TimeInterval = 3 * 86_400) -> UsageWindow {
    window(key: "weekly", label: "7d", minutes: nil, remaining: remaining, resetsIn: resetsIn)
}

private func document(_ providers: [ProviderUsage]) -> UsageDocument {
    UsageDocument(generatedAt: now, ok: false, providers: providers)
}

// MARK: - Window identity

@Test func fiveHourIsIdentifiedByDurationNotPosition() {
    #expect(window(key: "five_hour", label: "5h", minutes: 300, remaining: 50).isFiveHour)
    #expect(window(key: "monthly", label: "30d", minutes: 43200, remaining: 50).isFiveHour == false)
    #expect(window(key: "weekly", label: "7d", minutes: 10080, remaining: 50).isFiveHour == false)
    // Claude's weekly buckets carry no duration; they must not be mistaken for 5h.
    #expect(window(key: "weekly", label: "7d", minutes: nil, remaining: 50).isFiveHour == false)
    // Duration absent but the CLI's stable key present: trust the key.
    #expect(window(key: "five_hour", label: "5h", minutes: nil, remaining: 50).isFiveHour)
    // Duration present and wrong beats a misleading key.
    #expect(window(key: "five_hour", label: "5h", minutes: 43200, remaining: 50).isFiveHour == false)
}

@Test func providerExposesTheFiveHourWindowSeparatelyFromTheTightest() {
    let provider = ProviderUsage(
        provider: "claude",
        status: .ok,
        windows: [weekly(remaining: 8), fiveHour(remaining: 90)]
    )
    #expect(provider.tightestWindow?.key == "weekly")
    #expect(provider.fiveHourWindow?.remainingPercent == 90)
    #expect(provider.tightestNonFiveHourWindow?.key == "weekly")
}

@Test func fiveHourWindowIsNilRatherThanSubstitutedWhenAbsent() {
    let provider = ProviderUsage(
        provider: "codex",
        status: .ok,
        windows: [window(key: "monthly", label: "30d", minutes: 43200, remaining: 0)]
    )
    // A free Codex plan reports only a 30-day bucket. Returning it here would
    // put a monthly number under a `5h` label.
    #expect(provider.fiveHourWindow == nil)
    #expect(provider.tightestNonFiveHourWindow?.key == "monthly")
}

@Test func remainingBadgeMarksUnknownWithoutAPercentSign() {
    #expect(fiveHour(remaining: 83).remainingBadge == "83%")
    #expect(fiveHour(remaining: 0).remainingBadge == "0%")
    #expect(fiveHour(remaining: nil).remainingBadge == "?")
}

// MARK: - The pinned column

@Test func claudeAlwaysOwnsTheFirstColumn() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "codex", status: .ok, windows: [fiveHour(remaining: 55)]),
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)])
        ]),
        now: now
    )

    // Codex is first in the document; Claude is still first in the bar.
    let pinned = columns[0]
    #expect(pinned.id == "claude")
    #expect(pinned.isPinned)
    #expect(pinned.code == "Cl")
    #expect(pinned.top?.text == "4h 83%")
    #expect(columns.filter(\.isPinned).count == 1)
}

@Test func aProviderWithNoLongWindowLeavesTheBottomRowBlank() {
    // The whole point of the grid: an absent window draws nothing rather than a
    // placeholder, so "Codex has one window" does not read as a failure.
    let columns = MenuBarStatus.columns(
        for: document([ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)])]),
        now: now
    )
    #expect(columns[0].top?.text == "4h 83%")
    #expect(columns[0].bottom == nil)
}

@Test func aCodexWithOnlyAWeeklyLeavesTheFiveHourRowBlank() {
    // The real shape today: Codex reports no five-hour bucket, so its top cell
    // is empty and its weekly sits on the bottom row under the code.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 30), weekly(remaining: 20)]),
            ProviderUsage(provider: "codex", status: .ok, windows: [weekly(remaining: 40, resetsIn: 6 * 86_400)])
        ]),
        now: now
    )

    #expect(columns.map(\.id) == ["claude", "codex"])
    #expect(columns[0].code == "Cl")
    #expect(columns[0].top?.text == "4h 30%")
    #expect(columns[0].bottom?.text == "3d 20%")
    #expect(columns[1].code == "Cx")
    #expect(columns[1].top == nil)
    #expect(columns[1].bottom?.text == "6d 40%")
}

@Test func exhaustedCodexDoesNotDisplaceOrDimTheClaudeColumn() {
    // The regression the pinned column exists for: Codex at 0% on a monthly
    // window used to be the loudest thing in the bar and Claude showed whatever
    // its own tightest window happened to be.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "codex",
                status: .ok,
                plan: "free",
                windows: [window(key: "monthly", label: "30d", minutes: 43200, remaining: 0, resetsIn: 29 * 86_400)]
            ),
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)])
        ]),
        now: now
    )

    #expect(columns.map(\.id) == ["claude", "codex"])
    #expect(columns[0].top?.text == "4h 83%")
    #expect(columns[0].top?.severity == .normal)
    // Codex keeps its own readout, confined to its own column and its own row.
    #expect(columns[1].top == nil)
    #expect(columns[1].bottom?.text == "29d 0%")
    #expect(columns[1].bottom?.severity == .critical)
}

@Test func claudeColumnSurvivesAProviderThatReportsNoFiveHourWindow() {
    let columns = MenuBarStatus.columns(
        for: document([ProviderUsage(provider: "claude", status: .ok, windows: [weekly(remaining: 60)])]),
        now: now
    )

    let pinned = columns[0]
    #expect(pinned.isPinned)
    // The label stays `5h` and the value is explicitly absent — the 60% weekly
    // figure must never appear on this row.
    #expect(pinned.top?.text == "5h —")
    #expect(pinned.top?.severity == .unknown)
    #expect(pinned.top?.text.contains("60") == false)
    // It still belongs on the bottom row, where it is true.
    #expect(pinned.bottom?.text == "3d 60%")
}

@Test func anAbsentProviderIsNotInvented() {
    let value = document([ProviderUsage(provider: "codex", status: .ok, windows: [fiveHour(remaining: 40)])])
    #expect(MenuBarStatus.columns(for: value, now: now).map(\.id) == ["codex"])
}

@Test func authFailureShowsAStatusBadgeUnderTheFiveHourLabel() {
    let columns = MenuBarStatus.columns(
        for: document([ProviderUsage(provider: "claude", status: .authExpired, windows: [])]),
        now: now
    )

    #expect(columns[0].top?.text == "5h !")
    #expect(columns[0].bottom == nil)
    #expect(columns[0].top?.severity == .unknown)
    #expect(columns[0].detail.contains("claude"))  // the remedy
}

@Test func unreadableFiveHourPercentShowsAQuestionMarkNotAZero() {
    let columns = MenuBarStatus.columns(
        for: document([ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: nil)])]),
        now: now
    )

    #expect(columns[0].top?.text == "4h ?")
    #expect(columns[0].top?.severity == .unknown)
}

@Test func missingResetTimestampFallsBackToNamingTheSessionWindow() {
    // The top row leads with a countdown, but there is nothing to count down
    // here. It names the window rather than putting `?` in the label slot, which
    // would say strictly less while the percentage is still worth reading.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 12, resetsIn: nil)])
        ]),
        now: now
    )
    #expect(columns[0].top?.text == "5h 12%")
    #expect(columns[0].top?.severity == .warning)
}

@Test func aLongWindowWithNoResetTimestampLeadsWithAQuestionMark() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .ok,
                windows: [
                    fiveHour(remaining: 83),
                    window(key: "weekly", label: "7d", minutes: nil, remaining: 20, resetsIn: nil)
                ]
            )
        ]),
        now: now
    )
    #expect(columns[0].bottom?.text == "? 20%")
}

@Test func anExhaustedClaudeFiveHourReadsZeroRatherThanGoingAbsent() {
    // 0% is a reading, not a missing value, and it is the single most important
    // number the bar ever shows.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 0)]),
            ProviderUsage(provider: "codex", status: .ok, windows: [fiveHour(remaining: 100)])
        ]),
        now: now
    )
    #expect(columns[0].top?.text == "4h 0%")
    #expect(columns[0].top?.severity == .critical)
    #expect(columns[0].detail == "Claude Code 5h: 0% left, resets in 4h")
}

@Test func staleClaudeReadingIsMarkedButStillShown() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .rateLimited, stale: true, windows: [fiveHour(remaining: 73)])
        ]),
        now: now
    )
    #expect(columns[0].top?.text == "4h 73%·")
    #expect(columns[0].stale)
    #expect(columns[0].detail.contains("(cached)"))
}

@Test func eachColumnCarriesTheCacheMarkExactlyOnce() {
    // Both rows of a column share one staleness, so marking both says nothing
    // new and puts four dots in a bar that is trying to be quiet.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .rateLimited,
                stale: true,
                windows: [fiveHour(remaining: 73), weekly(remaining: 20)]
            ),
            ProviderUsage(
                provider: "codex",
                status: .ok,
                stale: true,
                windows: [weekly(remaining: 40, resetsIn: 6 * 86_400)]
            )
        ]),
        now: now
    )

    #expect(columns[0].top?.text == "4h 73%·")
    #expect(columns[0].bottom?.text == "3d 20%")
    // Codex has no top row, so the mark falls through rather than vanishing
    // with it.
    #expect(columns[1].top == nil)
    #expect(columns[1].bottom?.text == "6d 40%·")
    // Both rows still report as stale, which is what dims the whole column.
    #expect(columns[0].bottom?.stale == true)
    #expect(columns[0].stale)
    #expect(columns[1].stale)
}

// MARK: - The long-window row

@Test func theLongRowIsLedByItsCountdownAndKeepsItsRealNameInTheTooltip() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .ok,
                windows: [fiveHour(remaining: 83), weekly(remaining: 20)]
            )
        ]),
        now: now
    )

    #expect(columns[0].top?.text == "4h 83%")
    // Row position already says which window each row is, so both label slots
    // are spent on the countdown instead.
    #expect(columns[0].bottom?.text == "3d 20%")
    // The window's real name survives where there is room for it.
    #expect(columns[0].details == [
        "Claude Code 5h: 83% left, resets in 4h",
        "Claude Code 7d: 20% left, resets in 3d"
    ])
}

@Test func aHealthyWeeklyStillGetsItsRow() {
    // The old bar hid a healthy weekly to save width. The grid has a row for it
    // either way, so hiding it would just leave a hole.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .ok,
                windows: [fiveHour(remaining: 83), weekly(remaining: 51)]
            )
        ]),
        now: now
    )
    #expect(columns[0].bottom?.text == "3d 51%")
    #expect(columns[0].bottom?.severity == .normal)
}

@Test func aWeeklyLooserThanTheFiveHourStillGetsItsRow() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .ok,
                windows: [fiveHour(remaining: 4), weekly(remaining: 30)]
            )
        ]),
        now: now
    )
    #expect(columns[0].top?.text == "4h 4%")
    #expect(columns[0].top?.severity == .critical)
    #expect(columns[0].bottom?.text == "3d 30%")
    #expect(columns[0].bottom?.severity == .normal)
}

@Test func anUnreadableWeeklyStillGetsARowSayingSo() {
    // A blank cell would claim "no weekly limit", which is a different and
    // wrong statement from "there is one and we could not read it".
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .ok,
                windows: [fiveHour(remaining: 83), weekly(remaining: nil)]
            )
        ]),
        now: now
    )
    #expect(columns[0].bottom?.text == "3d ?")
    #expect(columns[0].bottom?.severity == .unknown)
}

@Test func theTightestOfSeveralWeeklyBucketsWinsTheRow() {
    // Claude reports 7d alongside 7d Opus, 7d Sonnet and friends. Only one fits
    // the row, and showing a healthy overall weekly while Opus is spent would
    // be the wrong one.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .ok,
                windows: [
                    fiveHour(remaining: 83),
                    weekly(remaining: 40),
                    window(key: "weekly_opus", label: "7d Opus", minutes: nil, remaining: 9, resetsIn: 5 * 86_400)
                ]
            )
        ]),
        now: now
    )
    #expect(columns[0].bottom?.text == "5d 9%")
    #expect(columns[0].bottom?.severity == .warning)
    #expect(columns[0].details.last == "Claude Code 7d Opus: 9% left, resets in 5d")
}

@Test func readingsAreGradedAcrossAllFourBands() {
    // Colour is the only thing distinguishing a healthy bar from one about to
    // run out — every other glyph is deliberately identical — so the band a
    // number lands in is the whole signal.
    func severity(ofFiveHour remaining: Int) -> UsageSeverity? {
        MenuBarStatus.columns(
            for: document([
                ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: remaining)])
            ]),
            now: now
        )[0].top?.severity
    }

    #expect(severity(ofFiveHour: 100) == .normal)
    #expect(severity(ofFiveHour: 30) == .normal)
    #expect(severity(ofFiveHour: 29) == .caution)
    #expect(severity(ofFiveHour: 15) == .caution)
    #expect(severity(ofFiveHour: 14) == .warning)
    #expect(severity(ofFiveHour: 5) == .warning)
    #expect(severity(ofFiveHour: 4) == .critical)
    #expect(severity(ofFiveHour: 0) == .critical)
}

// MARK: - Other providers

@Test func aProviderWithNoReadableWindowShowsItsFailureClass() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)]),
            ProviderUsage(provider: "codex", status: .upstreamError, windows: [])
        ]),
        now: now
    )
    #expect(columns[1].id == "codex")
    #expect(columns[1].code == "Cx")
    #expect(columns[1].top?.text == "!")
    #expect(columns[1].bottom == nil)
    #expect(columns[1].detail.contains("upstream_error"))
}

@Test func noDocumentYetRendersTheLoadingColumnRatherThanAnEmptyClaudeSlot() {
    let columns = MenuBarStatus.columns(for: .empty, now: now)
    #expect(columns == [MenuBarStatus.loadingColumn])
    #expect(columns[0].code == "AI")
    #expect(columns[0].top?.text == "…")
}

@Test func aLoadedButProviderlessDocumentShowsAGenericEmptyState() {
    let columns = MenuBarStatus.columns(for: document([]), now: now)
    #expect(columns == [MenuBarStatus.unconfiguredColumn])
}

// MARK: - The CLI itself failing

@Test func aCLIFailureBeforeAnyReadingShowsAGenericFailure() {
    let columns = MenuBarStatus.columns(
        for: .empty,
        error: "The limitbar command was not found.",
        now: now
    )

    #expect(columns.map(\.id) == ["error"])
    #expect(!columns[0].isPinned)
    #expect(columns[0].code == "AI")
    #expect(columns[0].top?.text == "×")
    #expect(columns[0].bottom == nil)
    #expect(columns[0].top?.severity == .unknown)
    #expect(columns[0].detail == "LimitBar: no reading — The limitbar command was not found.")
    // Distinct from the loading column, which means "no answer yet", not "failed".
    #expect(columns[0] != MenuBarStatus.loadingColumn)
}

@Test func theFailureColumnCarriesTheReasonIntoTheTooltipAndAccessibilityLabel() {
    let message = "limitbar speaks schema v2; this app expects v1."
    #expect(
        MenuBarStatus.tooltip(for: .empty, error: message, now: now)
            == "LimitBar: no reading — \(message)"
    )
    #expect(
        MenuBarStatus.accessibilityLabel(for: .empty, error: message, now: now)
            == "LimitBar: no reading — \(message)"
    )
}

@Test func aBlankErrorIsTreatedAsNoErrorRatherThanAnEmptyReason() {
    #expect(MenuBarStatus.columns(for: .empty, error: "", now: now) == [MenuBarStatus.loadingColumn])
    #expect(MenuBarStatus.columns(for: .empty, error: "   \n", now: now) == [MenuBarStatus.loadingColumn])
}

@Test func aFailedRefreshKeepsTheLastReadingButStopsItPassingForFresh() {
    // The document is the previous good one; only the refresh failed. Blanking
    // the bar would be worse than showing an older number, but showing it
    // unmarked would claim a freshness we do not have.
    let subject = document([
        ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)]),
        ProviderUsage(provider: "codex", status: .ok, windows: [fiveHour(remaining: 40)])
    ])
    let columns = MenuBarStatus.columns(for: subject, error: "limitbar did not respond in time.", now: now)

    #expect(columns.map(\.id) == ["claude", "codex"])
    #expect(columns[0].top?.text == "4h 83%·")
    #expect(columns[0].stale)
    #expect(columns[0].detail.hasSuffix("(last good reading; limitbar is failing)"))
    #expect(columns[1].stale)
}

@Test func anAlreadyCachedReadingKeepsSayingCachedWhenTheCLIAlsoFails() {
    let subject = document([
        ProviderUsage(provider: "claude", status: .rateLimited, stale: true, windows: [fiveHour(remaining: 73)])
    ])
    let columns = MenuBarStatus.columns(for: subject, error: "limitbar did not respond in time.", now: now)

    #expect(columns[0].top?.text == "4h 73%·")  // not doubled
    #expect(columns[0].detail.hasSuffix("(cached)"))
}

@Test func aRecoveredRefreshDropsTheDegradedMarkAgain() {
    let subject = document([
        ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)])
    ])
    #expect(MenuBarStatus.columns(for: subject, error: nil, now: now)[0].stale == false)
    #expect(MenuBarStatus.columns(for: subject, now: now)[0].top?.text == "4h 83%")
}

@Test func aFailedRefreshAlsoMarksColumnsThatHaveNoWindowToShow() {
    let columns = MenuBarStatus.columns(
        for: document([ProviderUsage(provider: "codex", status: .upstreamError, windows: [])]),
        error: "limitbar did not respond in time.",
        now: now
    )
    #expect(columns.map(\.id) == ["codex"])
    #expect(columns[0].stale)
}

// MARK: - Width budget

/// One unit per character, code included — enough to exercise trimming order.
private func fakeWidth(_ column: MenuBarStatus.Column) -> Double {
    Double(column.code.count + max(column.top?.text.count ?? 0, column.bottom?.text.count ?? 0))
}

@Test func trimmingDropsTrailingColumnsBeforeThePinnedOne() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(
                provider: "claude",
                status: .ok,
                windows: [fiveHour(remaining: 83), weekly(remaining: 6)]
            ),
            ProviderUsage(provider: "codex", status: .ok, windows: [fiveHour(remaining: 40)])
        ]),
        now: now
    )
    #expect(columns.count == 2)

    let fitted = MenuBarStatus.fit(columns, budget: 10, spacing: 1, width: fakeWidth)
    #expect(fitted.map(\.id) == ["claude"])
    #expect(MenuBarStatus.totalWidth(of: fitted, spacing: 1, width: fakeWidth) <= 10)
}

@Test func thePinnedColumnIsNeverTrimmedEvenWhenItAloneOverflows() {
    let columns = MenuBarStatus.columns(
        for: document([ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)])]),
        now: now
    )
    let fitted = MenuBarStatus.fit(columns, budget: 1, spacing: 1, width: fakeWidth)
    #expect(fitted.map(\.id) == ["claude"])
}

@Test func aCrowdedBarTrimsRightToLeftAndAlwaysKeepsTheClaudeColumn() {
    let others = (1...6).map {
        ProviderUsage(provider: "p\($0)", status: .ok, windows: [fiveHour(remaining: 10 * $0)])
    }
    let columns = MenuBarStatus.columns(
        for: document([ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)])] + others),
        now: now
    )
    #expect(columns.count == 7)

    for budget in stride(from: 0.0, through: 80.0, by: 1.0) {
        let fitted = MenuBarStatus.fit(columns, budget: budget, spacing: 1, width: fakeWidth)
        #expect(fitted.first?.id == "claude")
        #expect(fitted.first?.isPinned == true)
        // Trimming only ever removes a suffix, never reorders.
        #expect(fitted.map(\.id) == Array(columns.prefix(fitted.count)).map(\.id))
    }
}

@Test func aRowThatAlreadyFitsIsLeftAlone() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)]),
            ProviderUsage(provider: "codex", status: .ok, windows: [fiveHour(remaining: 40)])
        ]),
        now: now
    )
    #expect(MenuBarStatus.fit(columns, budget: 1000, spacing: 8, width: fakeWidth) == columns)
}

// MARK: - Tooltip

@Test func tooltipLeadsWithTheFiveHourLineAndMatchesTheColumns() {
    let subject = document([
        ProviderUsage(
            provider: "codex",
            status: .ok,
            windows: [window(key: "monthly", label: "30d", minutes: 43200, remaining: 0, resetsIn: 29 * 86_400)]
        ),
        ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)])
    ])

    let lines = MenuBarStatus.tooltip(for: subject, now: now).split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines[0] == "Claude Code 5h: 83% left, resets in 4h")
    #expect(lines[1] == "Codex 30d: 0% left, resets in 29d")
    // The tooltip is generated from the same columns as the image, so the two
    // can never disagree about what the bar is claiming.
    #expect(lines == MenuBarStatus.columns(for: subject, now: now).flatMap(\.details))
}

@Test func tooltipHasOneLinePerRowNotOnePerColumn() {
    let subject = document([
        ProviderUsage(
            provider: "claude",
            status: .ok,
            windows: [fiveHour(remaining: 83), weekly(remaining: 20)]
        ),
        ProviderUsage(provider: "codex", status: .ok, windows: [weekly(remaining: 40, resetsIn: 6 * 86_400)])
    ])
    #expect(
        MenuBarStatus.tooltip(for: subject, now: now) == """
        Claude Code 5h: 83% left, resets in 4h
        Claude Code 7d: 20% left, resets in 3d
        Codex 7d: 40% left, resets in 6d
        """
    )
}

@Test func tooltipNamesTheRemedyWhenTheFiveHourReadingIsMissing() {
    let subject = document([ProviderUsage(provider: "claude", status: .authExpired, windows: [])])
    let tooltip = MenuBarStatus.tooltip(for: subject, now: now)
    #expect(tooltip.hasPrefix("Claude Code 5h: no reading (auth_expired)"))
    #expect(tooltip.contains("refresh"))
}

@Test func tooltipSaysResettingNowRatherThanResetsInNow() {
    let subject = document([
        ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 0, resetsIn: 10)])
    ])
    #expect(MenuBarStatus.tooltip(for: subject, now: now) == "Claude Code 5h: 0% left, resetting now")
}

@Test func accessibilityLabelIsTheSameFactsOnOneLine() {
    let subject = document([
        ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 83)]),
        ProviderUsage(provider: "codex", status: .ok, windows: [fiveHour(remaining: 40)])
    ])
    #expect(
        MenuBarStatus.accessibilityLabel(for: subject, now: now)
            == "Claude Code 5h: 83% left, resets in 4h, Codex 5h: 40% left, resets in 4h"
    )
}

// MARK: - Against the golden fixture

@Test func goldenFixtureRendersClaudeFirstDespiteATighterCodexWeekly() throws {
    // The fixture is generated by the Python serializer: codex/weekly at 12% is
    // the document-wide `tightest`, and claude is stale and rate limited.
    guard let url = Bundle.module.url(forResource: "sample", withExtension: "json", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: "sample", withExtension: "json")
    else {
        Issue.record("sample.json fixture missing")
        return
    }
    let subject = try UsageDocument.decode(from: Data(contentsOf: url))
    let at = Date(timeIntervalSince1970: 1_786_118_400)  // the fixture's generated_at
    let columns = MenuBarStatus.columns(for: subject, now: at)

    #expect(subject.tightest?.provider == "codex")
    #expect(columns.map(\.id) == ["claude", "codex"])
    #expect(columns[0].top?.text == "5h 73%·")  // stale mark, not a dropped column
    #expect(columns[0].bottom == nil)           // claude reports no weekly here
    // Codex reports both, so its column fills in without any layout change.
    #expect(columns[1].top?.text == "2h 55%")
    #expect(columns[1].bottom?.text == "3d 12%")
    #expect(columns[1].bottom?.severity == .warning)
}

// MARK: - The session row's countdown

@Test func theSessionRowCountsDownRatherThanNamingItsWindow() {
    // The bug this fixes: the row said `5h` for the whole five hours, so the one
    // number that moves fastest was the one the bar never showed.
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 48, resetsIn: 3 * 3600)])
        ]),
        now: now
    )
    #expect(columns[0].top?.text == "3h 48%")
    // The window's real name still survives where there is room for it.
    #expect(columns[0].detail.contains("Claude Code 5h:"))
}

@Test func aSessionRowInsideTheLastHourCountsInMinutes() {
    let columns = MenuBarStatus.columns(
        for: document([
            ProviderUsage(provider: "claude", status: .ok, windows: [fiveHour(remaining: 9, resetsIn: 47 * 60)])
        ]),
        now: now
    )
    #expect(columns[0].top?.text == "47m 9%")
    // 9% remaining is the orange band; `critical` starts below 5%.
    #expect(columns[0].top?.severity == .warning)
}

@Test func unsubscribedClaudeIsHiddenAcrossDisplaySurfaces() throws {
    let inactive = try #require(UsageStatus(rawValue: "no_subscription"))
    let claude = ProviderUsage(provider: "claude", status: inactive, windows: [])
    let codex = ProviderUsage(provider: "codex", status: .ok, windows: [weekly(remaining: 80)])
    let value = document([claude, codex])
    #expect(value.providersInDisplayOrder.map(\.provider) == ["codex"])
    #expect(MenuBarStatus.columns(for: value).map(\.id) == ["codex"])
    #expect(WidgetSnapshot(document: value).entries.map(\.id) == ["codex"])
    for status in [UsageStatus.authBlocked, .authExpired, .offline, .rateLimited] {
        let failed = document([ProviderUsage(provider: "claude", status: status)])
        #expect(failed.providersInDisplayOrder.count == 1)
        #expect(MenuBarStatus.columns(for: failed).count == 1)
        #expect(WidgetSnapshot(document: failed).entries.count == 1)
    }
}

@Test func unconfiguredProvidersAreHiddenAndReturnAfterSignIn() {
    for id in ["claude", "codex"] {
        for status in [UsageStatus.authMissing, .unsupported, .noSubscription] {
            // Even last-good cached windows must not resurrect a removed account.
            let hidden = ProviderUsage(provider: id, status: status, stale: true,
                                       windows: [weekly(remaining: 80)])
            let value = document([hidden])
            #expect(value.providers.count == 1)
            #expect(value.providersInDisplayOrder.isEmpty)
            #expect(WidgetSnapshot(document: value).entries.isEmpty)
            #expect(MenuBarStatus.columns(for: value) == [MenuBarStatus.unconfiguredColumn])
        }
        for status in [UsageStatus.ok, .authExpired, .authBlocked, .offline, .rateLimited, .upstreamError, .unknown] {
            let value = document([ProviderUsage(provider: id, status: status)])
            #expect(value.providersInDisplayOrder.map(\.provider) == [id])
            #expect(WidgetSnapshot(document: value).entries.map(\.id) == [id])
            #expect(MenuBarStatus.columns(for: value).map(\.id) == [id])
        }
    }
}

@Test func oneUnconfiguredProviderDoesNotHideTheOther() {
    for hiddenID in ["claude", "codex"] {
        let visibleID = hiddenID == "claude" ? "codex" : "claude"
        let value = document([
            ProviderUsage(provider: hiddenID, status: .authMissing),
            ProviderUsage(provider: visibleID, status: .ok, windows: [weekly(remaining: 80)])
        ])
        #expect(value.providersInDisplayOrder.map(\.provider) == [visibleID])
        #expect(MenuBarStatus.columns(for: value).map(\.id) == [visibleID])
        #expect(WidgetSnapshot(document: value).entries.map(\.id) == [visibleID])
    }
}
