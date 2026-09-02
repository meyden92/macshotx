import AppKit
import Testing
@testable import MacshotCore

private func makeSourceImage(width: Int = 100, height: Int = 100) -> CGImage {
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

private func makeDestContext(width: Int = 100, height: Int = 100) -> CGContext {
    return CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 4 * width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

@MainActor
@Test
func toolShortcutsAreUnique() {
    var seen: [String: Tool] = [:]
    for tool in Tool.allCases where !tool.keyEquivalent.isEmpty {
        let key = tool.keyEquivalent
        #expect(seen[key] == nil, "Duplicate shortcut '\(key)' for \(tool) and \(seen[key]!)")
        seen[key] = tool
    }
}

@MainActor
@Test
func toolListIncludesAllPRDTools() {
    let cases = Set(Tool.allCases)
    let expected: Set<Tool> = [
        .select, .rectangle, .ellipse, .line, .arrow,
        .pen, .highlighter, .spotlight, .text, .callout, .stepMarker, .measure, .loupe,
        .fillRect, .fillFreehand, .blur, .pixelate
    ]
    #expect(cases == expected, "Tool.allCases drifted from the expected v1 toolbar")
}

@MainActor
@Test
func toolGroupingIsConsistent() {
    let groups: [Tool: ToolGroup] = [
        .select: .selection,
        .rectangle: .shapes, .ellipse: .shapes, .line: .shapes, .arrow: .shapes,
        .pen: .drawing, .highlighter: .drawing, .spotlight: .drawing,
        .text: .text, .callout: .text,
        .stepMarker: .markers, .measure: .markers, .loupe: .markers,
        .fillRect: .redaction, .fillFreehand: .redaction,
        .blur: .redaction, .pixelate: .redaction
    ]
    for (tool, expected) in groups {
        #expect(tool.group == expected, "\(tool) group is \(tool.group), expected \(expected)")
    }
}

@MainActor
@Test
func rendererDrawsEveryAnnotationType() {
    let source = makeSourceImage()
    let renderer = AnnotationRenderer(source: source, scale: 1.0)
    let ctx = makeDestContext()

    let annotations: [Annotation] = [
        .rectangle(CGRect(x: 10, y: 10, width: 30, height: 20), .default),
        .ellipse(CGRect(x: 10, y: 10, width: 30, height: 20), .default),
        .line(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 50), .default),
        .arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 80, y: 80), .default),
        .freehand(points: [CGPoint(x: 5, y: 5), CGPoint(x: 20, y: 20), CGPoint(x: 35, y: 5)], .default),
        .highlighter(
            points: [CGPoint(x: 5, y: 5), CGPoint(x: 50, y: 5)],
            .highlighter
        ),
        .text(box: CGRect(origin: CGPoint(x: 10, y: 10), size: TextLayout.defaultBoxSize), content: "Hello", .default),
        .callout(
            anchor: CGPoint(x: 90, y: 90),
            box: CGRect(origin: CGPoint(x: 20, y: 20), size: TextLayout.defaultBoxSize),
            content: "Wat",
            .default
        ),
        .stepMarker(center: CGPoint(x: 50, y: 50), number: 1, FillStyle(color: .systemRed)),
        .measure(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 80, y: 60), .default),
        .loupe(
            source: CGPoint(x: 30, y: 30), sourceRadius: 20,
            lens: CGPoint(x: 80, y: 80), lensRadius: 40, .default
        ),
        .spotlight(CGRect(x: 10, y: 10, width: 40, height: 40), .default),
        .fillRect(CGRect(x: 10, y: 10, width: 30, height: 20), .redact),
        .fillFreehand(
            points: [CGPoint(x: 5, y: 5), CGPoint(x: 30, y: 5), CGPoint(x: 17, y: 30)],
            .redact
        ),
        .blur(CGRect(x: 10, y: 10, width: 30, height: 20)),
        .pixelate(CGRect(x: 10, y: 10, width: 30, height: 20))
    ]

    for annotation in annotations {
        renderer.draw(annotation, in: ctx)
    }
    #expect(ctx.makeImage() != nil, "Renderer produced no output after all annotations")
}

