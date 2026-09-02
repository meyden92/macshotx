import AppKit
import Testing
@testable import MacshotCore

// Beautify through the overlay's commit callback: the seam that proves preview
// and bake agree, since both go through the compositor.

@MainActor
private func makeHostedView(fill: NSColor = .white) -> (RegionPickerView, NSWindow) {
    let ctx = CGContext(
        data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(fill.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(frame: frame, image: ctx.makeImage()!, scale: 1.0)
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
}

@MainActor
private func key(
    _ char: String, _ keyCode: UInt16, _ window: NSWindow,
    flags: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
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

/// Confirms the capture and returns the image the commit callback receives.
@MainActor
private func selectAndConfirm(_ view: RegionPickerView, _ window: NSWindow) -> CGImage? {
    var committed: CGImage?
    view.onCommit = { committed = $0 }
    view.keyDown(with: key("\r", 36, window))
    return committed
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    let offset = y * image.bytesPerRow + x * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
}

@MainActor
private func beautified() -> (RegionPickerView, NSWindow) {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
    view.keyDown(with: key("b", 11, window, flags: .option))
    return (view, window)
}

@MainActor
@Test
func beautifyOnConfirmsAnImageLargerThanTheSelectionWithBackdropAtItsCorners() throws {
    let (view, window) = beautified()
    #expect(view.isBeautifying)

    let composed = try #require(selectAndConfirm(view, window))
    #expect(composed.width > 200 && composed.height > 200,
            "The backdrop makes the exported image bigger than the Selection")
    let corner = pixel(composed, 2, 2)
    #expect(!(corner.r > 240 && corner.g > 240 && corner.b > 240),
            "A corner should be backdrop, not the white capture")
    let middle = pixel(composed, composed.width / 2, composed.height / 2)
    #expect(middle.r > 240 && middle.g > 240 && middle.b > 240, "and the middle is the capture")
}

@MainActor
@Test
func togglingBeautifyOffRestoresThePlainSelectionSizedImage() throws {
    let (view, window) = beautified()
    view.keyDown(with: key("b", 11, window, flags: .option))
    #expect(!view.isBeautifying)

    let plain = try #require(selectAndConfirm(view, window))
    #expect(plain.width == 200 && plain.height == 200, "Exactly the Selection, as before")
    #expect(pixel(plain, 100, 100).r > 240)
}

@MainActor
@Test
func choosingAStyleAndPaddingChangesWhatIsExported() throws {
    let (view, window) = beautified()
    let panel = try #require(view.subviews.compactMap { $0 as? PostProcessingPanelView }.first)

    panel.onStyleSelected?("slate")
    panel.onPaddingChanged?(0.25)
    let wide = try #require(selectAndConfirm(view, window))
    #expect(wide.width == 300, "25% of the 200pt long side, on both sides")
    let corner = pixel(wide, 3, 3)
    #expect(corner.r < 80 && corner.g < 80 && corner.b < 80, "Slate, not the previous style")

    // Below the default shadow's own reach, so the margin stops shrinking with
    // the padding — the shadow can never be clipped.
    panel.onPaddingChanged?(0.05)
    let tight = try #require(selectAndConfirm(view, window))
    #expect(tight.width < wide.width)
}

@MainActor
@Test
func theCaptureIsReadOnlyWhileTheBeautifyPreviewIsUp() {
    let (view, window) = beautified()
    // A tool shortcut and a drag that would otherwise draw a rectangle.
    view.keyDown(with: key("r", 15, window))
    drag(in: view, window: window, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180))
    #expect(view.annotations.isEmpty, "Nothing should be drawable over the preview")

    view.keyDown(with: key("b", 11, window, flags: .option))
    view.keyDown(with: key("r", 15, window))
    drag(in: view, window: window, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180))
    #expect(view.annotations.count == 1, "and editing comes straight back when it is off")
}

