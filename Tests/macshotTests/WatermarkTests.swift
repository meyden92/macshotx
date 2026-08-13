import AppKit
import Testing
@testable import MacshotCore

// Placement is arithmetic on the capture's own pixels, so every size and margin
// is a percentage: the same settings land the same way on a Retina capture and
// on a small crop. Rects are in CoreGraphics space — y grows upward.

private let canvas = CGSize(width: 1000, height: 500)
private let logo = CGSize(width: 200, height: 100)

private func settings(
    corner: WatermarkCorner = .bottomRight, scale: Int = 20, margin: Int = 2
) -> WatermarkSettings {
    var value = WatermarkSettings()
    value.enabled = true
    value.corner = corner
    value.scalePercent = scale
    value.marginPercent = margin
    return value
}

@Test
func theLogoIsSizedAsAShareOfTheCaptureWidthAndKeepsItsAspect() {
    let frame = Watermark.frame(logo: logo, in: canvas, settings: settings())
    #expect(frame.width == 200, "20% of a 1000pt-wide capture")
    #expect(frame.height == 100, "and 2:1 stays 2:1")
}

@Test
func eachCornerPlacesTheLogoAgainstItsOwnTwoEdges() {
    // margin is 2% of the width = 20; the logo is 200 × 100.
    let expected: [(WatermarkCorner, CGRect)] = [
        (.bottomLeft, CGRect(x: 20, y: 20, width: 200, height: 100)),
        (.bottomRight, CGRect(x: 780, y: 20, width: 200, height: 100)),
        (.topLeft, CGRect(x: 20, y: 380, width: 200, height: 100)),
        (.topRight, CGRect(x: 780, y: 380, width: 200, height: 100))
    ]
    for (corner, rect) in expected {
        #expect(Watermark.frame(logo: logo, in: canvas, settings: settings(corner: corner)) == rect,
                "\(corner)")
    }
}

@Test
func aLogoTooBigForTheCaptureIsShrunkToFitInsideItsMargins() {
    // 100% of the width is 1000; the margins leave 960 × 460, and a 2:1 logo
    // 960 wide would stand 480 tall — so the height is what actually binds.
    let frame = Watermark.frame(logo: logo, in: canvas, settings: settings(scale: 100))
    #expect(frame.height == 460, "capped by the shorter axis")
    #expect(frame.width == 920, "shrunk on both axes, so 2:1 survives")
    #expect(frame.minX >= 20 && frame.maxX <= 980, "and it stays inside the margins")

    // A tall logo has to fit the height too, not just the width.
    let tall = Watermark.frame(
        logo: CGSize(width: 100, height: 400), in: canvas, settings: settings(scale: 100)
    )
    #expect(tall.height <= 460 && tall.minY >= 20, "capped by the shorter axis")
}

// MARK: - Compositing

@MainActor
private func filled(_ color: NSColor, _ size: CGSize) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))
    return ctx.makeImage()!
}

@MainActor
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    let offset = y * image.bytesPerRow + x * 4
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
}

@MainActor
@Test
func theWatermarkLandsInItsCornerAndLeavesTheRestOfTheCaptureAlone() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macshot-wm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let logoURL = dir.appendingPathComponent("logo.png")
    try ImageEncoder.encode(filled(.systemRed, CGSize(width: 100, height: 100)),
                            format: .png, quality: 100).write(to: logoURL)

    var config = settings(corner: .bottomRight, scale: 20, margin: 2)
    config.imagePath = logoURL.path
    let marked = Watermark.applied(to: filled(.white, CGSize(width: 400, height: 400)), config)

    // Bottom-right in CoreGraphics space is the bottom row of the bitmap's
    // last rows; sample the middle of where the 80×80 logo must have landed.
    #expect(pixel(marked, 320, 360).0 > 200, "red channel is up in the logo's corner")
    #expect(pixel(marked, 320, 360).1 < 100, "and green is down, so it is not the white capture")
    let opposite = pixel(marked, 40, 40)
    #expect(opposite.0 > 240 && opposite.1 > 240 && opposite.2 > 240, "far corner is untouched white")
}

@MainActor
@Test
func aWatermarkThatIsOffOrUnreadableLeavesTheCaptureExactlyAsItWas() {
    let capture = filled(.white, CGSize(width: 100, height: 100))

    var off = settings()
    off.imagePath = "/tmp/does-not-matter.png"
    off.enabled = false
    #expect(Watermark.applied(to: capture, off) === capture, "disabled is a no-op")

    var missing = settings()
    missing.imagePath = "/tmp/macshot-no-such-logo-\(UUID().uuidString).png"
    #expect(Watermark.applied(to: capture, missing) === capture,
            "an unreadable file must never cost the user their capture")

    var empty = settings()
    empty.imagePath = ""
    #expect(Watermark.applied(to: capture, empty) === capture, "nor an unconfigured one")
}
