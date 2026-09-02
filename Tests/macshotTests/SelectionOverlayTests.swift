import AppKit
import Testing
@testable import MacshotCore

// Overlay-level selection-mechanics tests: wiring only — the rectangle math is
// covered at the pure geometry seam.

@MainActor
private func makeSourceImage(width: Int = 200, height: Int = 200) -> CGImage {
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

/// `overlay` hosts the capture overlay, where a drag captures on release;
/// otherwise the post-capture editor, whose crop Selection stays adjustable
/// — which is where the Resolution box, handles and nudge now live.
@MainActor
private func makeHostedView(
    width: Int = 200, height: Int = 200, overlay: Bool = false
) -> (RegionPickerView, NSWindow) {
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: makeSourceImage(width: width, height: height), scale: 1.0,
        requiresSelection: overlay
    )
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func keyEvent(
    _ char: String,
    keyCode: UInt16,
    window: NSWindow,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
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
    window: NSWindow
) -> NSEvent {
    let windowLocation = NSPoint(x: point.x, y: view.bounds.height - point.y)
    return NSEvent.mouseEvent(
        with: kind,
        location: windowLocation,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1.0
    )!
}

// MARK: - Ticket 04: anchored selection

@MainActor
@Test
func rightClickAnchorsTracksAndLeftClickCaptures() async {
    let (view, window) = makeHostedView(overlay: true)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.rightMouseDown(with: mouseEvent(.rightMouseDown, atViewPoint: CGPoint(x: 30, y: 30), in: view, window: window))
    view.mouseMoved(with: mouseEvent(.mouseMoved, atViewPoint: CGPoint(x: 130, y: 110), in: view, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 130, y: 110), in: view, window: window))

    #expect(baked?.width == 100, "The left click captures the anchored 100pt-wide region")
    #expect(baked?.height == 80)
}

@MainActor
@Test
func escCancelsOnlyTheAnchoredState() async {
    let (view, window) = makeHostedView(overlay: true)
    var cancelled = false
    view.onCancel = { cancelled = true }

    view.rightMouseDown(with: mouseEvent(.rightMouseDown, atViewPoint: CGPoint(x: 30, y: 30), in: view, window: window))
    view.mouseMoved(with: mouseEvent(.mouseMoved, atViewPoint: CGPoint(x: 130, y: 130), in: view, window: window))

    view.keyDown(with: keyEvent("\u{1B}", keyCode: 53, window: window))
    #expect(!cancelled, "Esc while anchored must cancel only the anchored state")

    view.keyDown(with: keyEvent("\u{1B}", keyCode: 53, window: window))
    #expect(cancelled, "A subsequent Esc cancels the capture as before")
}

@MainActor
@Test
func secondRightClickReAnchors() async {
    let (view, window) = makeHostedView(overlay: true)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.rightMouseDown(with: mouseEvent(.rightMouseDown, atViewPoint: CGPoint(x: 30, y: 30), in: view, window: window))
    view.mouseMoved(with: mouseEvent(.mouseMoved, atViewPoint: CGPoint(x: 60, y: 60), in: view, window: window))
    view.rightMouseDown(with: mouseEvent(.rightMouseDown, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseMoved(with: mouseEvent(.mouseMoved, atViewPoint: CGPoint(x: 150, y: 150), in: view, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 150, y: 150), in: view, window: window))

    #expect(baked?.width == 50, "Re-anchoring should pin the corner at the new point")
    #expect(baked?.height == 50)
}

@MainActor
@Test
func rightClickWithExistingSelectionDoesNothing() async {
    let (view, window) = makeHostedView()
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 20, y: 20), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))

    view.rightMouseDown(with: mouseEvent(.rightMouseDown, atViewPoint: CGPoint(x: 150, y: 150), in: view, window: window))
    view.mouseMoved(with: mouseEvent(.mouseMoved, atViewPoint: CGPoint(x: 160, y: 160), in: view, window: window))

    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    #expect(baked?.width == 100, "Right-click must not disturb an existing Selection")
    #expect(baked?.height == 100)
}

// MARK: - Ticket 06: strips follow the Selection

@MainActor
@Test
func toolStripIsLiveFromTheFirstFrameAndFollowsTheSelectionWhileItIsDragged() async {
    let (view, window) = makeHostedView(width: 900, height: 600, overlay: true)
    let toolbar = view.subviews.compactMap { $0 as? RegionToolbarView }.first
    #expect(toolbar?.isHidden == false, "The strip is there before any Selection exists")
    #expect(toolbar?.frame.maxY == 592, "and sits 8pt above the bottom edge")

    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 300, y: 200), in: view, window: window))
    #expect(toolbar?.frame.minY == 208, "While the Selection is live the strip sits 8pt below it")
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 300, y: 200), in: view, window: window))
}

