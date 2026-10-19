import Foundation

/// What the menu bar shows, computed as plain data.
///
/// The bar is a two-row grid whose **columns are providers** and whose **rows
/// are windows**:
///
///     Cl 3h 30%   Cx
///        3d 20%      6d 40%
///
/// - Row 1 is always the five-hour session window, led by its *countdown to
///   reset*.
/// - Row 2 is always the provider's longest-running bucket — weekly, monthly —
///   led by the same countdown. Row position already says which window it is,
///   so in both rows the label slot buys a more useful number. A row names its
///   window instead only when it has no reset time to count down from.
/// - The provider code is drawn small, once, at the head of row 1, and the two
///   rows share a left edge under it.
/// - A cell whose provider has no such window is left **blank**. Codex
///   reporting no five-hour bucket must read as "Codex has one window", not as
///   a failure, so nothing is drawn there at all.
///
/// The selection rule lives here rather than in the AppKit renderer because it
/// is the part worth testing, and testing it should not need a window server.
///
/// Configured Claude Code owns the first column and keeps its five-hour cell
/// even during temporary failures. Unconfigured providers are omitted from all
/// display surfaces. Nothing but a genuine five-hour window occupies that cell.
public enum MenuBarStatus {
    public static let claudeProviderID = "claude"

    /// Names the session window when a countdown is unavailable: the pinned row
    /// exists even when there is no window object to take a reset time from.
    public static let fiveHourLabel = "5h"

    /// Appended to a reading served from the CLI's last-good cache.
    public static let staleMark = "·"

    /// Stands in for a value the CLI did not report at all, as opposed to `?`,
    /// which means "reported, but unreadable".
    public static let absentMark = "—"

    /// The CLI itself did not answer — distinct from `absentMark`, which means
    /// the CLI answered and had nothing to say about Claude.
    public static let failedMark = "×"

    /// One drawn row inside a column.
    public struct Reading: Equatable, Sendable {
        /// `5h` on the top row; a reset countdown such as `3d` on the bottom.
        /// Empty on the loading column, which has no window to describe.
        public let lead: String

        /// `30%`, or one of the marks above when there is no number.
        public let value: String

        public let severity: UsageSeverity
        public let stale: Bool

        public init(lead: String, value: String, severity: UsageSeverity, stale: Bool) {
            self.lead = lead
            self.value = value
            self.severity = severity
            self.stale = stale
        }

        /// The row as one string, which is both what gets drawn and what the
        /// width budget measures.
        public var text: String { lead.isEmpty ? value : "\(lead) \(value)" }

        /// The same reading with the cache mark appended. Every reading in a
        /// column shares one staleness, so only the column's first row carries
        /// the mark — repeating it on the second says nothing new and puts up
        /// to four dots in a bar that is trying to be quiet.
        func marked() -> Reading {
            Reading(lead: lead, value: value + staleMark, severity: severity, stale: stale)
        }
    }

    /// One provider's column: a small code with up to two readings under it.
    ///
    /// Either reading may be `nil`, which draws nothing. Both are `nil` for the generic
    /// unconfigured state. A visible provider with no windows gets a status badge.
    public struct Column: Equatable, Sendable, Identifiable {
        /// The provider id, e.g. `claude`. Used by tests and by the renderer's
        /// fit pass; never shown.
        public let id: String

        /// Two-letter provider code, drawn small at the head of the top row.
        public let code: String

        /// The five-hour row.
        public let top: Reading?

        /// The long-window row.
        public let bottom: Reading?

        /// Long form, one line per reading, for the tooltip and the
        /// accessibility label.
        public let details: [String]

        /// True only for Claude's column. The renderer never drops it when
        /// trimming to width.
        public let isPinned: Bool

        public init(
            id: String,
            code: String,
            top: Reading?,
            bottom: Reading?,
            details: [String],
            isPinned: Bool
        ) {
            self.id = id
            self.code = code
            self.top = top
            self.bottom = bottom
            self.details = details
            self.isPinned = isPinned
        }

        /// This column's lines as one tooltip fragment.
        public var detail: String { details.joined(separator: "\n") }

        /// True when any reading in the column is older than a live one.
        public var stale: Bool { (top?.stale ?? false) || (bottom?.stale ?? false) }
    }

