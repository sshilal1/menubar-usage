import AppKit
import Foundation

@MainActor
private func image(from view: NSView, scale: CGFloat = 2) -> NSImage {
    view.layoutSubtreeIfNeeded()
    let size = view.fittingSize.width > 0 && view.fittingSize.height > 0
        ? view.fittingSize
        : view.bounds.size
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!)
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}

@MainActor
private func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(url.path)")
    }
    try! png.write(to: url)
}

@MainActor
private func makePopoverScreenshot() -> NSImage {
    let controller = PopoverViewController()
    controller.loadView()
    controller.view.appearance = NSAppearance(named: .darkAqua)

    let now = Date()
    controller.update(with: [
        UsageSnapshot(
            provider: .claude,
            isConnected: true,
            dailyPercent: 54,
            weeklyPercent: 16,
            dailyResetAt: now.addingTimeInterval(60 * 60 + 53 * 60),
            weeklyResetAt: now.addingTimeInterval(4 * 24 * 60 * 60 + 19 * 60 * 60),
            totalTokens: 49_200_000,
            planLabel: "Pro",
            updatedAt: now.addingTimeInterval(-120),
            error: nil
        ),
        UsageSnapshot(
            provider: .codex,
            isConnected: true,
            dailyPercent: 1,
            weeklyPercent: 10,
            dailyResetAt: now.addingTimeInterval(4 * 60 * 60 + 59 * 60),
            weeklyResetAt: now.addingTimeInterval(5 * 24 * 60 * 60 + 15 * 60 * 60),
            totalTokens: 1_800_000,
            planLabel: "Plus",
            updatedAt: now.addingTimeInterval(-6),
            error: nil
        )
    ])

    let contentSize = controller.preferredContentSize
    let backing = ScreenshotBackingView(frame: NSRect(origin: .zero, size: contentSize))

    controller.view.frame = backing.bounds
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    backing.addSubview(controller.view)
    NSLayoutConstraint.activate([
        controller.view.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
        controller.view.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
        controller.view.topAnchor.constraint(equalTo: backing.topAnchor),
        controller.view.bottomAnchor.constraint(equalTo: backing.bottomAnchor)
    ])

    return image(from: backing)
}

private final class ScreenshotBackingView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()

        NSColor(calibratedWhite: 0.22, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        border.lineWidth = 1
        border.stroke()
    }
}

@MainActor
private func makeMenuBarScreenshot() -> NSImage {
    let snapshots = [
        UsageSnapshot(
            provider: .claude,
            isConnected: true,
            dailyPercent: 54,
            weeklyPercent: 16,
            dailyResetAt: nil,
            weeklyResetAt: nil,
            totalTokens: nil,
            planLabel: nil,
            updatedAt: Date(),
            error: nil
        ),
        UsageSnapshot(
            provider: .codex,
            isConnected: true,
            dailyPercent: 1,
            weeklyPercent: 10,
            dailyResetAt: nil,
            weeklyResetAt: nil,
            totalTokens: nil,
            planLabel: nil,
            updatedAt: Date(),
            error: nil
        )
    ]
    let gauge = MenuBarGauge.image(for: snapshots, height: 22)

    let size = NSSize(width: 240, height: 38)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.15, alpha: 1).setFill()
        rect.fill()

        let bar = NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 7), xRadius: 7, yRadius: 7)
        NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.22, alpha: 1).setFill()
        bar.fill()

        gauge.draw(at: NSPoint(x: 22, y: 8), from: .zero, operation: .sourceOver, fraction: 1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)
        ]
        "Claude".draw(at: NSPoint(x: 94, y: 12), withAttributes: attrs)
        "ChatGPT".draw(at: NSPoint(x: 154, y: 12), withAttributes: attrs)
        return true
    }
    return image
}

@main
struct RenderReadmeScreenshots {
    @MainActor
    static func main() {
        setenv("MENUBAR_USAGE_FORCE_FALLBACK_ICONS", "1", 1)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        writePNG(makeMenuBarScreenshot(), to: assets.appendingPathComponent("menubar-preview.png"))
        writePNG(makePopoverScreenshot(), to: assets.appendingPathComponent("popover-preview.png"))
    }
}