@MainActor
@Test
func editorKeepsStripVisibleWithoutSelection() async {
    let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    let view = RegionPickerView(
        frame: frame, image: makeSourceImage(), scale: 1.0, requiresSelection: false
    )
    window.contentView = view
    let toolbar = view.subviews.compactMap { $0 as? RegionToolbarView }.first
    #expect(toolbar?.isHidden == false,
            "The post-capture editor keeps its strip with no crop Selection")
}

// MARK: - Ticket 07: instant in-overlay tooltips

@MainActor
@Test
func hoveringAToolButtonShowsItsTooltip() async {
    let (view, _) = makeHostedView(width: 900, height: 600)
    let toolbar = view.subviews.compactMap { $0 as? RegionToolbarView }.first
    let button = toolbar?.subviews.compactMap { $0 as? ToolButton }.first { $0.tool == .rectangle }
    #expect(button != nil)

    button?.onHover?(.rectangle)
    let tooltip = view.subviews.compactMap { $0 as? OverlayTooltipView }
        .first { $0.text.contains("Rectangle") }
    #expect(tooltip != nil, "Hover must immediately show an in-overlay tooltip")
    #expect(tooltip?.text == "Rectangle (R)", "Tooltip names the tool and its shortcut")

    button?.onHover?(nil)
    let remaining = view.subviews.compactMap { $0 as? OverlayTooltipView }
        .first { $0.text.contains("Rectangle") }
    #expect(remaining == nil, "Leaving the button dismisses the tooltip")
}

// MARK: - Ticket 08: selecting-state hint

/// The chip currently on the overlay, if any. It is rebuilt rather than
/// toggled, because it says something different in each state.
@MainActor
private func hintText(_ view: RegionPickerView) -> String? {
    view.subviews.compactMap { $0 as? OverlayTooltipView }
        .first { $0.text.contains("move") }?.text
}

@MainActor
@Test
func theHintNamesTheGestureConstraintsAndThenHowToMoveWhatWasDrawn() async {
    let (view, window) = makeHostedView(width: 900, height: 600)
    #expect(hintText(view) == nil, "Nothing to say before there is a Selection")

    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 300, y: 200), in: view, window: window))
    #expect(hintText(view)?.contains("Space") == true,
            "While shaping the Selection the hint names that gesture's constraints")

    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 300, y: 200), in: view, window: window))
    // The whole point of the chip outliving the drag: dragging the interior
    // and nudging with the arrows have no other affordance, and Space has
    // stopped meaning anything now that the mouse is up.
    let committed = hintText(view)
    #expect(committed?.contains("Drag inside to move") == true,
            "Once committed the hint says how to move it")
    #expect(committed?.contains("Arrows") == true, "and names the keyboard route")
    #expect(committed?.contains("Space") == false, "Space is gone with the gesture")
}

@MainActor
@Test
func hintStaysSuppressedByTheSetting() async {
    let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    let view = RegionPickerView(
        frame: frame, image: makeSourceImage(), scale: 1.0, requiresSelection: false,
        showOverlayHints: false
    )
    window.contentView = view
    window.makeFirstResponder(view)

    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 100, y: 100), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 300, y: 200), in: view, window: window))
    #expect(hintText(view) == nil, "The hint honours the suppression setting")

    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 300, y: 200), in: view, window: window))
    #expect(hintText(view) == nil, "including the committed-Selection hint")
}

// MARK: - Moving a committed Selection (issue 37)

private let leftArrow: UInt16 = 123
private let rightArrow: UInt16 = 124
private let downArrow: UInt16 = 125
private let upArrow: UInt16 = 126

/// Draws the Selection (20,20)–(120,120) and reports the rectangle a commit
/// would carry — the seam that states where the Selection actually is.
@MainActor
private func selectionAfter(
    _ view: RegionPickerView, _ window: NSWindow, _ act: () -> Void
) -> NSRect? {
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 20, y: 20), in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 120, y: 120), in: view, window: window))

    act()

    var committed: NSRect?
    view.onCommitRequested = { committed = $0 }
    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    return committed
}

