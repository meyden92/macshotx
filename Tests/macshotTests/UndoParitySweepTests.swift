import AppKit
import Testing
@testable import MacshotCore

// The closing sweep for phase 4: every edit the phase added undoes and redoes
// to exactly the prior state, continuous gestures collapse to one entry each,
// multi-selection operations land as one grouped entry, and all of it behaves
// the same in the detached editor window as on the capture overlay.

@MainActor
private func makeView(requiresSelection: Bool) -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 300, height: 300,
        bitsPerComponent: 8, bytesPerRow: 4 * 300,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
    let frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: ctx.makeImage()!, scale: 1.0, requiresSelection: requiresSelection
    )
    window.contentView = view
    window.makeFirstResponder(view)
    window.makeKeyAndOrderFront(nil)
    return (view, window)
}

@MainActor
private func key(
    _ char: String, _ code: UInt16, _ window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code
    )!
}

@MainActor
private func mouse(
    _ kind: NSEvent.EventType, _ point: CGPoint,
    _ view: RegionPickerView, _ window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.mouseEvent(
        with: kind, location: NSPoint(x: point.x, y: view.bounds.height - point.y),
        modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1.0
    )!
}

@MainActor
private func drag(
    _ view: RegionPickerView, _ window: NSWindow, from: CGPoint, to: CGPoint,
    modifiers: NSEvent.ModifierFlags = [], ticks: Int = 1
) {
    view.mouseDown(with: mouse(.leftMouseDown, from, view, window, modifiers: modifiers))
    for tick in 1...ticks {
        let t = CGFloat(tick) / CGFloat(ticks)
        let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        view.mouseDragged(with: mouse(.leftMouseDragged, point, view, window, modifiers: modifiers))
    }
    view.mouseUp(with: mouse(.leftMouseUp, to, view, window, modifiers: modifiers))
}

@MainActor
private func click(_ view: RegionPickerView, _ window: NSWindow, at point: CGPoint) {
    drag(view, window, from: point, to: point)
}

@MainActor
private func undo(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: key("z", 6, window, modifiers: [.command]))
}

@MainActor
private func redo(_ view: RegionPickerView, _ window: NSWindow) {
    view.keyDown(with: key("z", 6, window, modifiers: [.command, .shift]))
}

@MainActor
private func row(_ view: RegionPickerView) -> ToolOptionsRowView? {
    view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
}

/// Draws a rectangle at (40,40)–(140,120) with the given tool and selects it.
@MainActor
private func placeAndSelect(
    _ view: RegionPickerView, _ window: NSWindow,
    tool: (String, UInt16) = ("r", 15)
) {
    view.keyDown(with: key(tool.0, tool.1, window))
    drag(view, window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 140, y: 120))
    click(view, window, at: CGPoint(x: 90, y: 80))
}

// MARK: - Every phase-4 edit undoes and redoes

/// One row per style axis the phase added: apply it to a placed annotation,
/// then read the axis back out of the document.
private struct StyleCase {
    let name: String
    let tool: (String, UInt16)
    let apply: @MainActor (ToolOptionsRowView?) -> Void
    let read: (AnnotationStyle) -> String
}

@MainActor
private let styleCases: [StyleCase] = [
    StyleCase(name: "line width", tool: ("r", 15),
              apply: { $0?.onLineWidthSelected?(11) },
              read: { "\($0.lineWidth ?? 0)" }),
    StyleCase(name: "font size", tool: ("t", 17),
              apply: { $0?.onFontSizeSelected?(44) },
              read: { "\($0.fontSize ?? 0)" }),
    StyleCase(name: "dash style", tool: ("l", 37),
              apply: { $0?.onDashSelected?(.dotted) },
              read: { "\($0.dash?.rawValue ?? "")" }),
    StyleCase(name: "arrow head", tool: ("a", 0),
              apply: { $0?.onArrowHeadSelected?(.openV) },
              read: { "\($0.arrowHead?.rawValue ?? "")" }),
    StyleCase(name: "fill mode", tool: ("r", 15),
              apply: { $0?.onFillModeSelected?(.fillOnly) },
              read: { "\($0.fillMode?.rawValue ?? "")" }),
    StyleCase(name: "corner radius", tool: ("r", 15),
              apply: { $0?.onCornerRadiusSelected?(9) },
              read: { "\($0.cornerRadius ?? 0)" }),
    StyleCase(name: "font family", tool: ("t", 17),
              apply: { $0?.onFontFamilySelected?("Helvetica") },
              read: { $0.fontFamily ?? "" }),
    StyleCase(name: "italic", tool: ("t", 17),
              apply: { $0?.onTraitToggled?(.italic, true) },
              read: { "\($0.italic ?? false)" }),
    StyleCase(name: "underline", tool: ("t", 17),
              apply: { $0?.onTraitToggled?(.underline, true) },
              read: { "\($0.underline ?? false)" }),
    StyleCase(name: "alignment", tool: ("t", 17),
              apply: { $0?.onAlignmentSelected?(.center) },
              read: { $0.alignment?.rawValue ?? "" }),
    StyleCase(name: "text background", tool: ("t", 17),
              apply: { $0?.onTextBackgroundToggled?(true) },
              read: { ($0.backgroundColor ?? nil) == nil ? "off" : "on" }),
    StyleCase(name: "glyph outline", tool: ("t", 17),
              apply: { $0?.onTextOutlineToggled?(true) },
              read: { ($0.outlineColor ?? nil) == nil ? "off" : "on" })
]

