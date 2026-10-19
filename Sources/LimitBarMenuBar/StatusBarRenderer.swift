import LimitBarDomain
import AppKit

/// Draws the compact status-bar grid.
///
/// One column per provider. The provider code labels the column from its
/// vertical centre, and the readings sit in a block to its right:
///
///     Cl 5h 57%   Cx 6d 83%
///        6d 97%
///
/// Every glyph is the same font, the same size and — while nothing is running
/// low — the same colour. A column with one reading centres it on the strip
/// rather than stranding it on the lower half, so Codex's single weekly lines
/// up with its own code instead of hanging below it.
///
/// Colour is the one exception to the uniformity, and it is reserved for the
/// thing uniformity cannot express: a number that is running out. See
/// `UsageSeverity` for the ramp.
///
/// Which columns exist, and in what order, is decided by `MenuBarStatus` — this
/// file only turns them into pixels. The one layout rule it owns is the width
/// budget below, which trims from the right so a chatty Codex column cannot
/// push the Claude five-hour reading out of the bar.
@MainActor
enum StatusBarRenderer {
    /// One font for everything. Monospaced digits keep the columns from
    /// twitching as the numbers tick.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let codeGap: CGFloat = 3
    private static let columnSpacing: CGFloat = 8
    private static let rowSpacing: CGFloat = 1
    private static let height: CGFloat = 22

    /// Widest row we will ask the menu bar for. macOS silently hides status
    /// items when the bar fills up, so staying narrow is what keeps the pinned
    /// column on screen next to a full complement of other apps.
    static let maxWidth: CGFloat = 150

    /// `systemYellow` is tuned for fills, not for 9pt text: on a light menu bar
    /// it all but disappears, and a caution the user cannot read is worse than
    /// no caution at all. Amber keeps the "one step below orange" reading while
    /// staying legible, so this band is resolved per appearance rather than
    /// taken raw. The other bands are legible either way.
    private static let cautionColor = NSColor(name: "usageCaution") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.72, green: 0.50, blue: 0.0, alpha: 1)
    }

    static func image(for document: UsageDocument, error: String? = nil, now: Date = Date()) -> NSImage {
        image(forColumns: MenuBarStatus.columns(for: document, error: error, now: now))
    }

    static func placeholderImage() -> NSImage {
        image(forColumns: [MenuBarStatus.loadingColumn])
    }

    static func tooltip(for document: UsageDocument, error: String? = nil, now: Date = Date()) -> String {
        MenuBarStatus.tooltip(for: document, error: error, now: now)
    }

    /// Rendered width of one column: the code, the gap, and whichever reading
    /// is widest.
    static func width(of column: MenuBarStatus.Column) -> Double {
        Double(ceil(indent(of: column) + readingWidth(of: column)))
    }

    /// A reading is coloured only when it is running out. Everything else is
    /// one flat label colour, including the provider code — a bar that is
    /// quiet on a normal day is the whole point of the layout.
    static func tint(for reading: MenuBarStatus.Reading) -> NSColor {
        let base: NSColor
        switch reading.severity {
        case .critical: base = .systemRed
        case .warning: base = .systemOrange
        case .caution: base = cautionColor
        case .normal: base = .labelColor
        // A missing value is not a healthy one, so it does not get to look
        // like the rest of the row.
        case .unknown: base = .secondaryLabelColor
        }
        return reading.stale ? base.withAlphaComponent(0.6) : base
    }

    static func codeTint(for column: MenuBarStatus.Column) -> NSColor {
        column.stale ? NSColor.labelColor.withAlphaComponent(0.6) : .labelColor
    }

    // MARK: - Geometry

    private static var rowHeight: CGFloat { ceil(font.capHeight + 3) }

    private static func indent(of column: MenuBarStatus.Column) -> CGFloat {
        ceil((column.code as NSString).size(withAttributes: [.font: font]).width) + codeGap
    }

    private static func readingWidth(of column: MenuBarStatus.Column) -> CGFloat {
        ceil(rows(of: column).map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
    }

    private static func rows(of column: MenuBarStatus.Column) -> [MenuBarStatus.Reading] {
        [column.top, column.bottom].compactMap { $0 }
    }

    /// Drawing origins for a column's readings, top first.
    ///
    /// A single reading is centred on the strip. That is what lets Codex's lone
    /// weekly sit beside its code rather than under a blank five-hour cell.
    private static func rowOrigins(count: Int) -> [CGFloat] {
        guard count > 1 else { return [(height - rowHeight) / 2] }
        let block = rowHeight * 2 + rowSpacing
        let bottom = (height - block) / 2
        return [bottom + rowHeight + rowSpacing, bottom]
    }

    /// The code sits on the strip's centre line whatever the column holds, so
    /// it reads as a label for the column rather than for its first row.
    private static var codeOrigin: CGFloat { (height - rowHeight) / 2 }

    // MARK: - Drawing

    private static func image(forColumns columns: [MenuBarStatus.Column]) -> NSImage {
        let visible = MenuBarStatus.fit(
            columns,
            budget: Double(maxWidth),
            spacing: Double(columnSpacing),
            width: width(of:)
        )
        guard !visible.isEmpty else { return image(forColumns: [MenuBarStatus.loadingColumn]) }

        let widths = visible.map { CGFloat(width(of: $0)) }
        let totalWidth = widths.reduce(0, +) + columnSpacing * CGFloat(max(0, visible.count - 1))
        let size = NSSize(width: max(24, totalWidth), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, column) in visible.enumerated() {
                draw(column.code, at: NSPoint(x: x, y: codeOrigin), color: codeTint(for: column))

                let readingX = x + indent(of: column)
                let readings = rows(of: column)
                for (reading, y) in zip(readings, rowOrigins(count: readings.count)) {
                    draw(reading.text, at: NSPoint(x: readingX, y: y), color: tint(for: reading))
                }
                x += widths[index] + columnSpacing
            }
            return true
        }

        // Not a template image: the colour *is* the signal.
        image.isTemplate = false
        return image
    }

    private static func draw(_ string: String, at point: NSPoint, color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            .draw(at: point)
    }
}
