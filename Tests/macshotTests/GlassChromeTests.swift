import AppKit
import Testing
@testable import MacshotCore

// The parts of the chrome kit that have a right answer: the derivations and the
// mappings. The rendering of glass itself is not unit-tested — there is no
// supported way to assert that a refraction looks right.

@Test
func anInnerSurfaceTakesItsParentsRadiusLessTheInsetBetweenThem() {
    #expect(ChromeMetrics.concentricRadius(parent: 16, inset: 4) == 12)
    #expect(ChromeMetrics.concentricRadius(parent: 9, inset: 4) == 5)
    // A deeply inset child goes square rather than negative.
    #expect(ChromeMetrics.concentricRadius(parent: 8, inset: 20) == 0)
}

@Test
func radiusTiersAreOrderedLargestFirst() {
    #expect(ChromeMetrics.RadiusTier.large.radius > ChromeMetrics.RadiusTier.small.radius)
    #expect(ChromeMetrics.RadiusTier.small.radius >= ChromeMetrics.RadiusTier.tooltip.radius)
}

@MainActor
@Test
func theAccentRolesResolveToTheUsersAccentColourNotAFixedBlue() {
    #expect(ChromeTintRole.neutral.tintColor == nil, "A strip or a card is untinted glass")
    #expect(ChromeTintRole.active.tintColor == NSColor.controlAccentColor)
    #expect(ChromeTintRole.primary.tintColor == NSColor.controlAccentColor)
    #expect(ChromeTintRole.destructive.tintColor == NSColor.systemRed)
    // Dynamic colours, never snapshotted: the role hands back the system colour
    // itself, so it re-resolves with appearance and accent changes.
    #expect(ChromeTintRole.neutral.contentColor == NSColor.labelColor)
}

@Test
func reduceTransparencyPicksTheSystemsOwnReducedMaterial() {
    #expect(ChromeMaterial.resolve(reduceTransparency: false) == .glass)
    #expect(ChromeMaterial.resolve(reduceTransparency: true) == .reduced)
}

@MainActor
@Test
func aWrappedViewBecomesTheGlassSurfacesContentView() {
    let content = NSView(frame: NSRect(x: 10, y: 20, width: 120, height: 40))
    let surface = GlassChrome.surface(content, radius: .large, tint: .neutral)

    #expect(surface.frame == NSRect(x: 10, y: 20, width: 120, height: 40),
            "The surface takes the content's place")
    if let glass = surface as? NSGlassEffectView {
        #expect(glass.contentView === content,
                "Only the content view is guaranteed to be inside the glass")
        #expect(glass.cornerRadius == ChromeMetrics.RadiusTier.large.radius)
    } else {
        #expect(content.superview === surface, "The reduced material still hosts the content")
    }
}

@MainActor
@Test
func aBackdropSitsBehindTheContentAndNeverTakesAClick() {
    let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    let button = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    chrome.addSubview(button)
    GlassChrome.installBackdrop(in: chrome, radius: .small)

    #expect(chrome.subviews.first !== button, "The material is behind the content")
    #expect(chrome.subviews.last === button)
    #expect(chrome.subviews.first?.frame == chrome.bounds)
}

@MainActor
@Test
func aTypicalCaptureKeepsTheGlassSurfaceCountInSingleDigits() {
    let ctx = CGContext(
        data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let window = NSWindow(
        contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    let view = RegionPickerView(frame: frame, image: ctx.makeImage()!, scale: 1.0)
    window.contentView = view
    window.makeFirstResponder(view)

    func key(_ char: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code
        )!
    }
    // Draw a Selection, then open both post-processing panels — about as much
    // chrome as one capture ever has on screen at once.
    view.keyDown(with: key("s", 1))
    for (kind, point) in [
        (NSEvent.EventType.leftMouseDown, CGPoint(x: 50, y: 50)),
        (.leftMouseDragged, CGPoint(x: 250, y: 250)),
        (.leftMouseUp, CGPoint(x: 250, y: 250))
    ] {
        let event = NSEvent.mouseEvent(
            with: kind, location: NSPoint(x: point.x, y: 400 - point.y),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
        )!
        switch kind {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
    view.keyDown(with: key("b", 11, .option))
    view.keyDown(with: key("e", 14, .option))

    func glassSurfaces(in view: NSView) -> Int {
        view.subviews.reduce(view is NSGlassEffectView ? 1 : 0) { $0 + glassSurfaces(in: $1) }
    }
    let surfaces = glassSurfaces(in: view)
    #expect(surfaces > 0, "Chrome really is on glass")
    #expect(surfaces < 10, "Glass surfaces should stay in single digits, got \(surfaces)")
}
