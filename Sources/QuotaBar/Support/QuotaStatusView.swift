import AppKit

struct StatusRenderState: Equatable {
    let mode: StatusBarDisplayMode
    let groups: [StatusRenderGroup]
}

struct StatusRenderGroup: Equatable {
    let provider: QuotaProvider
    let rows: [StatusRenderRow]
    var primaryText: String = "--"
    var primaryTint: StatusRowTint = .normal
    var barProgress: Double? = nil
    var barTone: QuotaTone = .neutral
    var hasError: Bool = false
    var primaryNumericPercent: Int? = nil
}

enum QuotaProvider: Hashable {
    case codex, grok, agy

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .agy: return "Antigravity"
        }
    }

    var icon: NSImage {
        switch self {
        case .codex: return Self.codexIcon
        case .grok: return Self.grokIcon
        case .agy: return Self.agyIcon
        }
    }

    private static let codexIcon = loadIcon("CodexProvider", extension: "png")
    private static let grokIcon = loadIcon("GrokProvider", extension: "icns")
    private static let agyIcon = loadIcon("AgyProvider", extension: "png")

    private static func loadIcon(_ name: String, extension ext: String) -> NSImage {
        NSImage(contentsOf: Bundle.module.url(forResource: name, withExtension: ext)!)!
    }
}

struct StatusRenderRow: Equatable {
    let badge: String
    let value: String
    let tint: StatusRowTint
    var colorsValue = false
}

enum StatusRowTint {
    case normal, red, green

    static func daily(_ remainingPercent: Int?) -> StatusRowTint {
        guard let remainingPercent else { return .normal }
        if remainingPercent > 50 { return .green }
        if remainingPercent < 20 { return .red }
        return .normal
    }

    var color: NSColor {
        switch self {
        case .normal: return .labelColor
        case .red: return .systemRed
        case .green: return .systemGreen
        }
    }
}

extension QuotaTone {
    var nsColor: NSColor {
        switch self {
        case .healthy: return .systemGreen
        case .caution: return .systemOrange
        case .critical: return .systemRed
        case .neutral: return .secondaryLabelColor
        }
    }
}

enum QuotaStatusLayout {
    static let horizontalPadding: CGFloat = 3
    static let providerIconSize: CGFloat = 15
    static let providerIconCornerRadius: CGFloat = 3.5
    static let providerGap: CGFloat = 4
    static let groupGap: CGFloat = 10

    // Mode A: Progress bar
    static let progressValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    static let progressMinMetricWidth: CGFloat = 30
    static let progressBarHeight: CGFloat = 2.5

    // Mode B: Compact pill-less dual lines
    static let compactKeyFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    static let compactValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    static let compactKeyWidth: CGFloat = 9
    static let compactKeyGap: CGFloat = 2.5
    static let stackedBadgeFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    struct GroupLayout {
        let iconRect: NSRect
        let metricRect: NSRect
    }

    static func totalWidth(groups: [StatusRenderGroup], mode: StatusBarDisplayMode) -> CGFloat {
        guard !groups.isEmpty else { return 0 }
        let layouts = groupLayouts(groups, mode: mode)
        return ceil((layouts.last?.metricRect.maxX ?? 0) + horizontalPadding)
    }

    static func groupLayouts(_ groups: [StatusRenderGroup], mode: StatusBarDisplayMode) -> [GroupLayout] {
        var x: CGFloat = horizontalPadding
        let height = NSStatusBar.system.thickness
        return groups.map { group in
            let iconRect = NSRect(
                x: x,
                y: pixelAligned((height - providerIconSize) / 2),
                width: providerIconSize,
                height: providerIconSize
            )
            let metricWidth: CGFloat
            switch mode {
            case .progressBar:
                metricWidth = progressMetricWidth(for: group)
            case .compactDual:
                metricWidth = compactDualMetricWidth(rows: group.rows)
            }
            let metricRect = NSRect(x: iconRect.maxX + providerGap, y: 0, width: metricWidth, height: height)
            x = metricRect.maxX + groupGap
            return GroupLayout(iconRect: iconRect, metricRect: metricRect)
        }
    }

    static func progressMetricWidth(for group: StatusRenderGroup) -> CGFloat {
        let text = group.hasError && group.primaryNumericPercent == nil ? "!" : group.primaryText
        let textWidth = ceil(QuotaStatusDrawing.measuredWidth(text, font: progressValueFont))
        return max(progressMinMetricWidth, textWidth + 1)
    }

    static func progressValueRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: 2, width: bounds.width, height: 12.5)
    }

    static func progressTrackRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: bounds.height - 5.5, width: bounds.width, height: progressBarHeight)
    }

    static func compactDualMetricWidth(rows: [StatusRenderRow]) -> CGFloat {
        if let row = rows.first, rows.count == 1 {
            let labelWidth = QuotaStatusDrawing.measuredWidth(row.badge, font: stackedBadgeFont)
            let valWidth = QuotaStatusDrawing.measuredWidth(row.value, font: stackedValueFont)
            return ceil(max(labelWidth, valWidth) + 2)
        }
        let maxValWidth = rows.map { QuotaStatusDrawing.measuredWidth($0.value, font: compactValueFont) }.max() ?? 0
        return ceil(compactKeyWidth + compactKeyGap + maxValWidth + 1)
    }

    static func compactRowYOffsets(count: Int) -> [CGFloat] {
        count == 1 ? [0] : [1.5, 11.5]
    }

    private static func pixelAligned(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}

