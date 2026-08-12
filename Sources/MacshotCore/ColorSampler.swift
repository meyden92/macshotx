import AppKit
import ScreenCaptureKit

// MARK: - Color formatting (PRD §6.4.2: hex, RGB or HSL output)

enum ColorFormatter {
    static func format(r: UInt8, g: UInt8, b: UInt8, as format: ColorOutputFormat) -> String {
        switch format {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let (h, s, l) = hsl(r: r, g: g, b: b)
            return "hsl(\(h), \(s)%, \(l)%)"
        }
    }

    /// 0–255 RGB → (hue 0–359, saturation 0–100, lightness 0–100).
    static func hsl(r: UInt8, g: UInt8, b: UInt8) -> (Int, Int, Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf)
        let delta = maxC - minC
        let lightness = (maxC + minC) / 2

        var hue = 0.0
        var saturation = 0.0
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            if maxC == rf {
                hue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == gf {
                hue = (bf - rf) / delta + 2
            } else {
                hue = (rf - gf) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        return (
            Int(hue.rounded()) % 360,
            Int((saturation * 100).rounded()),
            Int((lightness * 100).rounded())
        )
    }
}

// MARK: - Pixel access

/// One-time RGBA8 readback of a CGImage for fast per-pixel sampling.
final class PixelBuffer {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(image: CGImage) {
        let imageWidth = image.width
        let imageHeight = image.height
        var data = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: imageWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard ok else { return nil }
        width = imageWidth
        height = imageHeight
        bytes = data
    }

    /// Top-left-origin pixel lookup.
    func color(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}

// MARK: - Sampler overlay

/// Color picker and magnifier loupe (PRD §6.4.2 / §6.4.3). Both present the
/// same frozen-screen loupe; the picker copies the clicked pixel's color.
@MainActor
final class ColorSampler {
    static func run(copyToClipboard: Bool) async {
        do {
            let (image, screen) = try await frozenDisplayUnderCursor()
            let sampler = ColorSampler()
            let picked = await sampler.present(image: image, screen: screen, picking: copyToClipboard)
            guard copyToClipboard, let picked else { return }
            let format = ConfigStore.shared.config.general.colorFormat
            let formatted = ColorFormatter.format(r: picked.r, g: picked.g, b: picked.b, as: format)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(formatted, forType: .string)
            Log.info("Picked color \(formatted)")
        } catch {
            Log.error("Color sampler failed: \(error)")
            await Notifier.failure(
                title: "Color picker failed",
                error: error,
                enabled: ConfigStore.shared.config.general.notificationsEnabled
            )
        }
    }

    private static func frozenDisplayUnderCursor() async throws -> (CGImage, NSScreen) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed(error)
        }
        let mouseLocation = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSPointInRect(mouseLocation, $0.frame) }),
            let screenID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID,
            let display = content.displays.first(where: { $0.displayID == screenID })
        else {
            throw CaptureError.noDisplayUnderCursor
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        config.capturesAudio = false
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return (image, screen)
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    private var overlay: NSWindow?
    private var continuation: CheckedContinuation<(r: UInt8, g: UInt8, b: UInt8)?, Never>?
    private var hasResumed = false

    private func present(
        image: CGImage,
        screen: NSScreen,
        picking: Bool
    ) async -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let buffer = PixelBuffer(image: image) else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let viewFrame = NSRect(origin: .zero, size: screen.frame.size)
            let view = LoupeView(
                frame: viewFrame,
                image: image,
                buffer: buffer,
                picking: picking,
                colorFormat: ConfigStore.shared.config.general.colorFormat
            )
            view.onPick = { [weak self] color in self?.finish(with: color) }
            view.onCancel = { [weak self] in self?.finish(with: nil) }

            let window = KeyableOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [
                .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary
            ]
            window.contentView = view

            overlay = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSCursor.crosshair.set()
        }
    }

    private func finish(with color: (r: UInt8, g: UInt8, b: UInt8)?) {
        guard !hasResumed else { return }
        hasResumed = true
        NSCursor.arrow.set()
        overlay?.orderOut(nil)
        overlay = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: color)
    }
}

// MARK: - Loupe view

final class LoupeView: NSView {
    var onPick: (((r: UInt8, g: UInt8, b: UInt8)) -> Void)?
    var onCancel: (() -> Void)?

    private let frozenImage: NSImage
    private let frozen: CGImage
    private let buffer: PixelBuffer
    private let picking: Bool
    private let colorFormat: ColorOutputFormat
    private let scale: CGFloat

    private var cursor: NSPoint = .zero

    private let gridCount = 11          // odd, so there's a center pixel
    private let cellSize: CGFloat = 13
    private var loupeSize: CGFloat { CGFloat(gridCount) * cellSize }