@MainActor
@Test
func annotationsAreInsideTheCaptureNotOnTheBackdrop() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("f", 3, window))
    drag(in: view, window: window, from: CGPoint(x: 110, y: 110), to: CGPoint(x: 190, y: 190))
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
    view.keyDown(with: key("b", 11, window, flags: .option))

    let composed = try #require(selectAndConfirm(view, window))
    // The black redaction is 10pt inside the Selection, so with padding it
    // lands inside the capture area and nowhere near the canvas edge.
    let margin = (composed.width - 200) / 2
    #expect(pixel(composed, margin + 50, margin + 50).r < 40, "The redaction rode along")
    #expect(pixel(composed, 3, 3).r > 40 || pixel(composed, 3, 3).b > 40,
            "and the backdrop corner is not annotation ink")
}

@MainActor
@Test
func theRadiusAndShadowControlsReachTheExportedImage() throws {
    let (view, window) = beautified()
    let panel = try #require(view.subviews.compactMap { $0 as? PostProcessingPanelView }.first)
    panel.onStyleSelected?("slate")
    panel.onShadowSelected?(.none)
    panel.onPaddingChanged?(0.1)

    panel.onCornerRadiusChanged?(0)
    let square = try #require(selectAndConfirm(view, window))
    #expect(pixel(square, 21, 21).r > 240, "A square capture reaches its own corner")

    panel.onCornerRadiusChanged?(40)
    let rounded = try #require(selectAndConfirm(view, window))
    #expect(rounded.width == square.width, "The radius does not change the canvas")
    #expect(pixel(rounded, 21, 21).r < 80, "and the backdrop shows through the rounded corner")

    panel.onShadowSelected?(.strong)
    let shadowed = try #require(selectAndConfirm(view, window))
    #expect(shadowed.width > rounded.width,
            "A shadow bigger than the padding grows the canvas rather than being clipped")
}

@MainActor
@Test
func theWindowFrameToggleAddsATitleBarToTheExportedImage() throws {
    let (view, window) = beautified()
    let panel = try #require(view.subviews.compactMap { $0 as? PostProcessingPanelView }.first)
    panel.onShadowSelected?(.none)
    panel.onPaddingChanged?(0.1)

    let plain = try #require(selectAndConfirm(view, window))
    panel.onWindowFrameToggled?(true)
    let framed = try #require(selectAndConfirm(view, window))

    #expect(framed.height == plain.height + 28, "The title bar grows the canvas")
    #expect(framed.width == plain.width, "and only in height")
    let bar = pixel(framed, framed.width / 2, 20 + 14)
    #expect(bar.r > 190 && bar.g > 190 && bar.b > 190 && bar.r < 250,
            "with a title bar strip above the capture, got \(bar)")
}

// MARK: - No Selection yet (ADR 0013)

@MainActor
@Test
func thePanelOpensWithNoSelectionAndEnterCapturesTheWholeDisplayBeautified() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("b", 11, window, flags: .option))
    #expect(view.isBeautifying)
    #expect(view.subviews.contains { $0 is PostProcessingPanelView }, "The panel is up with no Selection")

    let composed = try #require(selectAndConfirm(view, window))
    #expect(composed.width > 400 && composed.height > 400,
            "The whole 400pt display, padded, at full resolution")
}

@MainActor
@Test
func aClickCaptureCarriesTheConfiguredLookAndEffectsIntoTheShot() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("b", 11, window, flags: .option))
    let panel = try #require(view.subviews.compactMap { $0 as? PostProcessingPanelView }.first)
    panel.onStyleSelected?("slate")
    panel.onPaddingChanged?(0.1)
    panel.onShadowSelected?(.none)
    panel.onCornerRadiusChanged?(0)
    view.keyDown(with: key("e", 14, window, flags: .option))
    var values = EffectValues.neutral
    values.brightness = -0.3
    try #require(effectsPanel(of: view)).onValuesChanged?(values)

    var committed: CGImage?
    view.onCommit = { committed = $0 }
    // A click on the preview, never having previewed the real crop.
    drag(in: view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200, y: 200))

    let composed = try #require(committed)
    #expect(composed.width == 480 && composed.height == 480,
            "The whole display with 10% padding on every side, composited at full resolution")
    let corner = pixel(composed, 3, 3)
    #expect(corner.r < 80 && corner.g < 80 && corner.b < 80, "Slate at the corner")
    #expect(pixel(composed, 240, 240).r < 240, "and the darkened (no longer white) capture in the middle")
}