    /// Shown before the first refresh completes. Distinct from "Claude reported
    /// nothing": there is genuinely no document yet.
    public static let loadingColumn = Column(
        id: "loading",
        code: "AI",
        top: Reading(lead: "", value: "…", severity: .unknown, stale: false),
        bottom: nil,
        details: ["LimitBar: waiting for the first reading."],
        isPinned: false
    )

    public static let unconfiguredColumn = Column(
        id: "unconfigured", code: "AI",
        top: nil, bottom: nil,
        details: ["LimitBar: no configured providers found."], isPinned: false
    )

    // MARK: - Layout

    /// - Parameter error: the last `limitbar` invocation's failure, if it failed.
    ///   Before the first success this is what the pinned column reports; after
    ///   one, the previous document stays on screen but is marked stale, since
    ///   its numbers are older than a fresh reading would be.
    public static func columns(
        for document: UsageDocument,
        error: String? = nil,
        now: Date = Date()
    ) -> [Column] {
        let failure = error?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        // `UsageDocument.empty` is the pre-refresh placeholder, not a reading.
        guard document.generatedAt != nil || !document.providers.isEmpty else {
            return [failure.map(failureColumn(message:)) ?? loadingColumn]
        }

        let degraded = failure != nil
        let columns = document.providersInDisplayOrder.map { provider in
            column(for: provider, now: now, degraded: degraded,
                   isPinned: provider.provider == claudeProviderID)
        }
        return columns.isEmpty ? [unconfiguredColumn] : columns
    }

    /// One line per reading, in bar order.
    public static func tooltip(
        for document: UsageDocument,
        error: String? = nil,
        now: Date = Date()
    ) -> String {
        columns(for: document, error: error, now: now).flatMap(\.details).joined(separator: "\n")
    }

    public static func accessibilityLabel(
        for document: UsageDocument,
        error: String? = nil,
        now: Date = Date()
    ) -> String {
        columns(for: document, error: error, now: now).flatMap(\.details).joined(separator: ", ")
    }

    /// Drop trailing columns until the row fits `budget`.
    ///
    /// The pinned column is never dropped. If it alone overflows we hand it back
    /// oversized: a wide status item beats a missing five-hour reading, and the
    /// caller has no better option than to draw it.
    public static func fit(
        _ columns: [Column],
        budget: Double,
        spacing: Double,
        width: (Column) -> Double
    ) -> [Column] {
        var kept = columns
        while kept.count > 1, totalWidth(of: kept, spacing: spacing, width: width) > budget {
            guard kept.last?.isPinned == false else { break }
            kept.removeLast()
        }
        return kept
    }

    public static func totalWidth(of columns: [Column], spacing: Double, width: (Column) -> Double) -> Double {
        guard !columns.isEmpty else { return 0 }
        return columns.reduce(0) { $0 + width($1) } + spacing * Double(columns.count - 1)
    }

    // MARK: - Column construction

    /// A collection failure before provider configuration is known.
    private static func failureColumn(message: String) -> Column {
        Column(
            id: "error", code: "AI",
            top: Reading(lead: "", value: failedMark, severity: .unknown, stale: false),
            bottom: nil,
            details: ["LimitBar: no reading — \(message)"],
            isPinned: false
        )
    }

    private static func column(
        for provider: ProviderUsage,
        now: Date,
        degraded: Bool,
        isPinned: Bool
    ) -> Column {
        let stale = provider.stale || degraded
        var details: [String] = []

        // Top row: the five-hour window and nothing else. Substituting a longer
        // bucket here would put a weekly number in the session row.
        var top: Reading?
        if let window = provider.fiveHourWindow {
            top = reading(lead: sessionLead(for: window, now: now), window: window, stale: stale)
            details.append(detail(provider: provider, window: window, now: now, degraded: degraded))
        } else if isPinned {
            // Claude's cell is pinned, so it is drawn even with no window to
            // draw — carrying the failure class instead of a borrowed number.
            top = Reading(
                lead: fiveHourLabel,
                value: absentValue(for: provider),
                severity: .unknown,
                stale: stale
            )
            details.append(missingWindowDetail(for: provider, window: fiveHourLabel))
        }

        // Bottom row: the long window, led by its countdown.
        var bottom: Reading?
        if let window = longWindow(of: provider) {
            bottom = reading(lead: window.countdownText(now: now), window: window, stale: stale)
            details.append(detail(provider: provider, window: window, now: now, degraded: degraded))
        }

        // A provider with no readable window at all still occupies its column
        // and still says why.
        if top == nil, bottom == nil {
            top = Reading(lead: "", value: provider.status.badge, severity: .unknown, stale: stale)
            details.append(missingWindowDetail(for: provider, window: nil))
        }

        // One cache mark per column, on whichever row comes first — Codex's top
        // row is empty, so the mark has to be able to fall through to the
        // bottom one rather than disappearing with it.
        if stale {
            if top != nil {
                top = top?.marked()
            } else {
                bottom = bottom?.marked()
            }
        }

        return Column(
            id: provider.provider,
            code: provider.compactCode,
            top: top,
            bottom: bottom,
            details: details,
            isPinned: isPinned
        )
    }