/// Places something the axis applies to and selects it.
@MainActor
private func placeFor(
    _ testCase: StyleCase, in view: RegionPickerView, _ window: NSWindow
) {
    view.keyDown(with: key(testCase.tool.0, testCase.tool.1, window))
    if testCase.tool.0 == "t" {
        click(view, window, at: CGPoint(x: 40, y: 40))
        view.subviews.compactMap { $0 as? InlineTextView }.first?.string = "Hello"
        view.keyDown(with: key("s", 1, window))
        click(view, window, at: CGPoint(x: 60, y: 50))
    } else {
        drag(view, window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 140, y: 120))
        click(view, window, at: CGPoint(x: 90, y: 80))
    }
}

@MainActor
@Test
func everyStyleAxisUndoesAndRedoesToExactlyThePriorState() {
    for testCase in styleCases {
        let (view, window) = makeView(requiresSelection: false)
        placeFor(testCase, in: view, window)

        guard let before = view.annotations.last?.style else {
            Issue.record("\(testCase.name): nothing was placed")
            continue
        }
        let priorValue = testCase.read(before)
        testCase.apply(row(view))

        guard let changed = view.annotations.last?.style else { continue }
        #expect(testCase.read(changed) != priorValue,
                "\(testCase.name): the edit did not change anything to undo")

        undo(view, window)
        #expect(view.annotations.last.map { testCase.read($0.style) } == priorValue,
                "\(testCase.name): undo did not restore the prior value")

        redo(view, window)
        #expect(view.annotations.last.map { testCase.read($0.style) } == testCase.read(changed),
                "\(testCase.name): redo did not restore the edit")
    }
}

@MainActor
@Test
func rotationAndFlipUndoAndRedo() {
    let (view, window) = makeView(requiresSelection: false)
    placeAndSelect(view, window)

    let knob = CGPoint(x: 90, y: 40 - AnnotationGeometry.rotationHandleOffset)
    drag(view, window, from: knob, to: CGPoint(x: 200, y: 80), ticks: 4)
    let turned = view.annotations.last?.rotation ?? 0
    #expect(turned != 0)

    undo(view, window)
    #expect(view.annotations.last?.rotation == 0, "Undo should unturn it")
    redo(view, window)
    #expect(view.annotations.last?.rotation == turned, "Redo should turn it back")

    // Flip, on an arrow this time.
    let (arrowView, arrowWindow) = makeView(requiresSelection: false)
    arrowView.keyDown(with: key("a", 0, arrowWindow))
    drag(arrowView, arrowWindow, from: CGPoint(x: 40, y: 100), to: CGPoint(x: 160, y: 100))
    click(arrowView, arrowWindow, at: CGPoint(x: 100, y: 100))
    guard case let .arrow(from, to, _)? = arrowView.annotations.last else {
        Issue.record("Expected an arrow")
        return
    }
    row(arrowView)?.onFlip?()
    undo(arrowView, arrowWindow)
    guard case let .arrow(undoneFrom, undoneTo, _)? = arrowView.annotations.last else { return }
    #expect(undoneFrom == from && undoneTo == to, "Undo should put the head back")
}

@MainActor
@Test
func aWholeSliderDragIsStillOneUndoEntryAcrossTheNewAxes() {
    let (view, window) = makeView(requiresSelection: false)
    placeAndSelect(view, window)

    // A corner-radius drag: many live values, one entry.
    row(view)?.onGestureBegan?()
    for radius in [3, 7, 12, 18] as [CGFloat] { row(view)?.onCornerRadiusSelected?(radius) }
    row(view)?.onGestureEnded?()
    #expect(view.annotations.last?.style.cornerRadius == 18)

    // The discriminating assertion: with the drag grouped, the second undo
    // removes the rectangle outright. Per-tick entries would still be walking
    // back through 12, 7 and 3.
    undo(view, window)
    #expect(view.annotations.last?.style.cornerRadius == 0)
    undo(view, window)
    #expect(view.annotations.isEmpty, "A whole drag is one entry, not one per tick")
}

