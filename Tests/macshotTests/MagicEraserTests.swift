import AppKit
import Testing
@testable import MacshotCore

// The magic eraser: a filled redact whose colour is the pixel under the press,
// so a region is painted out in its own background rather than behind a block.

/// A 200×200 source split down the middle: pure red on the left, pure blue on
/// the right. The split is vertical so it survives the overlay's flipped
/// coordinates without any y bookkeeping.
@MainActor
private func makeHostedView() -> (RegionPickerView, NSWindow) {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 4 * 200,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
    ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
    ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: ctx.makeImage()!, scale: 1.0, requiresSelection: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func key(_ char: String, _ keyCode: UInt16, _ window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: keyCode
    )!
}

@MainActor
private func drag(in view: RegionPickerView, window: NSWindow, from: CGPoint, to: CGPoint) {
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to)
    ] {
        let event = NSEvent.mouseEvent(
            with: kind,
            location: NSPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1.0
        )!
        switch kind {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
}

/// 0–255 sRGB components of an annotation's colour.
private func rgb(_ color: NSColor?) -> (r: Int, g: Int, b: Int)? {
    guard let converted = color?.usingColorSpace(.sRGB) else { return nil }
    return (
        Int((converted.redComponent * 255).rounded()),
        Int((converted.greenComponent * 255).rounded()),
        Int((converted.blueComponent * 255).rounded())
    )
}

/// Erases from `from` to `to` and hands back what was placed.
@MainActor
private func erase(from: CGPoint, to: CGPoint) -> (RegionPickerView, NSWindow, Annotation?) {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("e", 14, window))
    drag(in: view, window: window, from: from, to: to)
    return (view, window, view.annotations.last)
}

@MainActor
@Test
func theMagicEraserPlacesAFilledRedactInTheColourUnderThePress() throws {
    // Both drags cross the seam, and each takes the half it started in: the
    // sample is the press, not the release and not the fill tool's default.
    let (_, _, fromRed) = erase(from: CGPoint(x: 30, y: 50), to: CGPoint(x: 170, y: 150))
    guard case let .fillRect(rect, style) = try #require(fromRed) else {
        Issue.record("The magic eraser should place a filled redact, got \(String(describing: fromRed))")
        return
    }
    #expect(rect == CGRect(x: 30, y: 50, width: 140, height: 100))
    #expect(rgb(style.color)! == (255, 0, 0), "Pressed on red, so the fill is red")

    let (_, _, fromBlue) = erase(from: CGPoint(x: 170, y: 50), to: CGPoint(x: 30, y: 150))
    guard case let .fillRect(_, blueStyle) = try #require(fromBlue) else {
        Issue.record("The magic eraser should place a filled redact")
        return
    }
    #expect(rgb(blueStyle.color)! == (0, 0, 255), "Pressed on blue, so the fill is blue")
}

@MainActor
@Test
func theErasedRegionBakesOutInTheSampledColour() throws {
    // The colour has to survive NSColor and the bake, not just the model.
    let (view, window, _) = erase(from: CGPoint(x: 30, y: 50), to: CGPoint(x: 170, y: 150))
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 190, y: 190))
    view.keyDown(with: key("\r", 36, window))

    let image = try #require(baked)
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    func pixel(_ point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
        let offset = (Int(point.y) - 10) * image.bytesPerRow + (Int(point.x) - 10) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    let covered = pixel(CGPoint(x: 150, y: 100))
    #expect(covered.r > 200 && covered.b < 60,
            "The blue half inside the rect should have been painted red, got \(covered)")
    let untouched = pixel(CGPoint(x: 150, y: 30))
    #expect(untouched.b > 200 && untouched.r < 60,
            "Outside the rect the blue half is left alone, got \(untouched)")
}
