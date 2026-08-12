import AppKit
import Testing
@testable import MacshotCore

// Typography: the attributes the one measurement path builds, the persisted
// defaults, and — at the overlay seam — the background plate and glyph outline
// in the baked image at scale 1 and scale 2.

private let plain = TextStyle(color: .systemRed, fontSize: 22)

// MARK: - Attributes

@Test
func traitsCombineRatherThanReplacingEachOther() {
    var style = plain
    style.bold = true
    style.italic = true
    style.underline = true
    style.strikethrough = true

    let attributes = TextLayout.attributes(for: style)
    let font = attributes[.font] as? NSFont
    let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
    #expect(traits.contains(.boldFontMask), "Bold should survive alongside italic")
    #expect(traits.contains(.italicFontMask))
    #expect(attributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
    #expect(attributes[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
}

@Test
func turningBoldOffGivesAnUnboldFont() {
    var style = plain
    style.bold = false
    let font = TextLayout.attributes(for: style)[.font] as? NSFont
    let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
    #expect(!traits.contains(.boldFontMask))
}

@Test
func aChosenFamilyIsUsedAndAnUnknownOneFallsBackWithoutCrashing() {
    var style = plain
    style.fontFamily = "Helvetica"
    let chosen = TextLayout.attributes(for: style)[.font] as? NSFont
    #expect(chosen?.familyName == "Helvetica")

    style.fontFamily = "No Such Family At All"
    let fallback = TextLayout.attributes(for: style)[.font] as? NSFont
    #expect(fallback != nil, "An unknown family should still produce a font")
    #expect(fallback?.pointSize == style.fontSize)
}

@Test
func alignmentReachesTheParagraphStyle() {
    for alignment in TextAlignment.allCases {
        var style = plain
        style.alignment = alignment
        let paragraph = TextLayout.attributes(for: style)[.paragraphStyle] as? NSParagraphStyle
        #expect(paragraph?.alignment == alignment.nsAlignment)
        #expect(paragraph?.lineBreakMode == .byWordWrapping,
                "Alignment must not cost the wrapping the box depends on")
    }
}

@Test
func theOutlinePassStrokesWithoutFillingSoTheFillEdgeStaysCrisp() {
    var style = plain
    #expect(TextLayout.outlineAttributes(for: style) == nil, "Off by default")

    style.outlineColor = .black
    style.outlineWidth = 3
    guard let outline = TextLayout.outlineAttributes(for: style) else {
        Issue.record("Expected outline attributes")
        return
    }
    #expect(outline[.strokeColor] as? NSColor == NSColor.black)
    let width = outline[.strokeWidth] as? CGFloat ?? 0
    #expect(width > 0, "A positive stroke width strokes without filling")
    #expect((outline[.foregroundColor] as? NSColor) == NSColor.clear)

    style.outlineWidth = 0
    #expect(TextLayout.outlineAttributes(for: style) == nil, "A zero width is no outline")
}

@Test
func textStyleAxesSurviveTheClipboardRoundTrip() {
    var style = plain
    style.fontFamily = "Helvetica"
    style.bold = false
    style.italic = true
    style.underline = true
    style.strikethrough = true
    style.alignment = .center
    style.backgroundColor = NSColor.white.withAlphaComponent(0.5)
    style.outlineColor = .black
    style.outlineWidth = 4

    let annotation = Annotation.text(
        box: CGRect(x: 1, y: 2, width: 100, height: 30), content: "Hi", style
    )
    guard let data = AnnotationClipboard.encode([annotation]),
          let copy = AnnotationClipboard.decode(data)?.first,
          case let .text(_, _, decoded) = copy
    else {
        Issue.record("Payload did not round-trip")
        return
    }
    #expect(decoded.fontFamily == "Helvetica")
    #expect(decoded.bold == false && decoded.italic && decoded.underline && decoded.strikethrough)
    #expect(decoded.alignment == .center)
    #expect(decoded.backgroundColor != nil && decoded.outlineColor != nil)
    #expect(decoded.outlineWidth == 4)
}

// MARK: - Persisted defaults

@Test
func aConfigFromBeforeRichTextDecodesToTodaysLook() throws {
    let json = Data("""
    {"textColorHex":"#FF3B30","textFontSize":22}
    """.utf8)
    let decoded = try JSONDecoder().decode(EditorStyles.self, from: json)
    let style = TextStyle(color: .systemRed, fontSize: 22)
        .withRichDefaults(decoded.textRichDefaults)

    #expect(style.bold, "Text has always been bold")
    #expect(!style.italic && !style.underline && !style.strikethrough)
    #expect(style.alignment == .left)
    #expect(style.backgroundColor == nil && style.outlineColor == nil)
    #expect(style.fontFamily.isEmpty, "Empty means the system font")
}