    /// The cache mark is not applied here — `column(for:…)` adds it once, to
    /// the column's first row.
    private static func reading(lead: String, window: UsageWindow, stale: Bool) -> Reading {
        Reading(
            lead: lead,
            value: window.remainingBadge,
            severity: UsageSeverity(remainingPercent: window.remainingPercent),
            stale: stale
        )
    }

    /// The top row's lead: how long until the session window resets.
    ///
    /// Falls back to naming the window when there is no reset time to count down
    /// from. `?` in the label slot would say strictly less than `5h` does, and
    /// the row still has a percentage worth reading.
    private static func sessionLead(for window: UsageWindow, now: Date) -> String {
        let countdown = window.countdownText(now: now)
        return countdown == "?" ? fiveHourLabel : countdown
    }

    /// The bottom row's window: the tightest bucket that is not the five-hour
    /// one, falling back to the first such bucket when none of them carries a
    /// reading. `tightestNonFiveHourWindow` deliberately ignores unreadable
    /// windows, but a window that exists and cannot be read still earns a row
    /// saying `?` — the alternative is a blank cell that reads as "no weekly
    /// limit", which is a different and wrong claim.
    private static func longWindow(of provider: ProviderUsage) -> UsageWindow? {
        provider.tightestNonFiveHourWindow ?? provider.windows.first { !$0.isFiveHour }
    }

    /// What to draw in the pinned five-hour cell when there is no five-hour
    /// window: the failure class when the provider named one, otherwise "the
    /// CLI answered and simply had nothing to say about this window".
    private static func absentValue(for provider: ProviderUsage) -> String {
        switch provider.status {
        case .ok, .unknown: return absentMark
        default: return provider.status.badge
        }
    }

    // MARK: - Long form

    private static func detail(
        provider: ProviderUsage,
        window: UsageWindow,
        now: Date,
        degraded: Bool
    ) -> String {
        let amount = window.remainingPercent.map { "\($0)% left" } ?? "no reading"
        // The bar spends the long row's label slot on a countdown, so the
        // tooltip is the only place the window's real name survives. Keep it.
        var line = "\(provider.displayName) \(window.label): \(amount), \(resetPhrase(for: window, now: now))"
        // The countdown stays honest on its own — it is derived from `resets_at`
        // — but the percentage does not, so say which kind of old it is.
        if provider.stale {
            line += " (cached)"
        } else if degraded {
            line += " (last good reading; limitbar is failing)"
        }
        return line
    }

    private static func resetPhrase(for window: UsageWindow, now: Date) -> String {
        switch window.countdownText(now: now) {
        case "?": return "reset time unknown"
        case "now": return "resetting now"
        case let countdown: return "resets in \(countdown)"
        }
    }

    private static func missingWindowDetail(for provider: ProviderUsage, window: String?) -> String {
        let label = window.map { " \($0)" } ?? ""
        var line = "\(provider.displayName)\(label): no reading (\(provider.status.rawValue))"
        if let remedy = provider.status.remedy(for: provider.provider) {
            line += " — \(remedy)"
        } else if let message = provider.error?.message, !message.isEmpty {
            line += " — \(message)"
        }
        return line
    }
}

private extension String {
    /// `nil` for the empty string, so a blank error is treated as no error at
    /// all rather than producing a column whose reason reads `no reading — `.
    var nonEmpty: String? { isEmpty ? nil : self }
}