private enum QuotaStatusDrawing {
    static func drawText(
        _ text: String,
        in bounds: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        verticallyCentered: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        var drawingRect = bounds

        if verticallyCentered {
            let textHeight = NSString(string: text).size(withAttributes: attributes).height
            drawingRect.origin.y = bounds.midY - textHeight / 2
            drawingRect.size.height = textHeight
        }

        NSString(string: text).draw(in: drawingRect, withAttributes: attributes)
    }

    static func drawRoundedIcon(_ icon: NSImage, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            roundedRect: rect,
            xRadius: QuotaStatusLayout.providerIconCornerRadius,
            yRadius: QuotaStatusLayout.providerIconCornerRadius
        ).addClip()
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        NSString(string: text).size(withAttributes: [.font: font]).width
    }
}

enum QuotaStatusImageRenderer {
    static func render(groups: [StatusRenderGroup], mode: StatusBarDisplayMode = .progressBar) -> NSImage {
        let width = QuotaStatusLayout.totalWidth(groups: groups, mode: mode)
        let height = NSStatusBar.system.thickness
        let image = NSImage(size: NSSize(width: width, height: height))
        // Template image adapts automatically to wallpaper-driven light/dark menu bars.
        image.isTemplate = true
        guard width > 0 else { return image }

        image.lockFocusFlipped(true)
        defer { image.unlockFocus() }

        switch mode {
        case .progressBar:
            drawProgressBarTemplate(groups: groups, height: height)
        case .compactDual:
            drawCompactDualTemplate(groups: groups, height: height)
        }

        return image
    }

    private static func drawProgressBarTemplate(groups: [StatusRenderGroup], height: CGFloat) {
        let layouts = QuotaStatusLayout.groupLayouts(groups, mode: .progressBar)
        for (index, (group, layout)) in zip(groups, layouts).enumerated() {
            if index > 0 {
                NSColor.black.withAlphaComponent(0.24).setFill()
                NSRect(x: layout.iconRect.minX - QuotaStatusLayout.groupGap / 2,
                       y: 4.5, width: 0.5, height: height - 9).fill()
            }

            let isColored = group.primaryTint != .normal || (group.hasError && group.primaryNumericPercent == nil)
            if !isColored {
                let text = group.primaryText
                QuotaStatusDrawing.drawText(
                    text,
                    in: QuotaStatusLayout.progressValueRect(in: layout.metricRect),
                    font: QuotaStatusLayout.progressValueFont,
                    color: .black,
                    alignment: .center,
                    verticallyCentered: true
                )
            }

            let trackRect = QuotaStatusLayout.progressTrackRect(in: layout.metricRect)
            NSColor.black.withAlphaComponent(0.22).setFill()
            NSBezierPath(
                roundedRect: trackRect,
                xRadius: trackRect.height / 2,
                yRadius: trackRect.height / 2
            ).fill()
        }
    }

    private static func drawCompactDualTemplate(groups: [StatusRenderGroup], height: CGFloat) {
        let layouts = QuotaStatusLayout.groupLayouts(groups, mode: .compactDual)
        for (index, (group, layout)) in zip(groups, layouts).enumerated() {
            if index > 0 {
                NSColor.black.withAlphaComponent(0.24).setFill()
                NSRect(x: layout.iconRect.minX - QuotaStatusLayout.groupGap / 2,
                       y: 4.5, width: 0.5, height: height - 9).fill()
            }

            let bounds = layout.metricRect
            if let row = group.rows.first, group.rows.count == 1 {
                let badgeRect = NSRect(x: bounds.minX, y: 1, width: bounds.width, height: 8.5)
                let valRect = NSRect(x: bounds.minX, y: 9.5, width: bounds.width, height: bounds.height - 10)
                if row.tint == .normal {
                    QuotaStatusDrawing.drawText(
                        row.badge,
                        in: badgeRect,
                        font: QuotaStatusLayout.stackedBadgeFont,
                        color: NSColor.black.withAlphaComponent(0.58),
                        alignment: .center,
                        verticallyCentered: true
                    )
                }
                if !row.colorsValue || row.tint == .normal {
                    QuotaStatusDrawing.drawText(
                        row.value,
                        in: valRect,
                        font: QuotaStatusLayout.stackedValueFont,
                        color: .black,
                        alignment: .center,
                        verticallyCentered: true
                    )
                }
            } else {
                for (row, y) in zip(group.rows, QuotaStatusLayout.compactRowYOffsets(count: group.rows.count)) {
                    let keyRect = NSRect(x: bounds.minX, y: y, width: QuotaStatusLayout.compactKeyWidth, height: 9.5)
                    let valX = keyRect.maxX + QuotaStatusLayout.compactKeyGap
                    let valRect = NSRect(x: valX, y: y, width: bounds.maxX - valX, height: 9.5)

                    if row.tint == .normal {
                        QuotaStatusDrawing.drawText(
                            row.badge,
                            in: keyRect,
                            font: QuotaStatusLayout.compactKeyFont,
                            color: NSColor.black.withAlphaComponent(0.55),
                            alignment: .left,
                            verticallyCentered: true
                        )
                    }
                    if !row.colorsValue || row.tint == .normal {
                        QuotaStatusDrawing.drawText(
                            row.value,
                            in: valRect,
                            font: QuotaStatusLayout.compactValueFont,
                            color: .black,
                            alignment: .left,
                            verticallyCentered: true
                        )
                    }
                }
            }
        }
    }
}