@Test
func richTextDefaultsRoundTripThroughTheConfig() throws {
    var style = TextStyle(color: .systemRed, fontSize: 22)
    style.fontFamily = "Menlo"
    style.italic = true
    style.alignment = .right
    style.backgroundColor = NSColor.black.withAlphaComponent(0.6)

    var styles = EditorStyles()
    styles.textRichDefaults = style.richDefaults
    let data = try JSONEncoder().encode(styles)
    let decoded = try JSONDecoder().decode(EditorStyles.self, from: data)
    let restored = TextStyle(color: .systemRed, fontSize: 22)
        .withRichDefaults(decoded.textRichDefaults)

    #expect(restored.fontFamily == "Menlo")
    #expect(restored.italic && restored.alignment == .right)
    #expect(restored.backgroundColor != nil)
}

// MARK: - Through the overlay

@MainActor
private func makeHostedView(scale: CGFloat = 1) -> (RegionPickerView, NSWindow) {
    let pixels = Int(300 * scale)
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 4 * pixels,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(
        frame: frame, image: ctx.makeImage()!, scale: scale, requiresSelection: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    window.makeKeyAndOrderFront(nil)
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
private func click(in view: RegionPickerView, window: NSWindow, at point: CGPoint) {
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(
            with: kind, location: NSPoint(x: point.x, y: view.bounds.height - point.y),
            modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1.0
        )!
        if kind == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
    }
}

@MainActor
private func optionsRow(of view: RegionPickerView) -> ToolOptionsRowView? {
    view.subviews.compactMap { $0 as? RegionToolbarView }.first?
        .subviews.compactMap { $0 as? ToolOptionsRowView }.first
}

@MainActor
private func editor(in view: RegionPickerView) -> InlineTextView? {
    view.subviews.compactMap { $0 as? InlineTextView }.first
}

@MainActor
private func bake(_ view: RegionPickerView, _ window: NSWindow) -> CGImage? {
    var baked: CGImage?
    view.onCommit = { baked = $0 }
    view.keyDown(with: key("\r", 36, window))
    return baked
}

/// (r, g, b) of the baked pixel a view point maps to.
private func pixel(_ baked: CGImage, _ point: CGPoint, scale: CGFloat) -> (UInt8, UInt8, UInt8) {
    let bytes = CFDataGetBytePtr(baked.dataProvider!.data!)!
    let x = Int(point.x * scale), y = Int(point.y * scale)
    let offset = y * baked.bytesPerRow + x * 4
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
}

/// Types `content` with the text tool at (40,40) after `setup` has picked the
/// styling, then bakes.
@MainActor
private func bakedText(
    scale: CGFloat = 1,
    content: String = "IIIIIIII",
    _ setup: (ToolOptionsRowView?) -> Void
) -> CGImage? {
    let (view, window) = makeHostedView(scale: scale)
    view.keyDown(with: key("t", 17, window))
    setup(optionsRow(of: view))
    click(in: view, window: window, at: CGPoint(x: 40, y: 40))
    editor(in: view)?.string = content
    return bake(view, window)
}

@MainActor
@Test(arguments: [CGFloat(1), CGFloat(2)])
func aBackgroundPlateLeavesItsColorBehindTheGlyphs(scale: CGFloat) {
    let beside = CGPoint(x: 180, y: 50)

    guard let bare = bakedText(scale: scale, { _ in }) else {
        Issue.record("No baked image")
        return
    }
    let paper = pixel(bare, beside, scale: scale)
    #expect(paper == (255, 255, 255), "Without a plate that spot is bare paper")

    // Turn the plate on and pick blue for it out of the picker.
    let (view, window) = makeHostedView(scale: scale)
    view.keyDown(with: key("t", 17, window))
    optionsRow(of: view)?.onTextBackgroundToggled?(true)
    optionsRow(of: view)?.onTextBackgroundWellClicked?()
    let picker = view.subviews.compactMap { $0 as? ColorPickerPanelView }.first
    #expect(picker != nil, "The background well should open the colour picker")
    picker?.standardSwatches.first { $0.color.matchesColor(.systemBlue) }?.onClick?(.systemBlue)
    click(in: view, window: window, at: CGPoint(x: 40, y: 40))
    editor(in: view)?.string = "IIIIIIII"

    guard let plated = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    let plate = pixel(plated, beside, scale: scale)
    #expect(plate.2 > plate.0 + 40,
            "The plate should leave its own blue behind the text at scale \(scale), got \(plate)")
}

