import AppKit
import Testing
@testable import MacshotCore

@MainActor
private func makeImage(width: Int = 200, height: Int = 200) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 4 * width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.gray.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@MainActor
private func makeEditorView(
    requiresSelection: Bool = true,
    styles: EditorStyles = EditorStyles(),
    onStylesChanged: ((EditorStyles) -> Void)? = nil
) -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let view = RegionPickerView(
        frame: frame,
        image: makeImage(),
        scale: 1.0,
        styles: styles,
        onStylesChanged: onStylesChanged,
        requiresSelection: requiresSelection
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
private func mouse(
    _ kind: NSEvent.EventType,
    at point: CGPoint,
    view: RegionPickerView,
    window: NSWindow
) -> NSEvent {
    let location = NSPoint(x: point.x, y: view.bounds.height - point.y)
    return NSEvent.mouseEvent(
        with: kind, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1.0
    )!
}


/// Opens the picker from the tool-options row's colour well and clicks one of
/// its standard swatches — the path a user takes to a common colour.
@MainActor
private func pickStandardColor(_ color: NSColor, in view: RegionPickerView) {
    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    row?.onColorWellClicked?()
    let panel = view.subviews.compactMap { $0 as? ColorPickerPanelView }.first
    let swatch = panel?.standardSwatches.first { $0.color.matchesColor(color) }
    #expect(swatch != nil, "The picker should offer a standard swatch for \(color)")
    swatch?.onClick?(color)
}

// MARK: - Editor mode (post-capture window)

@MainActor
@Test
func editorModeBakesFullImageWithoutSelection() {
    let (view, window) = makeEditorView(requiresSelection: false)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // No selection at all — Return should still bake the full frame.
    view.keyDown(with: key("\r", 36, window))
    #expect(baked?.width == 200)
    #expect(baked?.height == 200)
}

@MainActor
@Test
func editorModeSelectionCropsLikeRegionMode() {
    let (view, window) = makeEditorView(requiresSelection: false)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 30), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 110), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 120, y: 110), view: view, window: window))
    view.keyDown(with: key("\r", 36, window))

    #expect(baked?.width == 100)
    #expect(baked?.height == 80)
}

// MARK: - Callout tool

@MainActor
@Test
func calloutDragTypeCommitBakesBubble() {
    let (view, window) = makeEditorView()
    window.makeKeyAndOrderFront(nil)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // C = callout; drag from anchor (150, 150) to bubble position (40, 40).
    view.keyDown(with: key("c", 8, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 150, y: 150), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 40, y: 40), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 40, y: 40), view: view, window: window))

    // The drag spawns the inline editor at the bubble position.
    let editor = view.subviews.compactMap { $0 as? InlineTextView }.first
    #expect(editor != nil, "Callout should spawn the inline editor after the drag")
    editor?.string = "Hi"

    // Select everything and bake.
    view.keyDown(with: key("s", 1, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 5, y: 5), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 195, y: 195), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 195, y: 195), view: view, window: window))
    view.keyDown(with: key("\r", 36, window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }
    // Bubble rect starts at view (40, 40); cropped at (5, 5) → baked (35, 35).
    // Sample inside the bubble (default red fill): a few px in from the corner.
    let bpr = baked.bytesPerRow
    let offset = 45 * bpr + 45 * 4
    let r = bytes[offset]
    let g = bytes[offset + 1]
    #expect(r > 150 && g < 110, "Inside the callout bubble should be red fill, got R=\(r) G=\(g)")
}

@MainActor
@Test
func emptyCalloutCommitsNothing() {
    let (view, window) = makeEditorView(requiresSelection: false)
    window.makeKeyAndOrderFront(nil)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.keyDown(with: key("c", 8, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100), view: view, window: window))
    view.subviews.compactMap { $0 as? InlineTextView }.first?.string = ""
    view.keyDown(with: key("\r", 36, window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }
    // Where the default bubble would land (anchor + (24, -64) → (124, 44)):
    // must still be source gray, since an empty callout is discarded.
    let bpr = baked.bytesPerRow
    let offset = 46 * bpr + 126 * 4
    let r = bytes[offset]
    let g = bytes[offset + 1]
    #expect(abs(Int(r) - Int(g)) < 20, "Empty callout must not draw, got R=\(r) G=\(g)")
}

// MARK: - Step marker color