@MainActor
@Test
func arrowKeysNudgeTheCommittedSelectionAndShiftMovesItFurther() async {
    let (view, window) = makeHostedView()
    let rect = selectionAfter(view, window) {
        view.keyDown(with: keyEvent("", keyCode: rightArrow, window: window))
        view.keyDown(with: keyEvent("", keyCode: rightArrow, window: window))
        view.keyDown(with: keyEvent("", keyCode: downArrow, window: window, modifiers: [.shift]))
    }
    #expect(rect?.origin == CGPoint(x: 22, y: 30),
            "Two fine steps right and one coarse step down")
    #expect(rect?.size == CGSize(width: 100, height: 100), "A nudge never resizes")
}

@MainActor
@Test
func nudgingRunsTheSelectionToTheDisplayEdgeAndStopsThere() async {
    let (view, window) = makeHostedView()
    // Ten coarse steps left is 100pt from an origin 20pt off the edge.
    let rect = selectionAfter(view, window) {
        for _ in 0..<10 {
            view.keyDown(with: keyEvent("", keyCode: leftArrow, window: window, modifiers: [.shift]))
            view.keyDown(with: keyEvent("", keyCode: upArrow, window: window, modifiers: [.shift]))
        }
    }
    #expect(rect?.origin == .zero, "Held arrows clamp at the display edge")
    #expect(rect?.size == CGSize(width: 100, height: 100), "and still never resize")
}

@MainActor
@Test
func arrowKeysLeaveTheSelectionAloneWhileAnAnnotationIsSelected() async {
    let (view, window) = makeHostedView()
    let rect = selectionAfter(view, window) {
        // Draw a rectangle inside the Selection; it stays selected, so the
        // arrows belong to it rather than to the crop.
        view.keyDown(with: keyEvent("r", keyCode: 15, window: window))
        view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 40, y: 40), in: view, window: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: CGPoint(x: 80, y: 80), in: view, window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 80, y: 80), in: view, window: window))
        view.keyDown(with: keyEvent("", keyCode: rightArrow, window: window))
    }
    #expect(rect?.origin == CGPoint(x: 20, y: 20), "The crop should not have moved")
}

// MARK: - Ticket 09: Resolution box

@MainActor
private func drawSelection(
    _ view: RegionPickerView, _ window: NSWindow,
    from: CGPoint = CGPoint(x: 100, y: 100), to: CGPoint = CGPoint(x: 200, y: 200)
) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: from, in: view, window: window))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, atViewPoint: to, in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: to, in: view, window: window))
}

@MainActor
private func resolutionBox(of view: RegionPickerView) -> ResolutionBoxView? {
    view.subviews.compactMap { $0 as? ResolutionBoxView }.first
}

@MainActor
@Test
func typedWidthCommitsACentreAnchoredResize() async {
    let (view, window) = makeHostedView(width: 900, height: 600)
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    drawSelection(view, window)

    let box = resolutionBox(of: view)
    #expect(box?.isHidden == false)
    #expect(box?.widthField.stringValue == "100", "The box shows the live size")

    box?.widthField.stringValue = "200"
    _ = box?.control(
        box!.widthField, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertNewline(_:))
    )

    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    #expect(baked?.width == 200, "Return in the field commits the typed width")
    #expect(baked?.height == 100, "The height stays; the resize is centre-anchored")
}

@MainActor
@Test
func escInAFieldRevertsIt() async {
    let (view, window) = makeHostedView(width: 900, height: 600)
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    drawSelection(view, window)

    let box = resolutionBox(of: view)
    box?.widthField.stringValue = "999"
    _ = box?.control(
        box!.widthField, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.cancelOperation(_:))
    )
    #expect(box?.widthField.stringValue == "100", "Esc reverts the field")

    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    #expect(baked?.width == 100, "The Selection is untouched by the revert")
}

@MainActor
@Test
func toolShortcutsStayInertWhileAFieldIsFocused() async {
    let (view, window) = makeHostedView(width: 900, height: 600)
    drawSelection(view, window)
    let box = resolutionBox(of: view)
    let toolbar = view.subviews.compactMap { $0 as? RegionToolbarView }.first
    let rectangleButton = toolbar?.subviews.compactMap { $0 as? ToolButton }
        .first { $0.tool == .rectangle }

    box?.controlTextDidBeginEditing(
        Notification(name: NSControl.textDidBeginEditingNotification, object: box!.widthField)
    )
    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))
    #expect(rectangleButton?.isActive == false,
            "Typing 'r' into a field must not switch tools")

    box?.controlTextDidEndEditing(
        Notification(name: NSControl.textDidEndEditingNotification, object: box!.widthField)
    )
    view.keyDown(with: keyEvent("r", keyCode: 15, window: window))
    #expect(rectangleButton?.isActive == true,
            "After editing ends the shortcut works again")
}