// MARK: - Multi-selection operations are one grouped entry

@MainActor
@Test
func restylingASelectedSetAppliesToAllOfThemAsOneEntry() {
    let (view, window) = makeView(requiresSelection: false)
    view.keyDown(with: key("r", 15, window))
    drag(view, window, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 80, y: 80))
    drag(view, window, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180))

    // A Selection to marquee inside, then a marquee across both.
    view.keyDown(with: key("s", 1, window))
    drag(view, window, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 295, y: 295))
    drag(view, window, from: CGPoint(x: 15, y: 15), to: CGPoint(x: 250, y: 250))
    #expect(view.annotations.count == 2)

    row(view)?.onLineWidthSelected?(9)
    #expect(view.annotations.allSatisfy { $0.style.lineWidth == 9 },
            "A restyle with a set selected should apply to every member")

    undo(view, window)
    #expect(view.annotations.allSatisfy { $0.style.lineWidth == 3 },
            "One undo should take the whole group restyle back")
}

@MainActor
@Test
func theOptionsRowShowsWhatASelectedSetHasInCommon() {
    let (view, window) = makeView(requiresSelection: false)
    // A rectangle and an arrow: they share colour and line width, and nothing
    // else — no corner radius, no head.
    view.keyDown(with: key("r", 15, window))
    drag(view, window, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 80, y: 80))
    view.keyDown(with: key("a", 0, window))
    drag(view, window, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180))

    view.keyDown(with: key("s", 1, window))
    drag(view, window, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 295, y: 295))
    drag(view, window, from: CGPoint(x: 15, y: 15), to: CGPoint(x: 250, y: 250))

    let shared = Tool.rectangle.options.intersection(Annotation.arrow(
        from: .zero, to: .zero, StrokeStyle(color: .systemRed, lineWidth: 3)
    ).options)
    #expect(shared.contains(.color) && shared.contains(.lineWidth))
    #expect(!shared.contains(.cornerRadius) && !shared.contains(.arrowHead))
    #expect(row(view)?.colorWell.isHidden == false,
            "The row should be showing what the pair has in common")
    #expect(row(view)?.fillModeControl.isHidden == true,
            "An option only one member offers should not be on the row")
    #expect(row(view)?.headControl.isHidden == true)
}

// MARK: - Redo stack

@MainActor
@Test
func aNewEditAfterAnUndoDiscardsTheRedoPath() {
    let (view, window) = makeView(requiresSelection: false)
    placeAndSelect(view, window)
    row(view)?.onLineWidthSelected?(9)

    undo(view, window)
    #expect(view.annotations.last?.style.lineWidth == 3)

    // A different edit now: the 9pt width must not come back on redo.
    row(view)?.onLineWidthSelected?(15)
    redo(view, window)
    #expect(view.annotations.last?.style.lineWidth == 15,
            "Redo after a new edit should do nothing at all")
}

// MARK: - Delete and z-order

@MainActor
@Test
func undoOfADeleteRestoresTheAnnotationsInTheirOriginalZOrder() {
    let (view, window) = makeView(requiresSelection: false)
    view.keyDown(with: key("r", 15, window))
    drag(view, window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 60))
    view.keyDown(with: key("o", 31, window))
    drag(view, window, from: CGPoint(x: 80, y: 20), to: CGPoint(x: 120, y: 60))
    view.keyDown(with: key("a", 0, window))
    drag(view, window, from: CGPoint(x: 140, y: 20), to: CGPoint(x: 200, y: 60))

    let order = view.annotations.map(\.tool)
    #expect(order == [.rectangle, .ellipse, .arrow])

    // Marquee all three and delete them in one step.
    view.keyDown(with: key("s", 1, window))
    drag(view, window, from: CGPoint(x: 5, y: 120), to: CGPoint(x: 295, y: 295))
    drag(view, window, from: CGPoint(x: 15, y: 150), to: CGPoint(x: 250, y: 10))
    #expect(view.annotations.count == 3)
    view.keyDown(with: key("\u{08}", 51, window))
    #expect(view.annotations.isEmpty)

    undo(view, window)
    #expect(view.annotations.map(\.tool) == order,
            "Undo should put them back in the order they were drawn")
}

// MARK: - Redactions are untouched by the new axes

