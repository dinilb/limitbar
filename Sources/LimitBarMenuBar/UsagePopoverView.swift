import LimitBarDomain
import SwiftUI

/// The dropdown shown when the status item is clicked.
struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = store.lastError {
                CalloutView(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }

            if store.document.providersInDisplayOrder.isEmpty {
                CalloutView(
                    text: store.document.generatedAt == nil
                        ? "No usage data yet. Refresh to check for providers."
                        : "No configured providers found. Sign in to Claude Code or Codex, then refresh.",
                    systemImage: "clock",
                    tint: .secondary
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.document.providersInDisplayOrder) { provider in
                        ProviderRow(provider: provider)
                    }
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("LimitBar")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let refreshed = store.lastRefreshedAt {
                Text(refreshed, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // The one control whose whole purpose is "get me a reading now", so the
            // one place a Keychain dialog is an answer rather than an ambush.
            Button("Refresh") { store.refresh(force: true, userInitiated: true) }
                .disabled(store.isRefreshing)
            commandLineToolMenu
            Spacer()
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }

    @ViewBuilder
    private var commandLineToolMenu: some View {
        Menu {
            switch store.commandLineToolStatus {
            case .unavailable:
                Text("Bundled helper unavailable")
            case .notInstalled:
                Button("Install Command Line Tool…") { store.installCommandLineTool() }
            case .installed:
                Button("Reinstall Command Line Tool…") { store.installCommandLineTool() }
                Button("Remove Command Line Tool") { store.removeCommandLineTool() }
            case .conflict:
                Button("Replace Existing Command Line Tool…") { store.installCommandLineTool() }
            }
        } label: {
            Image(systemName: "terminal")
                .help(store.commandLineToolStatus.description)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct ProviderRow: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                if let plan = provider.plan, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if provider.stale {
                    Text("CACHED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            if provider.windows.isEmpty {
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(provider.windows) { window in
                    WindowRow(window: window)
                }
                if provider.status != .ok {
                    Text(statusLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(provider.notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Prefer the actionable remedy over the raw upstream message.
    private var statusLine: String {
        if let remedy = provider.status.remedy(for: provider.provider) {
            return remedy
        }
        if let message = provider.error?.message, !message.isEmpty {
            return message
        }
        return "No reading available."
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            QuotaBar(remainingPercent: window.remainingPercent)

            Text(window.remainingPercent == nil ? "?" : "\(window.remainingPercent ?? 0)%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 38, alignment: .trailing)

            Text(window.countdownText())
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var color: Color {
        Color(severity: UsageSeverity(remainingPercent: window.remainingPercent))
    }
}

struct QuotaBar: View {
    let remainingPercent: Int?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                if let remainingPercent {
                    Capsule()
                        .fill(Color(severity: UsageSeverity(remainingPercent: remainingPercent)))
                        .frame(width: geometry.size.width * CGFloat(max(0, min(100, remainingPercent))) / 100)
                }
            }
        }
        .frame(height: 5)
    }
}

struct CalloutView: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Color {
    init(severity: UsageSeverity) {
        switch severity {
        case .critical: self = .red
        case .warning: self = .orange
        case .caution: self = .yellow
        case .normal: self = .green
        case .unknown: self = .secondary
        }
    }
}