@MainActor
@Test
func unitToggleFiresPersistedPrefs() async {
    let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    var saved: SelectionPrefs?
    let view = RegionPickerView(
        frame: frame, image: makeSourceImage(), scale: 1.0,
        onSelectionPrefsChanged: { saved = $0 }
    )
    window.contentView = view
    window.makeFirstResponder(view)

    resolutionBox(of: view)?.onUnitToggled?()
    #expect(saved?.showSizesInPoints == true, "The px/pt choice persists via the config")
}

// MARK: - Ticket 11: armed exact size

@MainActor
@Test
func armedExactSizeGhostCapturesOnClickAndIsConsumed() async {
    let (view, window) = makeHostedView(width: 900, height: 600, overlay: true)
    var baked: CGImage?
    view.onCommit = { baked = $0 }

    // Arm 640×480 from the presets panel with no Selection.
    resolutionBox(of: view)?.onPresetsTapped?()
    let row = view.subviews.compactMap { $0 as? PresetsPanelView }.first?
        .subviews.compactMap { $0 as? PresetRowButton }
        .first { $0.title == "640×480" }
    #expect(row != nil, "The presets panel lists the exact sizes")
    row?.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: .zero, in: view, window: window))

    // The ghost frame follows the cursor; a click commits it in place.
    view.mouseMoved(with: mouseEvent(.mouseMoved, atViewPoint: CGPoint(x: 400, y: 300), in: view, window: window))
    view.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: CGPoint(x: 400, y: 300), in: view, window: window))
    view.mouseUp(with: mouseEvent(.leftMouseUp, atViewPoint: CGPoint(x: 400, y: 300), in: view, window: window))

    #expect(baked?.width == 640, "The click captures the armed frame at exactly its size")
    #expect(baked?.height == 480)

    // The armed size was consumed: a fresh drag is an ordinary rubber band.
    baked = nil
    drawSelection(view, window, from: CGPoint(x: 850, y: 30), to: CGPoint(x: 880, y: 55))
    #expect(baked?.width == 30, "The next capture gesture is not frozen at the armed size")
    #expect(baked?.height == 25)
}

// MARK: - Ticket 10: derived field under a lock

@MainActor
@Test
func lockDerivesTheOtherFieldOnCommit() async {
    let (view, window) = makeHostedView(width: 900, height: 600)
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    drawSelection(view, window)

    // Activate the 16:9 lock from the presets panel, then type only a width.
    resolutionBox(of: view)?.onPresetsTapped?()
    let row = view.subviews.compactMap { $0 as? PresetsPanelView }.first?
        .subviews.compactMap { $0 as? PresetRowButton }
        .first { $0.title == "16:9" }
    row?.mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: .zero, in: view, window: window))

    let box = resolutionBox(of: view)
    box?.widthField.stringValue = "320"
    _ = box?.control(
        box!.widthField, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertNewline(_:))
    )

    view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    #expect(baked?.width == 320, "The typed width applies")
    #expect(baked?.height == 180, "The height derives from the 16:9 lock")
}

@MainActor
@Test
func aPersistedLockNamesItselfOnThePresetsButton() async {
    let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    var prefs = SelectionPrefs()
    prefs.aspectLockRatio = 21.0 / 9
    let view = RegionPickerView(
        frame: frame, image: makeSourceImage(), scale: 1.0, selectionPrefs: prefs
    )
    window.contentView = view
    window.makeFirstResponder(view)

    let box = resolutionBox(of: view)
    #expect(box?.presetsTitle == "21:9 ▾",
            "A lock carried over from the config is named on the button")

    // The panel ticks the active row, and Freeform clears the lock.
    resolutionBox(of: view)?.onPresetsTapped?()
    let rows = view.subviews.compactMap { $0 as? PresetsPanelView }.first?
        .subviews.compactMap { $0 as? PresetRowButton }
    #expect(rows?.first { $0.title == "21:9" }?.isActive == true, "The armed lock is ticked")
    #expect(rows?.first { $0.title == "Freeform" }?.isActive == false)
    rows?.first { $0.title == "Freeform" }?
        .mouseDown(with: mouseEvent(.leftMouseDown, atViewPoint: .zero, in: view, window: window))
    #expect(box?.presetsTitle == "▾", "Freeform leaves no lock to announce")
}