final class QuotaStatusOverlayView: NSView {
    var mode: StatusBarDisplayMode = .progressBar { didSet { needsDisplay = true } }
    var groups: [StatusRenderGroup] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !groups.isEmpty else { return }

        switch mode {
        case .progressBar:
            drawProgressBarOverlay()
        case .compactDual:
            drawCompactDualOverlay()
        }
    }

    private func drawProgressBarOverlay() {
        let layouts = QuotaStatusLayout.groupLayouts(groups, mode: .progressBar)
        for (group, layout) in zip(groups, layouts) {
            QuotaStatusDrawing.drawRoundedIcon(group.provider.icon, in: layout.iconRect)

            if group.hasError && group.primaryNumericPercent == nil {
                QuotaStatusDrawing.drawText(
                    "!",
                    in: QuotaStatusLayout.progressValueRect(in: layout.metricRect),
                    font: QuotaStatusLayout.progressValueFont,
                    color: .systemOrange,
                    alignment: .center,
                    verticallyCentered: true
                )
            } else if group.primaryTint != .normal {
                QuotaStatusDrawing.drawText(
                    group.primaryText,
                    in: QuotaStatusLayout.progressValueRect(in: layout.metricRect),
                    font: QuotaStatusLayout.progressValueFont,
                    color: group.primaryTint.color,
                    alignment: .center,
                    verticallyCentered: true
                )
            }

            if let progress = group.barProgress, progress > 0 {
                let trackRect = QuotaStatusLayout.progressTrackRect(in: layout.metricRect)
                let fillWidth = max(trackRect.height, trackRect.width * CGFloat(progress))
                let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY,
                                      width: min(trackRect.width, fillWidth), height: trackRect.height)
                group.barTone.nsColor.setFill()
                NSBezierPath(
                    roundedRect: fillRect,
                    xRadius: trackRect.height / 2,
                    yRadius: trackRect.height / 2
                ).fill()
            }
        }
    }

    private func drawCompactDualOverlay() {
        let layouts = QuotaStatusLayout.groupLayouts(groups, mode: .compactDual)
        for (group, layout) in zip(groups, layouts) {
            QuotaStatusDrawing.drawRoundedIcon(group.provider.icon, in: layout.iconRect)

            let bounds = layout.metricRect
            if let row = group.rows.first, group.rows.count == 1, row.tint != .normal {
                let badgeRect = NSRect(x: bounds.minX, y: 1, width: bounds.width, height: 8.5)
                let valRect = NSRect(x: bounds.minX, y: 9.5, width: bounds.width, height: bounds.height - 10)
                QuotaStatusDrawing.drawText(
                    row.badge,
                    in: badgeRect,
                    font: QuotaStatusLayout.stackedBadgeFont,
                    color: row.tint.color,
                    alignment: .center,
                    verticallyCentered: true
                )
                if row.colorsValue {
                    QuotaStatusDrawing.drawText(
                        row.value,
                        in: valRect,
                        font: QuotaStatusLayout.stackedValueFont,
                        color: row.tint.color,
                        alignment: .center,
                        verticallyCentered: true
                    )
                }
            } else {
                for (row, y) in zip(group.rows, QuotaStatusLayout.compactRowYOffsets(count: group.rows.count)) where row.tint != .normal {
                    let keyRect = NSRect(x: bounds.minX, y: y, width: QuotaStatusLayout.compactKeyWidth, height: 9.5)
                    let valX = keyRect.maxX + QuotaStatusLayout.compactKeyGap
                    let valRect = NSRect(x: valX, y: y, width: bounds.maxX - valX, height: 9.5)

                    QuotaStatusDrawing.drawText(
                        row.badge,
                        in: keyRect,
                        font: QuotaStatusLayout.compactKeyFont,
                        color: row.tint.color,
                        alignment: .left,
                        verticallyCentered: true
                    )
                    if row.colorsValue {
                        QuotaStatusDrawing.drawText(
                            row.value,
                            in: valRect,
                            font: QuotaStatusLayout.compactValueFont,
                            color: row.tint.color,
                            alignment: .left,
                            verticallyCentered: true
                        )
                    }
                }
            }
        }
    }
}