@MainActor
@Test(arguments: [CGFloat(1), CGFloat(2)])
func anOutlineLeavesOutlineColoredPixelsAroundTheGlyphs(scale: CGFloat) {
    guard let plainBake = bakedText(scale: scale, { _ in }),
          let outlined = bakedText(scale: scale, { row in row?.onTextOutlineToggled?(true) })
    else {
        Issue.record("No baked image")
        return
    }
    // Count dark pixels across the band the glyphs occupy: a black outline
    // around red glyphs adds ink that plain red text does not have.
    func darkCount(_ image: CGImage) -> Int {
        var count = 0
        for y in stride(from: 42, through: 66, by: 1) {
            for x in stride(from: 40, through: 120, by: 1) {
                let p = pixel(image, CGPoint(x: CGFloat(x), y: CGFloat(y)), scale: scale)
                if p.0 < 100 && p.1 < 100 && p.2 < 100 { count += 1 }
            }
        }
        return count
    }
    #expect(darkCount(plainBake) == 0, "Red text on white has no near-black pixels")
    #expect(darkCount(outlined) > 20,
            "An outline should leave its own colour around the glyphs at scale \(scale)")
}

@MainActor
@Test
func alignmentMovesWrappedTextInsideTheBox() {
    func inkColumns(_ image: CGImage) -> (first: Int, last: Int) {
        var first = 999, last = -1
        let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
        for x in 0..<300 {
            for y in 40..<80 where bytes[y * image.bytesPerRow + x * 4 + 2] < 200 {
                first = min(first, x); last = max(last, x)
                break
            }
        }
        return (first, last)
    }

    guard let left = bakedText(content: "II", { _ in }),
          let right = bakedText(content: "II", { row in row?.onAlignmentSelected?(.right) })
    else {
        Issue.record("No baked image")
        return
    }
    #expect(inkColumns(right).first > inkColumns(left).first,
            "Right-aligned text should sit further along the box")
}

@MainActor
@Test
func theInlineEditorReflectsTheCurrentStylingWhileTyping() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))
    optionsRow(of: view)?.onTraitToggled?(.italic, true)
    optionsRow(of: view)?.onAlignmentSelected?(.center)
    optionsRow(of: view)?.onFontFamilySelected?("Helvetica")

    click(in: view, window: window, at: CGPoint(x: 40, y: 40))

    guard let editor = editor(in: view) else {
        Issue.record("No editor")
        return
    }
    #expect(editor.font?.familyName == "Helvetica")
    #expect(NSFontManager.shared.traits(of: editor.font!).contains(.italicFontMask))
    #expect(editor.alignment == .center)
}

@MainActor
@Test
func calloutsExposeTheSameControlsAsText() {
    #expect(Tool.callout.options == Tool.text.options)

    let (view, window) = makeHostedView()
    view.keyDown(with: key("c", 8, window))
    optionsRow(of: view)?.onTraitToggled?(.underline, true)
    #expect(optionsRow(of: view)?.traitToggles[.underline]?.isOn == true,
            "A callout should take the same typography as text")
}

@MainActor
@Test
func aRichTextChangeOnAPlacedAnnotationIsOneUndoEntry() {
    let (view, window) = makeHostedView()
    view.keyDown(with: key("t", 17, window))
    click(in: view, window: window, at: CGPoint(x: 40, y: 40))
    editor(in: view)?.string = "IIII"
    view.keyDown(with: key("s", 1, window))

    // Select it and turn the background on.
    click(in: view, window: window, at: CGPoint(x: 50, y: 50))
    optionsRow(of: view)?.onTextBackgroundToggled?(true)

    view.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
    )!)

    guard let baked = bake(view, window) else {
        Issue.record("No baked image")
        return
    }
    // With the plate undone, the area beside the glyphs is bare paper again.
    let beside = pixel(baked, CGPoint(x: 200, y: 50), scale: 1)
    #expect(beside.0 == 255 && beside.1 == 255 && beside.2 == 255,
            "One undo should have taken the plate back off")
}