    init(
        frame: NSRect,
        image: CGImage,
        buffer: PixelBuffer,
        picking: Bool,
        colorFormat: ColorOutputFormat
    ) {
        self.frozen = image
        self.frozenImage = NSImage(cgImage: image, size: frame.size)
        self.buffer = buffer
        self.picking = picking
        self.colorFormat = colorFormat
        self.scale = frame.width > 0 ? CGFloat(image.width) / frame.width : 1
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            cursor = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard picking else {
            onCancel?()
            return
        }
        if let color = sample(at: point) {
            onPick?(color)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func pixelCoordinates(at point: NSPoint) -> (x: Int, y: Int) {
        (
            min(buffer.width - 1, max(0, Int(point.x * scale))),
            min(buffer.height - 1, max(0, Int(point.y * scale)))
        )
    }

    private func sample(at point: NSPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let (px, py) = pixelCoordinates(at: point)
        return buffer.color(x: px, y: py)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        frozenImage.draw(in: bounds)
        drawLoupe()
    }

    private func drawLoupe() {
        let (px, py) = pixelCoordinates(at: cursor)
        guard let centerColor = buffer.color(x: px, y: py) else { return }

        // Loupe rect: offset from the cursor, flipped near screen edges.
        var origin = NSPoint(x: cursor.x + 24, y: cursor.y + 24)
        if origin.x + loupeSize > bounds.maxX - 8 {
            origin.x = cursor.x - 24 - loupeSize
        }
        if origin.y + loupeSize + 30 > bounds.maxY - 8 {
            origin.y = cursor.y - 24 - loupeSize - 30
        }
        let loupeRect = NSRect(x: origin.x, y: origin.y, width: loupeSize, height: loupeSize)

        // Magnified pixels: gridCount × gridCount source pixels around the cursor.
        let half = gridCount / 2
        let sourceRect = CGRect(
            x: px - half, y: py - half, width: gridCount, height: gridCount
        )
        NSGraphicsContext.current?.saveGraphicsState()
        let clip = NSBezierPath(ovalIn: loupeRect)
        clip.addClip()

        NSColor.black.setFill()
        loupeRect.fill()

        if let cropped = frozen.cropping(
            to: sourceRect.intersection(CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height))
        ) {
            // Align partial crops at screen edges into the right grid cells.
            let visible = sourceRect.intersection(
                CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height)
            )
            let cellX = loupeRect.minX + (visible.minX - sourceRect.minX) * cellSize
            let cellY = loupeRect.minY + (visible.minY - sourceRect.minY) * cellSize
            let target = NSRect(
                x: cellX,
                y: cellY,
                width: visible.width * cellSize,
                height: visible.height * cellSize
            )
            let context = NSGraphicsContext.current
            let saved = context?.imageInterpolation
            context?.imageInterpolation = .none
            NSImage(cgImage: cropped, size: target.size).draw(in: target)
            if let saved { context?.imageInterpolation = saved }
        }

        // Pixel grid.
        NSColor.white.withAlphaComponent(0.18).setStroke()
        for index in 1..<gridCount {
            let offset = CGFloat(index) * cellSize
            let vertical = NSBezierPath()
            vertical.move(to: NSPoint(x: loupeRect.minX + offset, y: loupeRect.minY))
            vertical.line(to: NSPoint(x: loupeRect.minX + offset, y: loupeRect.maxY))
            vertical.lineWidth = 1
            vertical.stroke()
            let horizontal = NSBezierPath()
            horizontal.move(to: NSPoint(x: loupeRect.minX, y: loupeRect.minY + offset))
            horizontal.line(to: NSPoint(x: loupeRect.maxX, y: loupeRect.minY + offset))
            horizontal.lineWidth = 1
            horizontal.stroke()
        }

        // Center pixel highlight.
        let centerRect = NSRect(
            x: loupeRect.minX + CGFloat(half) * cellSize,
            y: loupeRect.minY + CGFloat(half) * cellSize,
            width: cellSize,
            height: cellSize
        )
        NSColor.white.setStroke()
        let highlight = NSBezierPath(rect: centerRect)
        highlight.lineWidth = 2
        highlight.stroke()

        NSGraphicsContext.current?.restoreGraphicsState()

        // Ring.
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: loupeRect)
        ring.lineWidth = 2
        ring.stroke()

        // Color label under the loupe.
        let label = ColorFormatter.format(
            r: centerColor.r, g: centerColor.g, b: centerColor.b, as: colorFormat
        ) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attrs)
        let labelRect = NSRect(
            x: loupeRect.midX - textSize.width / 2 - 8,
            y: loupeRect.maxY + 6,
            width: textSize.width + 16,
            height: textSize.height + 6
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        // Swatch of the sampled color inside the label background.
        label.draw(
            at: NSPoint(x: labelRect.minX + 8, y: labelRect.minY + 3),
            withAttributes: attrs
        )
    }
}