@MainActor
private func makeHostedView(width: Int = 200, height: Int = 200) -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let source = makeSourceImage(width: width, height: height)
    // Editor mode: these test annotations and the bake, which both surfaces
    // share, against a crop Selection that stays put.
    let view = RegionPickerView(frame: frame, image: source, scale: 1.0, requiresSelection: false)
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func keyEvent(_ char: String, keyCode: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: char,
        charactersIgnoringModifiers: char,
        isARepeat: false,
        keyCode: keyCode
    )!
}

@MainActor
private func mouseEvent(
    _ kind: NSEvent.EventType,
    atViewPoint point: CGPoint,
    in view: RegionPickerView,
    window: NSWindow,
    clickCount: Int = 1,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    // The view is flipped (top-left). Convert top-left view point → window (bottom-left) coords.
    let windowLocation = NSPoint(x: point.x, y: view.bounds.height - point.y)
    return NSEvent.mouseEvent(
        with: kind,
        location: windowLocation,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1.0
    )!
}

@MainActor
@Test
func pickerDragsSelectionAndCommitsViaReturn() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 20, y: 30), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 120, y: 130), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 120, y: 130), in: view, window: window))

    // Return commits
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    #expect(baked != nil, "Return after a selection drag should bake an image")
    #expect(baked?.width == 100, "Baked image width should match selection width × scale")
    #expect(baked?.height == 100, "Baked image height should match selection height × scale")
}

@MainActor
@Test
func pickerBakesRectangleAnnotationIntoSelection() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // Press R to switch to rectangle tool
    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))

    // Drag a rectangle annotation from (40, 40) to (60, 60) (in flipped view points)
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 40, y: 40), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 60, y: 60), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 60, y: 60), in: view, window: window))

    // Press S to switch back to select tool, then drag a selection that contains the rect
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 10, y: 10), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))

    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image produced")
        return
    }

    // The rectangle annotation outline at view-points (40,40)-(60,60), 3pt red stroke.
    // After selection at (10,10)-(100,100), the baked image is cropped from (10,10) to (100,100).
    // So inside the baked image, the rectangle annotation appears at (30,30)-(50,50).
    // Sample a pixel ON the top-edge of that rectangle.
    let bpr = baked.bytesPerRow
    let edgeOffset = 30 * bpr + 40 * 4
    let r = bytes[edgeOffset]
    let g = bytes[edgeOffset + 1]
    let b = bytes[edgeOffset + 2]
    // .systemRed nominally has high red, low green/blue.
    #expect(r > 200, "Top edge of red rectangle annotation should have high red, got R=\(r)")
    #expect(g < 100, "Top edge of red rectangle annotation should have low green, got G=\(g)")
    #expect(b < 100, "Top edge of red rectangle annotation should have low blue, got B=\(b)")
}

@MainActor
@Test
func pickerEscapeCancels() async {
    let (view, window) = makeHostedView()
    var cancelled = false
    view.onCancel = { cancelled = true }

    view.keyDown(with: keyEvent("\u{1B}", keyCode: 53, window: window))
    #expect(cancelled, "Esc should fire onCancel")
}

@MainActor
@Test
func pickerUndoRemovesAnnotation() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // Draw a red fillRect annotation in the redaction style (black fill)
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 40, y: 40), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 60, y: 60), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 60, y: 60), in: view, window: window))

    // Undo with Cmd+Z
    view.keyDown(with: keyEvent("z", keyCode: 6, window: window, modifiers: [.command]))

    // Select region containing where the fill rect would have been, confirm
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 10, y: 10), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image produced")
        return
    }

    // Pixel where the (undone) black fill would have been should still be the gray source color
    let bpr = baked.bytesPerRow
    let pixelOffset = 40 * bpr + 40 * 4
    let r = bytes[pixelOffset]
    #expect(r > 100, "After undo, the pixel inside the deleted fill rect should be source gray, got R=\(r)")
}

