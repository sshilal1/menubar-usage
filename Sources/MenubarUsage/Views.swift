import AppKit

/// Fallback rounded-badge glyph (`CL` / `GP`) drawn when the provider's desktop
/// app icon isn't installed.
final class ProviderLogoView: NSView {
    private let provider: Provider
    private let selected: Bool

    init(provider: Provider, selected: Bool) {
        self.provider = provider
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 2, dy: 2)
        let fill: NSColor
        let stroke: NSColor
        switch provider {
        case .codex:
            fill = selected ? NSColor(calibratedRed: 0.06, green: 0.40, blue: 0.33, alpha: 1) : NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.28, alpha: 1)
            stroke = NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.74, alpha: 1)
        case .claude:
            fill = selected ? NSColor(calibratedRed: 0.63, green: 0.35, blue: 0.20, alpha: 1) : NSColor(calibratedRed: 0.45, green: 0.33, blue: 0.25, alpha: 1)
            stroke = NSColor(calibratedRed: 0.86, green: 0.73, blue: 0.58, alpha: 1)
        }

        fill.setFill()
        stroke.setStroke()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        path.lineWidth = selected ? 2 : 1
        path.fill()
        path.stroke()

        let text = provider.badge
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 10),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

/// Shared source for each provider's brand icon, used by the popover so it shows
/// the real desktop-app glyph (falling back to the badge when not installed).
enum ProviderBranding {
    static func appIcon(for provider: Provider) -> NSImage? {
        let bundleID: String
        let fallbackPath: String
        switch provider {
        case .claude:
            bundleID = "com.anthropic.claudefordesktop"
            fallbackPath = "/Applications/Claude.app"
        case .codex:
            bundleID = "com.openai.chat"
            fallbackPath = "/Applications/ChatGPT.app"
        }
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: bundleID)
            ?? (FileManager.default.fileExists(atPath: fallbackPath) ? URL(fileURLWithPath: fallbackPath) : nil)
        guard let url else { return nil }
        return workspace.icon(forFile: url.path)
    }

    @MainActor
    static func icon(for provider: Provider, size: CGFloat) -> NSImage {
        if let appIcon = appIcon(for: provider) {
            let copy = appIcon.copy() as! NSImage
            copy.size = NSSize(width: size, height: size)
            return copy
        }
        let view = ProviderLogoView(provider: provider, selected: true)
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A full-width labeled limit gauge for the popover:
/// `5-hour  ▓▓▓░░░░░  19%` with the fill color-graded by consumption.
final class PopoverLimitBar: NSView {
    private let caption: String
    private let percent: Double?

    init(caption: String, percent: Double?) {
        self.caption = caption
        self.percent = percent
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        let midY = bounds.midY

        let captionSize = caption.size(withAttributes: captionAttrs)
        caption.draw(at: NSPoint(x: 0, y: midY - captionSize.height / 2), withAttributes: captionAttrs)

        let valueText = UsageFormat.percentText(percent)
        let valueSize = valueText.size(withAttributes: valueAttrs)
        valueText.draw(
            at: NSPoint(x: bounds.maxX - valueSize.width, y: midY - valueSize.height / 2),
            withAttributes: valueAttrs
        )

        let barX: CGFloat = 62
        let barMaxX = bounds.maxX - valueSize.width - 12
        let barWidth = barMaxX - barX
        guard barWidth > 4 else { return }

        let barHeight: CGFloat = 6
        let trackRect = NSRect(x: barX, y: midY - barHeight / 2, width: barWidth, height: barHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        guard let percent else { return }
        let clamped = max(0, min(100, percent))
        let fillWidth = max(barHeight, barWidth * CGFloat(clamped / 100))
        let fillRect = NSRect(x: barX, y: trackRect.minY, width: fillWidth, height: barHeight)
        UsageFormat.color(forPercent: clamped).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }
}

/// A small status dot used in the popover to signal a provider's headline health.
final class StatusDotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

// MARK: - Menu bar gauge

/// Renders the always-visible menu bar content: for each provider a 2-letter
/// badge plus two slim vertical gauge bars (5-hour and weekly), color-graded by
/// consumption. Produces an `NSImage` sized to the menu bar so it can be set as
/// the status item's button image (clicks + positioning come for free).
enum MenuBarGauge {
    private static var badgeFont: NSFont { NSFont.systemFont(ofSize: 9, weight: .bold) }
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2
    private static let badgeGap: CGFloat = 3
    private static let providerGap: CGFloat = 9
    private static let sidePadding: CGFloat = 3

    /// Width one provider's cell occupies (badge + two bars).
    private static func cellWidth(badge: String) -> CGFloat {
        let badgeWidth = (badge as NSString).size(withAttributes: [.font: badgeFont]).width
        return badgeWidth + badgeGap + barWidth * 2 + barGap
    }

    @MainActor
    static func image(for snapshots: [UsageSnapshot], height: CGFloat) -> NSImage {
        // Keep providers in a stable, predictable order.
        let ordered = Provider.allCases.compactMap { provider in
            snapshots.first { $0.provider == provider }
        }
        let cells = ordered.isEmpty
            ? Provider.allCases.map { UsageSnapshot.disconnected($0) }
            : ordered

        var width = sidePadding * 2
        for (i, snap) in cells.enumerated() {
            width += cellWidth(badge: snap.provider.badge)
            if i < cells.count - 1 { width += providerGap }
        }

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x = sidePadding
            for (i, snap) in cells.enumerated() {
                x = drawCell(snap, atX: x, height: height)
                if i < cells.count - 1 { x += providerGap }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    @MainActor
    private static func drawCell(_ snapshot: UsageSnapshot, atX startX: CGFloat, height: CGFloat) -> CGFloat {
        var x = startX

        // Two-letter provider badge in its accent color (dimmed if disconnected).
        let badge = snapshot.provider.badge as NSString
        let badgeColor = snapshot.isConnected
            ? snapshot.provider.accentColor
            : NSColor.tertiaryLabelColor
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: badgeColor
        ]
        let badgeSize = badge.size(withAttributes: badgeAttrs)
        badge.draw(at: NSPoint(x: x, y: (height - badgeSize.height) / 2), withAttributes: badgeAttrs)
        x += badgeSize.width + badgeGap

        // Two vertical gauges: 5-hour (left), weekly (right).
        let barTop: CGFloat = height - 4
        let barBottom: CGFloat = 3
        let barHeight = barTop - barBottom
        drawBar(percent: snapshot.dailyPercent, connected: snapshot.isConnected,
                x: x, bottom: barBottom, fullHeight: barHeight)
        x += barWidth + barGap
        drawBar(percent: snapshot.weeklyPercent, connected: snapshot.isConnected,
                x: x, bottom: barBottom, fullHeight: barHeight)
        x += barWidth

        return x
    }

    private static func drawBar(percent: Double?, connected: Bool,
                                x: CGFloat, bottom: CGFloat, fullHeight: CGFloat) {
        let radius = barWidth / 2
        let track = NSRect(x: x, y: bottom, width: barWidth, height: fullHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard connected, let percent else { return }
        let clamped = max(0, min(100, percent))
        let fillHeight = max(barWidth, fullHeight * CGFloat(clamped / 100))
        let fill = NSRect(x: x, y: bottom, width: barWidth, height: fillHeight)
        UsageFormat.color(forPercent: clamped).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
