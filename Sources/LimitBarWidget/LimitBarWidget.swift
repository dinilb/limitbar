import LimitBarDomain
import SwiftUI
import WidgetKit

/// WidgetKit desktop / Notification Center widget.
///
/// A widget extension is sandboxed and short-lived, so it never spawns the CLI
/// and never reads a credential. Its only input is the snapshot file the menu-bar
/// app writes after each refresh (see `WidgetSnapshot`).
///
/// `@main` is compiled in only for the real extension. `swift build` builds these
/// sources as a plain library purely to type-check them; `scripts/build-app.sh`
/// recompiles them with `-DWIDGET_EXTENSION` to produce the `.appex`.
#if WIDGET_EXTENSION
@main
#endif
struct LimitBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        LimitBarQuotaWidget()
    }
}

struct LimitBarQuotaWidget: Widget {
    let kind = WidgetSnapshot.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            LimitBarWidgetView(entry: entry)
        }
        .configurationDisplayName("LimitBar")
        .description("Remaining Claude Code and Codex quota from the local limitbar CLI.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageTimelineEntry {
        UsageTimelineEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageTimelineEntry) -> Void) {
        completion(UsageTimelineEntry(date: Date(), snapshot: WidgetSnapshot.readBestAvailable() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageTimelineEntry>) -> Void) {
        let now = Date()
        let entry = UsageTimelineEntry(date: now, snapshot: WidgetSnapshot.readBestAvailable() ?? .empty)
        // The app drives real updates via reloadAllTimelines(); this is only a
        // backstop for the case where the app is not running.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(300))))
    }
}

struct LimitBarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageTimelineEntry

    var body: some View {
        content.containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        if entry.snapshot.entries.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "chart.bar").foregroundStyle(.secondary)
                Text("No usage data").font(.caption.weight(.semibold))
                Text("Open LimitBar to refresh.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if family == .systemSmall {
            smallBody
        } else {
            regularBody
        }
    }

    /// The small family has room for one number, so it shows the single window
    /// closest to exhaustion across both providers.
    @ViewBuilder
    private var smallBody: some View {
        let tightest = entry.snapshot.tightestEntry
        VStack(alignment: .leading, spacing: 2) {
            Text("LimitBar").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let provider = tightest, let window = provider.tightest {
                Text(window.remainingText + (window.remainingPercent == nil ? "" : "%"))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(WidgetTint.value(window.remainingPercent))
                Text("\(provider.code) · \(window.label) left")
                    .font(.caption2)
                Text("resets \(window.countdownText())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(unavailableText(for: tightest)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            staleFooter
        }
    }

    @ViewBuilder
    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LimitBar").font(.headline)
            // Every window gets its own row. Showing only the tightest one hid
            // the fact that Claude has two limits that run down at completely
            // different rates: the session empties in an afternoon, the weekly
            // over days, and either can be the one that stops you.
            ForEach(entry.snapshot.entries) { provider in
                ProviderWidgetBlock(provider: provider)
            }
            Spacer(minLength: 0)
            staleFooter
        }
    }

    @ViewBuilder
    private var staleFooter: some View {
        HStack(spacing: 3) {
            if entry.snapshot.entries.contains(where: { $0.stale }) {
                Image(systemName: "clock.arrow.circlepath").font(.caption2)
            }
            Text(entry.snapshot.updatedAt, style: .relative)
            Text("ago")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func unavailableText(for provider: WidgetSnapshot.Entry?) -> String {
        guard let provider else { return "Unavailable" }
        return provider.status.remedy(for: provider.id) ?? "Unavailable"
    }
}

/// One provider: a code, then a row per window.
private struct ProviderWidgetBlock: View {
    let provider: WidgetSnapshot.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let windows = provider.windowsInDisplayOrder
            if windows.isEmpty {
                HStack(spacing: 6) {
                    Text(provider.code)
                        .font(.caption.weight(.bold))
                        .frame(width: 22, alignment: .leading)
                    Text(provider.status.remedy(for: provider.id) ?? "Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    // The code labels the block, not each row, so it appears
                    // once and the rows beneath it stay aligned under it.
                    WindowGaugeRow(
                        code: index == 0 ? provider.code : "",
                        window: window,
                        stale: provider.stale
                    )
                }
            }
        }
    }
}

/// `Cl  5h ▓▓▓▓▓▓░░  57%  ↻ 2h` — label, gauge, remaining, time to reset.
private struct WindowGaugeRow: View {
    let code: String
    let window: WidgetSnapshot.WindowEntry
    let stale: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(code)
                .font(.caption.weight(.bold))
                .frame(width: 22, alignment: .leading)

            Text(window.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            ProgressView(value: Double(window.remainingPercent ?? 0), total: 100)
                .tint(WidgetTint.bar(window.remainingPercent))

            Text(window.remainingText + (window.remainingPercent == nil ? "" : "%"))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(WidgetTint.value(window.remainingPercent))
                .frame(width: 36, alignment: .trailing)

            // Each window resets on its own clock — the session several times a
            // day, the weekly once — so the countdown belongs per row rather
            // than once per provider.
            HStack(spacing: 1) {
                Image(systemName: "arrow.clockwise").font(.system(size: 7))
                Text(window.countdownText()).font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
        }
        .opacity(stale ? 0.6 : 1)
    }
}

/// Shared colour ramp so the widget and the menu bar grade the same number the
/// same way. Unknown is deliberately grey, never green.
enum WidgetTint {
    /// Gauge fill. Carries the whole ramp — a filled bar renders yellow
    /// perfectly well at any size.
    static func bar(_ remainingPercent: Int?) -> Color {
        switch UsageSeverity(remainingPercent: remainingPercent) {
        case .critical: return .red
        case .warning: return .orange
        case .caution: return .yellow
        case .normal: return .green
        case .unknown: return .secondary
        }
    }

    /// The number itself. Yellow text on a light widget background is close to
    /// unreadable, so caution is left to the gauge and only warning and
    /// critical tint the digits; healthy stays plain.
    static func value(_ remainingPercent: Int?) -> Color {
        switch UsageSeverity(remainingPercent: remainingPercent) {
        case .critical: return .red
        case .warning: return .orange
        case .caution, .normal: return .primary
        case .unknown: return .secondary
        }
    }
}