@MainActor
@Test
func stepMarkerUsesConfiguredColor() {
    var styles = EditorStyles()
    styles.stepMarkerColorHex = "#0000FF"
    let (view, window) = makeEditorView(styles: styles)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.keyDown(with: key("n", 45, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100), view: view, window: window))

    view.keyDown(with: key("s", 1, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 150, y: 150), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 150, y: 150), view: view, window: window))
    view.keyDown(with: key("\r", 36, window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }
    // Marker center at view (100, 100) → baked (50, 50): offset from the
    // centered "1" glyph, sample (50, 58) inside the disc.
    let bpr = baked.bytesPerRow
    let offset = 58 * bpr + 50 * 4
    let r = bytes[offset]
    let b = bytes[offset + 2]
    #expect(b > 150 && r < 110, "Step marker should use the configured blue, got R=\(r) B=\(b)")
}

// MARK: - Style persistence

@MainActor
@Test
func styleChangesArePersistedThroughCallback() {
    var saved: EditorStyles?
    let (view, window) = makeEditorView(onStylesChanged: { saved = $0 })

    // Rectangle tool, then pick blue out of the colour picker.
    view.keyDown(with: key("r", 15, window))
    pickStandardColor(.systemBlue, in: view)

    #expect(saved != nil, "Changing a style must fire the persistence callback")
    if let saved {
        let blue = NSColor(hexString: saved.strokeColorHex)?.usingColorSpace(.sRGB)
        #expect(blue != nil && blue!.blueComponent > blue!.redComponent)
    }
}

@MainActor
@Test
func aWidthDragInTheEditorPersistsOnceWithItsFinalValue() {
    var saved: [EditorStyles] = []
    let (view, window) = makeEditorView(onStylesChanged: { saved.append($0) })

    view.keyDown(with: key("r", 15, window))
    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    #expect(row != nil, "The detached editor hosts the same tool-options row")

    row?.onGestureBegan?()
    for width in [8, 11, 15] as [CGFloat] { row?.onLineWidthSelected?(width) }
    row?.onGestureEnded?()

    #expect(saved.count == 1, "A whole drag should persist once, not per tick")
    #expect(saved.last?.strokeLineWidth == 15,
            "The persisted width should be where the drag ended")
}

@MainActor
@Test
func persistedStylesAreLoadedOnInit() {
    var styles = EditorStyles()
    styles.strokeColorHex = "#00FF00"
    styles.strokeLineWidth = 6
    let (view, window) = makeEditorView(styles: styles)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // Draw a rectangle with the persisted (green) stroke style.
    view.keyDown(with: key("r", 15, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 40, y: 40), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 120), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 120, y: 120), view: view, window: window))

    view.keyDown(with: key("s", 1, window))
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 180, y: 180), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 180, y: 180), view: view, window: window))
    view.keyDown(with: key("\r", 36, window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }
    // Top edge of the rect: view (80, 40) → baked (70, 30).
    let bpr = baked.bytesPerRow
    let offset = 30 * bpr + 70 * 4
    let r = bytes[offset]
    let g = bytes[offset + 1]
    #expect(g > 150 && r < 110, "Rectangle should use persisted green stroke, got R=\(r) G=\(g)")
}

// MARK: - Selection rect adjustment (PRD §6.1 step 5)

@MainActor
@Test
func selectionRectIsResizableAfterDrawing() {
    let (view, window) = makeEditorView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // Draw a 60×60 selection, then drag its bottom-right handle out by 40.
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 80, y: 80), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 80, y: 80), view: view, window: window))

    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 80, y: 80), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 120), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 120, y: 120), view: view, window: window))

    view.keyDown(with: key("\r", 36, window))
    #expect(baked?.width == 100, "Selection should have been resized to 100, got \(String(describing: baked?.width))")
    #expect(baked?.height == 100)
}

@MainActor
@Test
func selectionRectIsMovableByDraggingInside() {
    let (view, window) = makeEditorView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 80, y: 80), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 80, y: 80), view: view, window: window))

    // Drag from the middle of the selection (no annotation there) to move it.
    view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), view: view, window: window))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 90, y: 90), view: view, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 90, y: 90), view: view, window: window))

    view.keyDown(with: key("\r", 36, window))
    // Same size, new position — size is the observable here.
    #expect(baked?.width == 60)
    #expect(baked?.height == 60)
}

// MARK: - Hex helpers

@Test
func hexColorRoundTrips() {
    let color = NSColor(hexString: "#3A7BD5")
    #expect(color != nil)
    #expect(color?.hexRGBString == "#3A7BD5")
    #expect(NSColor(hexString: "FFCC00")?.hexRGBString == "#FFCC00")
    #expect(NSColor(hexString: "nope") == nil)
    #expect(NSColor(hexString: "#12345") == nil)
}
