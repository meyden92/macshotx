import AppKit
import Testing
@testable import MacshotCore

// The colour picker: the hex codec that persists a chosen opacity, the panel's
// own picking maths, the palette's round-trip through the config, and — at the
// overlay seam — a translucent colour actually blending into the baked image.

private func rgba(_ color: NSColor?) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    guard let c = color?.usingColorSpace(.deviceRGB) else { return (-1, -1, -1, -1) }
    return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
}

private func expectColor(_ actual: NSColor?, matches expected: NSColor) {
    let a = rgba(actual), e = rgba(expected)
    #expect(abs(a.0 - e.0) < 0.02 && abs(a.1 - e.1) < 0.02 && abs(a.2 - e.2) < 0.02
            && abs(a.3 - e.3) < 0.02,
            "Expected \(e), got \(a)")
}

// MARK: - Hex with alpha

@Test
func sixDigitHexStillDecodesFullyOpaque() {
    let color = NSColor(hexString: "#3A7BD5")
    expectColor(color, matches: NSColor(srgbRed: 0x3A / 255, green: 0x7B / 255, blue: 0xD5 / 255, alpha: 1))
    #expect(!NSColor.hexStringCarriesAlpha("#3A7BD5"))
    #expect(!NSColor.hexStringCarriesAlpha("3A7BD5"))
}

@Test
func eightDigitHexCarriesTheAlphaAndRoundTrips() {
    let translucent = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.35)
    let hex = translucent.hexRGBAString
    #expect(hex == "#FFCC0059", "Expected #FFCC0059, got \(hex)")
    #expect(NSColor.hexStringCarriesAlpha(hex))
    expectColor(NSColor(hexString: hex), matches: translucent)
}

@Test
func theRGBFormIsUnchangedSoTheColorSamplerKeepsItsOutput() {
    let translucent = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.35)
    #expect(translucent.hexRGBString == "#FFCC00")
    #expect(NSColor(hexString: "#12345") == nil)
    #expect(NSColor(hexString: "#1234567") == nil)
    #expect(NSColor(hexString: "nope") == nil)
}

// MARK: - Config round-trip

@Test
func theCustomPalettePersistsThroughTheConfig() throws {
    var styles = EditorStyles()
    styles.customPaletteHex = ["#FF000080", "#00FF00FF"]
    styles.highlighterColorHex = NSColor.systemYellow.withAlphaComponent(0.5).hexRGBAString

    let data = try JSONEncoder().encode(styles)
    let decoded = try JSONDecoder().decode(EditorStyles.self, from: data)

    #expect(decoded.customPaletteHex == styles.customPaletteHex)
    expectColor(
        NSColor(hexString: decoded.highlighterColorHex),
        matches: NSColor.systemYellow.withAlphaComponent(0.5)
    )
}

@Test
func aConfigWrittenBeforeOpacityStillDecodes() throws {
    // No customPaletteHex key at all, and six-digit colours.
    let json = Data("""
    {"strokeColorHex":"#FF3B30","highlighterColorHex":"#FFCC00"}
    """.utf8)
    let decoded = try JSONDecoder().decode(EditorStyles.self, from: json)

    #expect(decoded.customPaletteHex.isEmpty)
    #expect(!NSColor.hexStringCarriesAlpha(decoded.highlighterColorHex))
    expectColor(NSColor(hexString: decoded.strokeColorHex), matches: NSColor(hexString: "#FF3B30")!)
}

// MARK: - The panel

@MainActor
@Test
func thePanelOpensOnTheColorItIsGiven() {
    let start = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 0.4)
    let panel = ColorPickerPanelView(color: start, palette: [])
    expectColor(panel.color, matches: start)
}

@MainActor
@Test
func pickingAStandardSwatchReportsThatWholeColor() {
    let panel = ColorPickerPanelView(color: .systemRed, palette: [])
    var reported: NSColor?
    panel.onColorChanged = { reported = $0 }

    panel.standardSwatches.first { $0.color.matchesColor(.systemGreen) }?
        .onClick?(.systemGreen)

    expectColor(reported, matches: .systemGreen)
    expectColor(panel.color, matches: .systemGreen)
}

@MainActor
@Test
func theOpacityStripDrivesTheAlphaAndBracketsItsDrag() {
    let panel = ColorPickerPanelView(color: .systemRed, palette: [])
    var reported: [NSColor] = []
    var gestures = 0
    panel.onColorChanged = { reported.append($0) }
    panel.onGestureBegan = { gestures += 1 }
    panel.onGestureEnded = { gestures -= 1 }

    let strip = panel.subviews.compactMap { $0 as? AlphaStrip }.first
    #expect(strip != nil, "The picker should offer an opacity strip")
    strip?.frame = NSRect(x: 0, y: 0, width: 100, height: 12)
    strip?.onGestureBegan?()
    strip?.report(at: CGPoint(x: 50, y: 6))
    strip?.onGestureEnded?()

    #expect(gestures == 0, "A drag should open and close exactly one gesture")
    #expect(abs(rgba(reported.last).3 - 0.5) < 0.03,
            "Half way along the strip should be half opacity")
}