@MainActor
@Test
func aClickOnAWindowThroughTheScaledPreviewCapturesThatWindow() throws {
    let (view, window) = makeHostedView()
    let target = WindowCandidate(
        id: 7, frame: CGRect(x: 100, y: 100, width: 200, height: 200),
        bundleIdentifier: "com.example.app", layer: 0, isOnScreen: true
    )
    var asked: [CGPoint] = []
    view.onSnapHover = { point in
        asked.append(point)
        return (target, NSRect(x: 100, y: 100, width: 200, height: 200))
    }
    view.setSnapArmed(true)
    view.keyDown(with: key("b", 11, window, flags: .option))
    let panel = try #require(view.subviews.compactMap { $0 as? PostProcessingPanelView }.first)
    panel.onPaddingChanged?(0.1)
    panel.onShadowSelected?(.none)

    var committed: CGImage?
    view.onCommit = { committed = $0 }
    // The preview shrinks the 480pt canvas to 352pt; the display's centre is
    // still the centre of the capture in it, well inside the window.
    drag(in: view, window: window, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200, y: 200))

    let composed = try #require(committed)
    #expect(composed.width == 240 && composed.height == 240, "The 200pt window, padded")
    let mapped = try #require(asked.last)
    #expect(abs(mapped.x - 200) < 1 && abs(mapped.y - 200) < 1,
            "Snap was asked about the point's place in the capture, not on the backdrop")
}

// MARK: - Image effects

@MainActor
private func effectsPanel(of view: RegionPickerView) -> EffectsPanelView? {
    view.subviews.compactMap { $0 as? EffectsPanelView }.first
}

@MainActor
@Test
func confirmingWithEffectsAppliedYieldsASelectionSizedImageThatMoved() throws {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))

    let plain = try #require(selectAndConfirm(view, window))
    view.keyDown(with: key("e", 14, window, flags: .option))
    let panel = try #require(effectsPanel(of: view))

    var values = EffectValues.neutral
    values.brightness = -0.3
    panel.onValuesChanged?(values)

    let darkened = try #require(selectAndConfirm(view, window))
    #expect(darkened.width == 200 && darkened.height == 200, "Effects do not resize the capture")
    #expect(pixel(darkened, 100, 100).r < pixel(plain, 100, 100).r - 30,
            "and the sampled pixel moved")
}

@MainActor
@Test
func effectsChangeTheCaptureAndLeaveTheBackdropAndTheAnnotationsAlone() throws {
    let (view, window) = makeHostedView()
    // A red arrow, so an effect that greys the capture must not grey it.
    view.keyDown(with: key("f", 3, window))
    drag(in: view, window: window, from: CGPoint(x: 140, y: 140), to: CGPoint(x: 160, y: 160))
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
    view.keyDown(with: key("b", 11, window, flags: .option))
    let beautifyPanel = try #require(
        view.subviews.compactMap { $0 as? PostProcessingPanelView }.first
    )
    beautifyPanel.onStyleSelected?("slate")
    beautifyPanel.onShadowSelected?(.none)
    beautifyPanel.onPaddingChanged?(0.1)
    beautifyPanel.onCornerRadiusChanged?(0)

    let plain = try #require(selectAndConfirm(view, window))
    view.keyDown(with: key("e", 14, window, flags: .option))
    var values = EffectValues.neutral
    values.brightness = -0.4
    try #require(effectsPanel(of: view)).onValuesChanged?(values)
    let darkened = try #require(selectAndConfirm(view, window))

    #expect(darkened.width == plain.width && darkened.height == plain.height)
    #expect(pixel(darkened, 3, 3) == pixel(plain, 3, 3), "The backdrop is not the capture")
    #expect(pixel(darkened, 40, 40).r < pixel(plain, 40, 40).r - 30, "but the capture moved")
    // The redaction is drawn after the effects, so it is still exactly black.
    #expect(pixel(darkened, 60, 60) == pixel(plain, 60, 60),
            "and the annotation keeps the colour the user picked")
}