@MainActor
@Test
func redactionsIgnoreEveryNewStyleAxisAndStillCropBeforeFiltering() {
    let box = CGRect(x: 10, y: 10, width: 40, height: 40)
    for redaction in [Annotation.blur(box), .pixelate(box)] {
        let written = redaction.applyingStyle {
            $0.color = .systemBlue
            $0.lineWidth = 9
            $0.fillMode = .fillOnly
            $0.cornerRadius = 12
            $0.bold = true
            $0.backgroundColor = .some(.black)
        }
        #expect(written == redaction, "\(redaction.tool) should ignore every style axis")
        #expect(!redaction.supportsRotation, "\(redaction.tool) stays axis-aligned (ADR 0003)")
        #expect(redaction.options.isEmpty)
    }

    // And the crop-then-filter path still produces something: a pixelated
    // region over a two-tone source stops being either pure tone.
    let ctx = CGContext(
        data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    ctx.setFillColor(NSColor.black.cgColor)
    for stripe in stride(from: 0, to: 200, by: 8) {
        ctx.fill(CGRect(x: stripe, y: 0, width: 4, height: 200))
    }
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: ctx.makeImage()!, scale: 1.0, requiresSelection: false
    )
    window.contentView = view
    window.makeFirstResponder(view)

    view.keyDown(with: key("x", 7, window))
    drag(view, window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160))
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("\r", 36, window))

    guard let baked else {
        Issue.record("No baked image")
        return
    }
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    var midTones = 0
    for y in 60..<140 {
        for x in 60..<140 {
            let value = bytes[y * baked.bytesPerRow + x * 4]
            if value > 40 && value < 215 { midTones += 1 }
        }
    }
    #expect(midTones > 100,
            "Pixelating stripes should average them into mid tones, got \(midTones)")
}

// MARK: - Detached editor parity

@MainActor
@Test
func thePhaseBehavesTheSameInTheDetachedEditorWindow() {
    // requiresSelection: false is the detached editor's mode.
    let (view, window) = makeView(requiresSelection: false)

    // Rotation.
    placeAndSelect(view, window)
    let knob = CGPoint(x: 90, y: 40 - AnnotationGeometry.rotationHandleOffset)
    drag(view, window, from: knob, to: CGPoint(x: 200, y: 80))
    #expect(view.annotations.last?.rotation != 0, "Rotation should work in the editor")

    // Shape fill and corner radius.
    row(view)?.onFillModeSelected?(.strokeAndFill)
    row(view)?.onCornerRadiusSelected?(6)
    #expect(view.annotations.last?.style.fillMode == .strokeAndFill)
    #expect(view.annotations.last?.style.cornerRadius == 6)

    // Duplicate, copy and paste.
    view.keyDown(with: key("d", 2, window, modifiers: [.command]))
    #expect(view.annotations.count == 2, "Cmd+D should duplicate in the editor")
    view.keyDown(with: key("c", 8, window, modifiers: [.command]))
    view.keyDown(with: key("v", 9, window, modifiers: [.command]))
    #expect(view.annotations.count == 3, "Cmd+V should paste in the editor")

    // Undo of the paste, as one entry.
    undo(view, window)
    #expect(view.annotations.count == 2)
}

@MainActor
@Test
func theMarqueeWorksInTheEditorOnceThereIsASelectionToMarqueeInside() {
    let (view, window) = makeView(requiresSelection: false)
    view.keyDown(with: key("r", 15, window))
    drag(view, window, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 80, y: 80))
    drag(view, window, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180))

    // The editor starts with no Selection, so one is drawn first — the same
    // gesture rule as the capture overlay, not a different one.
    view.keyDown(with: key("s", 1, window))
    drag(view, window, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 295, y: 295))
    drag(view, window, from: CGPoint(x: 15, y: 15), to: CGPoint(x: 250, y: 250))

    view.keyDown(with: key("\u{08}", 51, window))
    #expect(view.annotations.isEmpty, "A marquee should select both in the editor too")

    undo(view, window)
    #expect(view.annotations.count == 2, "and the delete should be one grouped entry")
}

@MainActor
@Test
func textReEditingWorksInTheDetachedEditorWindow() {
    let (view, window) = makeView(requiresSelection: false)
    view.keyDown(with: key("t", 17, window))
    click(view, window, at: CGPoint(x: 40, y: 40))
    view.subviews.compactMap { $0 as? InlineTextView }.first?.string = "teh"
    view.keyDown(with: key("s", 1, window))

    view.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 60, y: 300 - 50),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 2, pressure: 1.0
    )!)
    let editor = view.subviews.compactMap { $0 as? InlineTextView }.first
    #expect(editor?.string == "teh", "Double-click should re-edit in the editor window")
    editor?.string = "the"
    view.keyDown(with: key("s", 1, window))

    guard case let .text(_, content, _)? = view.annotations.last else {
        Issue.record("Expected a text annotation")
        return
    }
    #expect(content == "the")
}