@MainActor
@Test
func pickerTextEditingCommitsOnReturn() async {
    let (view, window) = makeHostedView()
    window.makeKeyAndOrderFront(nil)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // Switch to text tool
    view.keyDown(with: keyEvent("t", keyCode: 17, window: window))

    // Click to place text input
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 30, y: 30), in: view, window: window))

    // Find the spawned inline editor and set its value programmatically
    let editor = view.subviews.compactMap { $0 as? InlineTextView }.first
    #expect(editor != nil, "Text tool click should spawn the inline editor")
    editor?.string = "Hi"
    // Confirming the capture commits whatever is being typed.

    // Select + confirm
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 10, y: 10), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 150, y: 150), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 150, y: 150), in: view, window: window))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    #expect(baked != nil, "Selection drag + Return after a text annotation should bake")
}

@MainActor
private func drawFillRectAnnotation(in view: RegionPickerView, window: NSWindow, rect: CGRect) {
    view.keyDown(with: keyEvent("f", keyCode: 3, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: rect.minX, y: rect.minY), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: rect.maxX, y: rect.maxY), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: rect.maxX, y: rect.maxY), in: view, window: window))
}

@MainActor
@Test
func pickerStyleStripAppliesColorToNextAnnotation() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))

    // Open the picker from the colour well and click its blue standard swatch.
    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    row?.onColorWellClicked?()
    let panel = view.subviews.compactMap { $0 as? ColorPickerPanelView }.first
    let blueSwatch = panel?.standardSwatches.first { $0.color.matchesColor(.systemBlue) }
    #expect(blueSwatch != nil, "The picker should expose a blue standard swatch")
    blueSwatch?.onClick?(.systemBlue)

    // Now draw a rectangle annotation. It should use the new color.
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 40, y: 40), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window))

    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 5, y: 5), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }
    // Top edge of the rect lands at baked (35..35+strokeWidth, 35). Sample (40, 35).
    let bpr = baked.bytesPerRow
    let offset = 35 * bpr + 40 * 4
    let r = bytes[offset]
    let g = bytes[offset + 1]
    let b = bytes[offset + 2]
    #expect(b > r, "Rectangle should pick up blue, got R=\(r) G=\(g) B=\(b)")
    #expect(b > g, "Rectangle should pick up blue, got R=\(r) G=\(g) B=\(b)")
}

@MainActor
@Test
func toolOptionsRowAppliesAnArbitraryLineWidthToTheNextAnnotation() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))

    // 14pt is not one of the three widths the old fixed strip could produce.
    let toolbar = view.subviews.compactMap { $0 as? RegionToolbarView }.first
    let row = toolbar?.subviews.compactMap { $0 as? ToolOptionsRowView }.first
    #expect(row != nil, "The toolbar should host a tool-options row")
    row?.onLineWidthSelected?(14)

    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 40, y: 40), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 90, y: 90), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 90, y: 90), in: view, window: window))

    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 5, y: 5), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }
    // The stroke is centred on the top edge at view y=40 — baked y=35. A 14pt
    // stroke reaches 5pt inside it; the 3pt default would leave grey there.
    let bpr = baked.bytesPerRow
    let inside = 40 * bpr + 50 * 4
    let beyond = 27 * bpr + 50 * 4
    #expect(bytes[inside] > bytes[inside + 2] + 40,
            "5pt inside the edge should be stroke, got R=\(bytes[inside]) B=\(bytes[inside + 2])")
    #expect(bytes[beyond] <= bytes[beyond + 2] + 20,
            "8pt outside the edge should stay background, got R=\(bytes[beyond]) B=\(bytes[beyond + 2])")
}

@MainActor
@Test
func theToolOptionsRowShowsOnlyApplicableControlsAndCollapsesWhenThereAreNone() {
    let row = ToolOptionsRowView()

    row.configure(
        options: Tool.rectangle.options,
        style: AnnotationStyle(color: .systemRed, lineWidth: 3)
    )
    let colorAndSlider = row.frame.width
    #expect(colorAndSlider > 0 && !row.isHidden)

    row.configure(
        options: Tool.stepMarker.options, style: AnnotationStyle(color: .systemRed)
    )
    #expect(row.frame.width > 0 && row.frame.width < colorAndSlider,
            "Colour alone should be narrower than colour plus a slider")

    for tool in [Tool.select, .blur, .pixelate] {
        row.configure(options: tool.options, style: AnnotationStyle())
        #expect(row.frame.width == 0 && row.isHidden,
                "\(tool) has no options, so the row should take up no room")
    }
}