@MainActor
@Test
func aPresetMovesTheSlidersAndResetPutsTheCaptureBack() throws {
    // Mid-grey rather than white: a preset that brightens has nowhere to move a
    // pixel that is already at 255.
    let (view, window) = makeHostedView(fill: NSColor(white: 0.5, alpha: 1))
    view.keyDown(with: key("s", 1, window))
    drag(in: view, window: window, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
    let plain = try #require(selectAndConfirm(view, window))

    view.keyDown(with: key("e", 14, window, flags: .option))
    let panel = try #require(effectsPanel(of: view))
    // Presets and reset are the same mechanism: they write the four values.
    panel.onValuesChanged?(EffectPreset.all[0].values)
    let punchy = try #require(selectAndConfirm(view, window))
    #expect(pixel(punchy, 100, 100) != pixel(plain, 100, 100))

    panel.onValuesChanged?(.neutral)
    let reset = try #require(selectAndConfirm(view, window))
    #expect(pixel(reset, 100, 100) == pixel(plain, 100, 100),
            "Reset returns the untouched capture")
}

// MARK: - Remembering the look

@MainActor
@Test
func theLookIsRememberedButTheToggleAndTheEffectsAreNot() throws {
    var saved: BeautifyDefaults?
    let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: nil, scale: 1.0,
        onBeautifyDefaultsChanged: { saved = $0 }
    )
    window.contentView = view
    window.makeFirstResponder(view)

    view.keyDown(with: key("b", 11, window, flags: .option))
    let panel = try #require(view.subviews.compactMap { $0 as? PostProcessingPanelView }.first)
    panel.onStyleSelected?("meadow")
    panel.onPaddingChanged?(0.2)
    panel.onCornerRadiusChanged?(30)
    panel.onShadowSelected?(.soft)
    panel.onWindowFrameToggled?(true)

    let remembered = try #require(saved)
    #expect(remembered.styleID == "meadow" && remembered.paddingFraction == 0.2)
    #expect(remembered.cornerRadius == 30 && remembered.shadow == ShadowIntensity.soft.rawValue)
    #expect(remembered.windowFrame)

    // A fresh capture starts plain, with the look restored underneath.
    let next = RegionPickerView(frame: frame, image: nil, scale: 1.0, beautifyDefaults: remembered)
    #expect(!next.isBeautifying, "Every capture starts with beautify off")
    window.contentView = next
    next.keyDown(with: key("b", 11, window, flags: .option))
    let nextPanel = try #require(
        next.subviews.compactMap { $0 as? PostProcessingPanelView }.first
    )
    #expect(nextPanel.radiusSlider.value == 30, "and the last look comes back with it")
}

@Test
func aBeautifyStyleThatNoLongerExistsFallsBackInsteadOfFailing() throws {
    let json = Data("""
    {"styleID":"a-style-from-a-later-build","paddingFraction":0.11}
    """.utf8)
    let decoded = try JSONDecoder().decode(BeautifyDefaults.self, from: json)
    #expect(decoded.paddingFraction == 0.11)
    #expect(decoded.cornerRadius == BeautifyDefaults().cornerRadius, "Missing keys default")

    let settings = BeautifySettings(remembering: decoded)
    #expect(settings.styleID == Backdrops.defaultID)
    #expect(!settings.enabled, "and the toggle is never restored")
}
