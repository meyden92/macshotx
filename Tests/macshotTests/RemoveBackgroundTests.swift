import AppKit
import Testing
@testable import MacshotCore

// Both branches of subject isolation, driven through the injected dependency
// rather than through whatever Vision makes of a synthetic bitmap.

/// A mask covering the left half of the image: white keeps, black cuts.
private func halfMask(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    return ctx.makeImage()!
}

@MainActor
private func makeView(
    isolate: @escaping SubjectIsolator
) -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: ctx.makeImage()!, scale: 1.0, isolateSubject: isolate
    )
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func key(
    _ char: String, _ code: UInt16, _ window: NSWindow, flags: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code
    )!
}

@MainActor
private func drag(in view: RegionPickerView, window: NSWindow, from: CGPoint, to: CGPoint) {
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to)
    ] {
        let event = NSEvent.mouseEvent(
            with: kind, location: NSPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
        )!
        switch kind {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
}

private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    return Int(bytes[y * image.bytesPerRow + x * 4 + 3])
}

@MainActor
private func selectionAndRemoval(
    isolate: @escaping SubjectIsolator
) async -> (RegionPickerView, NSWindow) {
    let (view, window) = makeView(isolate: isolate)
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
    view.keyDown(with: key("r", 15, window, flags: .option))
    // The request runs off the main actor; let it land.
    for _ in 0..<50 where view.annotations.isEmpty && !view.isSelectionLocked {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (view, window)
}

@MainActor
@Test
func aFoundSubjectLeavesTheRestTransparentAndIsOneUndoStep() async throws {
    let (view, window) = await selectionAndRemoval { image in
        halfMask(width: image.width, height: image.height)
    }
    #expect(view.isSelectionLocked, "The mask belongs to this crop, so the crop stops moving")

    var committed: CGImage?
    view.onCommit = { committed = $0 }
    view.keyDown(with: key("\r", 36, window))
    let image = try #require(committed)
    #expect(alpha(image, 40, 100) == 255, "The subject side keeps its pixels")
    #expect(alpha(image, 160, 100) == 0, "and the background side is transparent")

    let undo = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!
    view.keyDown(with: undo)
    #expect(!view.isSelectionLocked, "One undo brings the background back and unlocks the crop")

    view.keyDown(with: key("\r", 36, window))
    let restored = try #require(committed)
    #expect(alpha(restored, 160, 100) == 255)
}

@MainActor
@Test
func noSubjectFoundLeavesTheCaptureExactlyAsItWas() async throws {
    let (view, window) = await selectionAndRemoval { _ in nil }
    #expect(!view.isSelectionLocked, "Nothing was applied, so nothing is locked")

    var committed: CGImage?
    view.onCommit = { committed = $0 }
    view.keyDown(with: key("\r", 36, window))
    let image = try #require(committed)
    #expect(alpha(image, 160, 100) == 255, "The capture is untouched")
    #expect(image.width == 200 && image.height == 200)
}