@MainActor
@Test
func pickerDeleteRemovesSelectedAnnotation() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    drawFillRectAnnotation(in: view, window: window, rect: CGRect(x: 40, y: 40, width: 20, height: 20))

    // Select tool, click inside the fill rect
    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))

    // Delete key
    view.keyDown(with: keyEvent("\u{7F}", keyCode: 51, window: window))

    // Region select + confirm
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 10, y: 10), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }

    // Pixel inside what used to be the fill rect: view (50,50) -> baked pixel
    // (50-10, 50-10) = (40, 40). After delete, should be source gray, not black.
    let bpr = baked.bytesPerRow
    let offset = 40 * bpr + 40 * 4
    let r = bytes[offset]
    #expect(r > 100, "After delete, pixel should be source color (gray), got R=\(r)")
}

@MainActor
@Test
func pickerResizeHandleEnlargesAnnotation() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    drawFillRectAnnotation(in: view, window: window, rect: CGRect(x: 40, y: 40, width: 20, height: 20))

    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    // Click inside the fill rect to select
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))

    // Drag the bottom-right handle from (60, 60) out to (90, 90) -> resize to (40, 40, 50, 50)
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 60, y: 60), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 90, y: 90), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 90, y: 90), in: view, window: window))

    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 5, y: 5), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))

    guard let baked,
          let data = baked.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No baked image")
        return
    }

    // Resized fillRect is (40, 40, 50, 50). Cropped at (5, 5) so view (75, 75) -> baked (70, 70).
    // That pixel is INSIDE the resized rect now (40..90) -> should be black fill.
    let bpr = baked.bytesPerRow
    let offset = 70 * bpr + 70 * 4
    let r = bytes[offset]
    #expect(r < 100, "After resize, pixel (75,75) should be inside the enlarged fill, got R=\(r)")
}

@MainActor
@Test
func pickerEscDeselectsBeforeCancel() async {
    let (view, window) = makeHostedView()
    var cancelCount = 0
    view.onCancel = { cancelCount += 1 }

    drawFillRectAnnotation(in: view, window: window, rect: CGRect(x: 40, y: 40, width: 20, height: 20))

    view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))

    // First Esc: deselect, don't cancel
    view.keyDown(with: keyEvent("\u{1B}", keyCode: 53, window: window))
    #expect(cancelCount == 0, "First Esc should deselect, not cancel")

    // Second Esc: cancel
    view.keyDown(with: keyEvent("\u{1B}", keyCode: 53, window: window))
    #expect(cancelCount == 1, "Second Esc should cancel")
}

