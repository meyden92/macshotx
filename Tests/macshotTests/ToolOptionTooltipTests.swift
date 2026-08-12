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