@MainActor
@Test
func theSurfaceAndHueStripReachAnyColor() {
    let panel = ColorPickerPanelView(color: .white, palette: [])
    var reported: NSColor?
    panel.onColorChanged = { reported = $0 }

    let hue = panel.subviews.compactMap { $0 as? HueStrip }.first
    let surface = panel.subviews.compactMap { $0 as? SaturationBrightnessSurface }.first
    #expect(hue != nil && surface != nil)

    hue?.frame = NSRect(x: 0, y: 0, width: 120, height: 12)
    surface?.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
    // A third of the way round the hue wheel is green; full saturation, full
    // brightness is the top-right of the surface.
    hue?.report(at: CGPoint(x: 40, y: 6))
    surface?.report(at: CGPoint(x: 100, y: 0))

    let picked = rgba(reported)
    #expect(picked.1 > 0.9 && picked.0 < 0.1 && picked.2 < 0.1,
            "Expected a saturated green, got \(picked)")
}

@MainActor
@Test
func aColorCanBeSavedToThePaletteAndClearedAgain() {
    let panel = ColorPickerPanelView(color: .systemTeal, palette: [])
    var saved: [NSColor] = []
    panel.onPaletteChanged = { saved = $0 }

    let addButton = panel.subviews.compactMap { $0 as? PaletteAddButton }.first
    #expect(addButton != nil, "The picker should offer a save-to-palette control")
    addButton?.onClick?()

    #expect(saved.count == 1)
    expectColor(saved.first, matches: .systemTeal)
    #expect(panel.paletteSwatches.count == 1, "The saved colour should appear as a slot")

    panel.paletteSwatches.first?.onSecondaryClick?(panel.paletteSwatches[0].color)
    #expect(saved.isEmpty, "A secondary click should clear the slot")
    #expect(panel.paletteSwatches.isEmpty)
}

@MainActor
@Test
func thePaletteIsCappedAndNeverStoresTheSameColorTwice() {
    let panel = ColorPickerPanelView(color: .systemRed, palette: [])
    var saved: [NSColor] = []
    panel.onPaletteChanged = { saved = $0 }
    let addButton = panel.subviews.compactMap { $0 as? PaletteAddButton }.first

    addButton?.onClick?()
    addButton?.onClick?()
    #expect(saved.count == 1, "Saving the same colour twice should not duplicate it")

    for standard in ColorPickerPanelView.standardColors {
        panel.standardSwatches.first { $0.color.matchesColor(standard) }?.onClick?(standard)
        addButton?.onClick?()
    }
    #expect(saved.count == ColorPickerPanelView.paletteSlotCount,
            "The palette should stop at its slot count")
}

// MARK: - Through the overlay

@MainActor
private func makeHostedView() -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 4 * 200,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.gray.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(frame: frame, image: ctx.makeImage()!, scale: 1.0)
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
private func drag(
    in view: RegionPickerView, window: NSWindow, from: CGPoint, to: CGPoint
) {
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, from),
        (.leftMouseDragged, to),
        (.leftMouseUp, to)
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

@MainActor
private func openPicker(in view: RegionPickerView) -> ColorPickerPanelView? {
    let row = view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
    row?.onColorWellClicked?()
    return view.subviews.compactMap { $0 as? ColorPickerPanelView }.first
}

@MainActor
@Test
func aTranslucentColorBlendsWithTheScreenshotInTheBakedImage() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("f", 3, window))

    // Black at half opacity, picked the way a user would.
    let panel = openPicker(in: view)
    #expect(panel != nil, "The colour well should open the picker")
    panel?.standardSwatches.first { $0.color.matchesColor(.black) }?.onClick?(.black)
    let strip = panel?.subviews.compactMap { $0 as? AlphaStrip }.first
    strip?.onGestureBegan?()
    strip?.report(at: CGPoint(x: (strip?.bounds.width ?? 0) / 2, y: 6))
    strip?.onGestureEnded?()

    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 80, y: 80))

    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 150))
    view.keyDown(with: key("\r", 36, window))

    guard let baked else {
        Issue.record("No baked image produced")
        return
    }
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    let value = bytes[(60 - 10) * baked.bytesPerRow + (60 - 10) * 4]
    #expect(value > 40 && value < 90,
            "Half-opaque black over gray should land between the two, got \(value)")
}

@MainActor
@Test
func thePickerOpensOnTheSelectedAnnotationsColor() {
    let (view, window) = makeHostedView()

    // A green rectangle, then select it and open the picker.
    view.keyDown(with: key("r", 15, window))
    var panel = openPicker(in: view)
    panel?.standardSwatches.first { $0.color.matchesColor(.systemGreen) }?
        .onClick?(.systemGreen)
    drag(in: view, window: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 80, y: 80))

    // Back to red for the tool, so the tool default and the annotation differ.
    // Re-picking the tool drops the selection the drag left behind, so the red
    // moves the default instead of restyling the rectangle.
    view.keyDown(with: key("r", 15, window))
    panel = openPicker(in: view)
    panel?.standardSwatches.first { $0.color.matchesColor(.systemRed) }?.onClick?(.systemRed)

    drag(in: view, window: window, from: CGPoint(x: 60, y: 40), to: CGPoint(x: 60, y: 40))
    panel = openPicker(in: view)
    expectColor(panel?.color, matches: .systemGreen)
}

@MainActor
@Test
func thePanelRendersWithoutBlowingUp() {
    // The picker's surfaces are all custom drawing; nothing else in the suite
    // ever runs it. This forces one full draw pass.
    let panel = ColorPickerPanelView(
        color: NSColor.systemBlue.withAlphaComponent(0.4),
        palette: [.systemRed, .systemGreen]
    )
    #expect(panel.frame.width > 0 && panel.frame.height > 0)
    guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else {
        Issue.record("No bitmap rep for the panel")
        return
    }
    panel.cacheDisplay(in: panel.bounds, to: rep)
    #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
}