@MainActor
@Test
func pixelateSamplesFromSameVisualRegion() {
    // 200x200 source: visual top-left is GREEN, visual bottom-left is RED.
    // (CGContext origin is lower-left, so y=100..200 is the visual top half.)
    let ctx = makeDestContext(width: 200, height: 200)
    ctx.setFillColor(NSColor.green.cgColor)
    ctx.fill(CGRect(x: 0, y: 100, width: 100, height: 100))
    ctx.setFillColor(NSColor.red.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    let source = ctx.makeImage()!
    let renderer = AnnotationRenderer(source: source, scale: 1.0)

    // Destination matches bake(): pixel-sized buffer with a flip CTM.
    let dest = makeDestContext(width: 200, height: 200)
    dest.translateBy(x: 0, y: 200)
    dest.scaleBy(x: 1, y: -1)

    let nsCtx = NSGraphicsContext(cgContext: dest, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    // Annotation at view-top-left (10, 10, 80, 80) — sits inside the visual
    // top-left of the source.
    renderer.draw(.pixelate(CGRect(x: 10, y: 10, width: 80, height: 80)), in: dest)
    NSGraphicsContext.restoreGraphicsState()

    guard let output = dest.makeImage(),
          let data = output.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("Pixelate produced no output")
        return
    }

    // Sample pixel at row 50, col 50 (top-down) of the output — well inside the
    // annotation rect (10..90, 10..90 view-top-left). The source slice should
    // come from the visual top-left (GREEN), not the visual bottom-left (RED).
    let bpr = output.bytesPerRow
    let offset = 50 * bpr + 50 * 4
    let r = bytes[offset]
    let g = bytes[offset + 1]
    #expect(g > r, "Pixelate slice should be GREEN (visual top-left), got R=\(r) G=\(g)")
}

@MainActor
@Test
func pixelateLivePreviewSamplesSameVisualRegion() {
    // Exercises the LIVE PREVIEW path: a real RegionPickerView (isFlipped=true)
    // hosted in a window, drawn into a bitmap via cacheDisplay — same draw
    // method the user sees on screen.
    let ctx = makeDestContext(width: 200, height: 200)
    ctx.setFillColor(NSColor.green.cgColor)
    ctx.fill(CGRect(x: 0, y: 100, width: 200, height: 100))    // top half visually
    ctx.setFillColor(NSColor.red.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))      // bottom half visually
    let source = ctx.makeImage()!

    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let view = RegionPickerView(frame: frame, image: source, scale: 1.0)
    window.contentView = view
    window.makeFirstResponder(view)

    // Pixelate tool (X), drag a rect in the top-left quadrant (visual GREEN).
    view.keyDown(with: keyEvent("x", keyCode: 7, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 10, y: 10), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 90, y: 90), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 90, y: 90), in: view, window: window))

    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        Issue.record("Couldn't create bitmap rep")
        return
    }
    view.cacheDisplayWithoutChrome(to: rep)
    guard let cg = rep.cgImage,
          let data = cg.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("No cgImage from cached display")
        return
    }
    let bpr = cg.bytesPerRow
    let imageScale = CGFloat(cg.width) / 200.0
    // The resolution box tracks the draft and floats over this spot, so the
    // capture leaves the chrome out and samples the preview underneath it.
    let row = Int(25 * imageScale)
    let col = Int(50 * imageScale)
    let offset = row * bpr + col * 4
    let r = bytes[offset]
    let g = bytes[offset + 1]
    #expect(g > r, "Live-preview pixelate slice should be GREEN (visual top-left), got R=\(r) G=\(g)")
}

