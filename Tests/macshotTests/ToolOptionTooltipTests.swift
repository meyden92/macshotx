import AppKit
import Testing
@testable import MacshotCore

// Every control in the tool-options row is a swatch, a glyph or a bare slider,
// so the tooltip is the only thing that says what it changes.

/// Every control type in the row that a user can point at and act on.
@MainActor
private func interactiveControls(in view: NSView) -> [NSView] {
    var found: [NSView] = []
    func walk(_ view: NSView) {
        let isControl = view is ColorWellButton
            || view is OptionSlider
            || view is NSPopUpButton
            || view is NSSlider
            || view is SegmentButton
            || view is ToggleOptionButton
            || view is OptionActionButton
        if isControl { found.append(view) }
        view.subviews.forEach(walk)
    }
    walk(view)
    return found
}

@MainActor
@Test
func everyControlInTheToolOptionsRowSaysWhatItChanges() {
    let row = ToolOptionsRowView()
    let controls = interactiveControls(in: row)
    #expect(controls.count > 15, "Expected the whole row, found \(controls.count) controls")

    let mute = controls.filter { ($0.toolTip ?? "").isEmpty }
    #expect(
        mute.isEmpty,
        "No tooltip on: \(mute.map { String(describing: type(of: $0)) }.sorted())"
    )
}

/// Carrying a tooltip is not the same as showing one: the overlay draws its own
/// tooltips, and AppKit's never appear in this window. The row has to publish
/// what the pointer is over, or every control is mute however well it is
/// labelled.
@MainActor
@Test
func pointingAtAControlPublishesItsTooltipForTheOverlayToDraw() {
    let row = ToolOptionsRowView()
    row.configure(options: Tool.text.options, style: AnnotationStyle())
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
    let window = NSWindow(
        contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    window.contentView = host
    host.addSubview(row)

    var published: (text: String?, frame: NSRect)?
    row.onHover = { published = ($0, $1) }

    let bold = try! #require(row.traitToggles[.bold])
    let center = row.convert(bold.frame.center, from: bold.superview)
    row.mouseMoved(with: moved(to: row.convert(center, to: nil), in: window))

    #expect(published?.text == bold.toolTip)
    #expect(published?.frame == bold.convert(bold.bounds, to: host),
            "The frame is what the overlay anchors the tooltip to")

    // Off every control, the tooltip has to be taken back down again.
    row.mouseExited(with: moved(to: .zero, in: window))
    #expect(published?.text == nil)
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

@MainActor
private func moved(to windowPoint: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: .mouseMoved, location: windowPoint, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
        clickCount: 0, pressure: 0
    )!
}

@MainActor
@Test
func theSwatchesAndTheFontMenuNameTheThingTheyColourOrSet() {
    let row = ToolOptionsRowView()
    // Four identical-looking circles: only the tooltip tells them apart.
    let tooltips = [
        row.colorWell.toolTip, row.fillColorWell.toolTip,
        row.backgroundWell.toolTip, row.outlineWell.toolTip
    ].compactMap { $0 }
    #expect(tooltips.count == 4)
    #expect(Set(tooltips).count == 4, "Each swatch needs its own wording, got \(tooltips)")
    #expect(row.fontPopup.toolTip?.isEmpty == false)
}
