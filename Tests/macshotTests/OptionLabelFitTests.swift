import AppKit
import Testing
@testable import MacshotCore

// The options row and the post-processing panels have no captions: an option's
// name lives in its readout ("Padding 25%") or in a glyph. Anything clipped
// there is unreachable, so every label has to fit the box it is drawn in.

/// Labels that need more width than they are given, as "'text' needs N has M".
@MainActor
private func clippedLabels(in root: NSView) -> [String] {
    var clipped: [String] = []
    func walk(_ view: NSView) {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            let needed = ceil(field.attributedStringValue.size().width)
            if needed > field.frame.width + 0.5 {
                clipped.append("'\(field.stringValue)' needs \(needed) has \(field.frame.width)")
            }
        }
        view.subviews.forEach(walk)
    }
    walk(root)
    return clipped
}

@MainActor
@Test
func noReadoutInTheToolOptionsRowIsCutOffAtItsWidestValue() {
    // Every slider pushed to the end of its range, where its readout is longest.
    var style = AnnotationStyle()
    style.lineWidth = ToolOptionsRowView.lineWidthRange.upperBound
    style.fontSize = ToolOptionsRowView.fontSizeRange.upperBound
    style.cornerRadius = ToolOptionsRowView.cornerRadiusRange.upperBound
    style.magnification = LoupeGeometry.magnificationRange.upperBound
    style.dimStrength = SpotlightGeometry.strengthRange.upperBound

    let row = ToolOptionsRowView()
    row.configure(options: AnnotationOptions(rawValue: ~0), style: style)
    #expect(clippedLabels(in: row).isEmpty, "Cut off: \(clippedLabels(in: row))")
}

@MainActor
@Test
func theBeautifyAndEffectsPanelsShowTheWholeOptionNameNotJustItsTail() {
    // These sliders carry the option's name in the readout itself, so a clipped
    // readout is a missing label rather than a missing digit.
    var settings = BeautifySettings()
    settings.paddingFraction = 0.25
    settings.cornerRadius = 48
    let beautify = PostProcessingPanelView()
    beautify.configure(settings)
    #expect(clippedLabels(in: beautify).isEmpty, "Cut off: \(clippedLabels(in: beautify))")

    var values = EffectValues.neutral
    values.brightness = EffectValues.brightnessRange.lowerBound
    values.contrast = EffectValues.contrastRange.upperBound
    values.saturation = EffectValues.saturationRange.upperBound
    values.sharpness = EffectValues.sharpnessRange.upperBound
    let effects = EffectsPanelView()
    effects.configure(values)
    #expect(clippedLabels(in: effects).isEmpty, "Cut off: \(clippedLabels(in: effects))")
}

@MainActor
@Test
func aReadoutNeverClaimsAValueTheTrackCannotShow() {
    // A style carrying an out-of-range value must not print a number the knob
    // cannot reach — that is both a lie and the one string wide enough to clip.
    let row = ToolOptionsRowView()
    var style = AnnotationStyle()
    style.dimStrength = 4
    row.configure(options: AnnotationOptions(rawValue: ~0), style: style)
    #expect(clippedLabels(in: row).isEmpty, "Cut off: \(clippedLabels(in: row))")
}