@MainActor
@Test
func pixelateActuallyQuantizesIntoBlocks() {
    // Per-column gradient so every adjacent column differs in the raw source.
    let src = makeDestContext(width: 200, height: 200)
    for x in 0..<200 {
        src.setFillColor(NSColor(white: CGFloat(x) / 200.0, alpha: 1).cgColor)
        src.fill(CGRect(x: x, y: 0, width: 1, height: 200))
    }
    let source = src.makeImage()!
    let renderer = AnnotationRenderer(source: source, scale: 1.0)

    let dest = makeDestContext(width: 200, height: 200)
    dest.translateBy(x: 0, y: 200)
    dest.scaleBy(x: 1, y: -1)
    let nsCtx = NSGraphicsContext(cgContext: dest, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    renderer.draw(.pixelate(CGRect(x: 0, y: 0, width: 200, height: 200)), in: dest)
    NSGraphicsContext.restoreGraphicsState()

    let output = dest.makeImage()!
    let data = output.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let bpr = output.bytesPerRow
    // Adjacent columns inside one 12px block must be equal once pixelated.
    let row = 100
    let a = bytes[row * bpr + 50 * 4]
    let b = bytes[row * bpr + 51 * 4]
    #expect(a == b, "Adjacent pixels in a block should be equal when pixelated, got \(a) vs \(b)")
}

@MainActor
@Test
func pixelatePreservesVerticalOrientation() {
    // Visual top half green, bottom half red (CGContext origin is lower-left).
    let src = makeDestContext(width: 200, height: 200)
    src.setFillColor(NSColor.green.cgColor)
    src.fill(CGRect(x: 0, y: 100, width: 200, height: 100))
    src.setFillColor(NSColor.red.cgColor)
    src.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    let source = src.makeImage()!
    let renderer = AnnotationRenderer(source: source, scale: 1.0)

    let dest = makeDestContext(width: 200, height: 200)
    dest.translateBy(x: 0, y: 200)
    dest.scaleBy(x: 1, y: -1)
    let nsCtx = NSGraphicsContext(cgContext: dest, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    renderer.draw(.pixelate(CGRect(x: 0, y: 0, width: 200, height: 200)), in: dest)
    NSGraphicsContext.restoreGraphicsState()

    let output = dest.makeImage()!
    let data = output.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    let bpr = output.bytesPerRow
    // Output rows are top-down: row 30 = visual top (green), row 170 = bottom (red).
    let topR = bytes[30 * bpr + 100 * 4], topG = bytes[30 * bpr + 100 * 4 + 1]
    let botR = bytes[170 * bpr + 100 * 4], botG = bytes[170 * bpr + 100 * 4 + 1]
    #expect(topG > topR, "Top of pixelated region should be green, got R=\(topR) G=\(topG)")
    #expect(botR > botG, "Bottom of pixelated region should be red, got R=\(botR) G=\(botG)")
}

@MainActor
@Test
func blurSoftensHardEdge() {
    // Source with a hard vertical white|black edge at x=100.
    let ctx = makeDestContext(width: 200, height: 200)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
    let source = ctx.makeImage()!
    let renderer = AnnotationRenderer(source: source, scale: 1.0)

    let dest = makeDestContext(width: 200, height: 200)
    dest.translateBy(x: 0, y: 200)
    dest.scaleBy(x: 1, y: -1)
    let nsCtx = NSGraphicsContext(cgContext: dest, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    // Blur a region straddling the edge.
    renderer.draw(.blur(CGRect(x: 50, y: 50, width: 100, height: 100)), in: dest)
    NSGraphicsContext.restoreGraphicsState()

    guard let output = dest.makeImage(),
          let data = output.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("Blur produced no output")
        return
    }

    // A pixel right on the former hard edge should now be a grey blend, proving
    // the blur actually rendered (not pure white and not pure black).
    let bpr = output.bytesPerRow
    let offset = 100 * bpr + 100 * 4
    let r = bytes[offset]
    #expect(r > 40 && r < 215, "Blurred edge pixel should be a grey blend, got R=\(r)")
}

@MainActor
@Test
func pixelateRendersAtImageCorners() {
    // Solid grey source; dest starts transparent-black. If a corner slice fails
    // to render, the sampled pixel stays 0.
    let source = makeSourceImage(width: 200, height: 200)
    let renderer = AnnotationRenderer(source: source, scale: 1.0)

    let dest = makeDestContext(width: 200, height: 200)
    dest.translateBy(x: 0, y: 200)
    dest.scaleBy(x: 1, y: -1)
    let nsCtx = NSGraphicsContext(cgContext: dest, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    renderer.draw(.pixelate(CGRect(x: 0, y: 0, width: 30, height: 30)), in: dest)
    renderer.draw(.pixelate(CGRect(x: 170, y: 170, width: 30, height: 30)), in: dest)
    NSGraphicsContext.restoreGraphicsState()

    guard let output = dest.makeImage(),
          let data = output.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("Pixelate produced no output")
        return
    }
    let bpr = output.bytesPerRow
    let topLeft = bytes[10 * bpr + 10 * 4]
    let bottomRight = bytes[180 * bpr + 180 * 4]
    #expect(topLeft > 80, "Top-left corner pixelation should render source grey, got R=\(topLeft)")
    #expect(bottomRight > 80, "Bottom-right corner pixelation should render source grey, got R=\(bottomRight)")
}

/// A drag inside an existing element is how you put a smaller shape inside a
/// redact box or a label over an arrow, so the active drawing tool owns it —
/// hit-testing must not turn it into a move.
@MainActor
@Test
func aDragInsideAnExistingElementDrawsANewOneWhileADrawToolIsActive() {
    let (view, window) = makeHostedView()

    // Draw a black fill rect; this leaves the fill-rect tool active (no switch to select).
    drawFillRectAnnotation(in: view, window: window, rect: CGRect(x: 40, y: 40, width: 20, height: 20))
    let placed = view.annotations

    // Still in the draw tool: drag from inside the fill out to (70,70).
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window))

    #expect(view.annotations.count == 2, "The drag should have drawn a second element")
    #expect(view.annotations.first == placed.first, "and left the one underneath where it was")
    guard case let .fillRect(drawn, _)? = view.annotations.last else {
        Issue.record("Expected the drag to draw a fill rect")
        return
    }
    #expect(drawn == CGRect(x: 50, y: 50, width: 20, height: 20))
}

@MainActor
@Test
func aBareClickStillSelectsAnElementWithoutLeavingTheDrawTool() {
    let (view, window) = makeHostedView()
    // A rectangle rather than a fill, so there is a stroke width to read back.
    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 40, y: 40), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))

    // A click draws nothing, so it can still pick up what is underneath.
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window))

    #expect(view.annotations.count == 1, "A bare click must not place anything")
    // Selected, so the options row now restyles it rather than the tool default.
    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    row?.onLineWidthSelected?(9)
    #expect(view.annotations.last?.style.lineWidth == 9)
}

@MainActor
@Test
func theSelectToolAndCommandBothStillGrabAndMoveAPlacedElement() {
    for (label, modifiers, switchToSelect) in [
        ("select tool", NSEvent.ModifierFlags(), true),
        ("command held", NSEvent.ModifierFlags.command, false)
    ] {
        let (view, window) = makeHostedView()
        drawFillRectAnnotation(in: view, window: window, rect: CGRect(x: 40, y: 40, width: 20, height: 20))
        if switchToSelect {
            view.keyDown(with: keyEvent("s", keyCode: 1, window: window))
        }

        view.mouseDown(with: mouseEvent(
            .leftMouseDown, atViewPoint: CGPoint(x: 50, y: 50), in: view, window: window,
            modifiers: modifiers
        ))
        view.mouseDragged(with: mouseEvent(
            .leftMouseDragged, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window,
            modifiers: modifiers
        ))
        view.mouseUp(with: mouseEvent(
            .leftMouseUp, atViewPoint: CGPoint(x: 70, y: 70), in: view, window: window,
            modifiers: modifiers
        ))

        #expect(view.annotations.count == 1, "\(label): the drag should move, not draw")
        guard case let .fillRect(moved, _)? = view.annotations.last else {
            Issue.record("\(label): expected the fill rect to still be there")
            continue
        }
        #expect(moved == CGRect(x: 60, y: 60, width: 20, height: 20), "\(label): moved by the drag delta")
    }
}

@MainActor
@Test
func rendererChangesPixelsInsideAnnotation() {
    let source = makeSourceImage()
    let renderer = AnnotationRenderer(source: source, scale: 1.0)
    let ctx = makeDestContext()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))

    // Mirror RegionPicker.bake(): flip so annotation coords use top-left origin.
    ctx.translateBy(x: 0, y: 100)
    ctx.scaleBy(x: 1, y: -1)

    renderer.draw(
        .fillRect(CGRect(x: 30, y: 30, width: 20, height: 20), .redact),
        in: ctx
    )

    guard let image = ctx.makeImage(),
          let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        Issue.record("Could not read back pixels")
        return
    }

    // Sample a pixel inside the filled rect (35, 35) and outside (5, 5)
    let bpr = image.bytesPerRow
    let insideOffset = 35 * bpr + 35 * 4
    let outsideOffset = 5 * bpr + 5 * 4

    let insideR = bytes[insideOffset]
    let outsideR = bytes[outsideOffset]
    #expect(insideR == 0, "Pixel inside black fill rect should be 0, got \(insideR)")
    #expect(outsideR == 255, "Pixel outside fill rect should remain white, got \(outsideR)")
}
