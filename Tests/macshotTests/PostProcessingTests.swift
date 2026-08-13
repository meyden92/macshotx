import AppKit
import Testing
@testable import MacshotCore

// The compositor's layout arithmetic and what it actually renders. Preview and
// bake share these functions, so an assertion here is a statement about both.

private let captureSize = CGSize(width: 200, height: 100)

@MainActor
private func makeImage(
    width: Int = 200, height: Int = 100, _ color: NSColor = .systemRed
) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// RGBA of a pixel, in top-left-origin image coordinates.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    let offset = y * image.bytesPerRow + x * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
}

// MARK: - Layout

@Test
func neutralSettingsLeaveTheCanvasTheSizeOfTheCapture() {
    let layout = PostProcessingCompositor.layout(
        captureSize: captureSize, settings: BeautifySettings(enabled: false), scale: 1
    )
    _ = layout
    let neutral = PostProcessingCompositor.layout(
        captureSize: captureSize, padding: 0, shadowBlur: 0, shadowOffset: 0
    )
    #expect(neutral.canvas == captureSize)
    #expect(neutral.capture == CGRect(origin: .zero, size: captureSize))
}

@Test
func theMarginIsTheSameOnEverySideSoTheCaptureStaysCentred() {
    let layout = PostProcessingCompositor.layout(
        captureSize: captureSize, padding: 20, shadowBlur: 0, shadowOffset: 0
    )
    #expect(layout.canvas == CGSize(width: 240, height: 140))
    #expect(layout.capture == CGRect(x: 20, y: 20, width: 200, height: 100))
}

@Test
func aShadowBiggerThanThePaddingGrowsTheCanvasRatherThanBeingClipped() {
    let layout = PostProcessingCompositor.layout(
        captureSize: captureSize, padding: 10, shadowBlur: 24, shadowOffset: 10
    )
    // max(10, 24 + 10) = 34 on every side.
    #expect(layout.canvas == CGSize(width: 268, height: 168))
    #expect(layout.capture == CGRect(x: 34, y: 34, width: 200, height: 100))
}

@Test
func aWindowFrameGrowsTheOccupiedRectByItsTitleBar() {
    let plain = PostProcessingCompositor.layout(
        captureSize: captureSize, padding: 20, shadowBlur: 0, shadowOffset: 0
    )
    let framed = PostProcessingCompositor.layout(
        captureSize: captureSize, padding: 20, shadowBlur: 0, shadowOffset: 0, titleBarHeight: 28
    )
    #expect(framed.canvas.height == plain.canvas.height + 28)
    #expect(framed.canvas.width == plain.canvas.width, "A title bar only adds height")
    #expect(framed.content == CGRect(x: 20, y: 48, width: 200, height: 100),
            "and the capture content sits below it")
}

@Test
func aRadiusIsClampedToHalfTheShorterSide() {
    #expect(PostProcessingCompositor.clampedRadius(500, for: captureSize) == 50)
    #expect(PostProcessingCompositor.clampedRadius(12, for: captureSize) == 12)
    #expect(PostProcessingCompositor.clampedRadius(-5, for: captureSize) == 0)
}

@Test
func paddingIsAFractionOfTheLongerSide() {
    let layout = PostProcessingCompositor.layout(
        captureSize: captureSize,
        settings: BeautifySettings(enabled: true, paddingFraction: 0.1, shadow: .none),
        scale: 1
    )
    #expect(layout.capture.minX == 20, "10% of the 200pt long side")
}

// MARK: - Rendering

@MainActor
@Test
func aNeutralCompositionReturnsTheSourceUntouched() {
    let source = makeImage()
    let composed = PostProcessingCompositor.render(
        source, settings: BeautifySettings(enabled: false), scale: 1
    )
    #expect(composed.width == source.width && composed.height == source.height)
    #expect(pixel(composed, 100, 50) == pixel(source, 100, 50))
}

@MainActor
@Test
func beautifyPutsBackdropAtTheCornersAndTheCaptureAtTheCentre() {
    let composed = PostProcessingCompositor.render(
        makeImage(),
        settings: BeautifySettings(
            enabled: true, styleID: "slate", paddingFraction: 0.1,
            cornerRadius: 0, shadow: .none
        ),
        scale: 1
    )
    #expect(composed.width == 240 && composed.height == 140)

    let corner = pixel(composed, 2, 2)
    #expect(corner.r < 80 && corner.g < 80 && corner.b < 80, "Slate backdrop at the corner")
    let middle = pixel(composed, 120, 70)
    #expect(middle.r > 200 && middle.g < 120, "and the capture in the middle")
}

@MainActor
@Test
func aCornerRadiusLetsTheBackdropThroughTheCapturesCorners() {
    let composed = PostProcessingCompositor.render(
        makeImage(),
        settings: BeautifySettings(
            enabled: true, styleID: "slate", paddingFraction: 0.1,
            cornerRadius: 30, shadow: .none
        ),
        scale: 1
    )
    // The capture occupies (20, 20)–(220, 120) with a 30pt radius, so its very
    // corner is outside the rounded shape and its middle-left edge is not.
    let cut = pixel(composed, 23, 23)
    #expect(cut.r < 80, "Just inside the capture's square corner shows backdrop")
    let kept = pixel(composed, 120, 22)
    #expect(kept.r > 200, "while the middle of the same edge is capture content")
}

@MainActor
@Test
func aShadowDarkensTheBackdropBelowTheCaptureAndGrowsTheCanvasToFit() {
    var settings = BeautifySettings(
        enabled: true, styleID: "paper", paddingFraction: 0.2, cornerRadius: 0
    )
    settings.shadow = .none
    let lit = PostProcessingCompositor.render(makeImage(), settings: settings, scale: 1)
    settings.shadow = .strong
    let shadowed = PostProcessingCompositor.render(makeImage(), settings: settings, scale: 1)

    #expect(shadowed.height > lit.height,
            "A shadow that reaches past the padding grows the canvas rather than being clipped")

    let layout = PostProcessingCompositor.layout(
        captureSize: captureSize, settings: settings, scale: 1
    )
    let below = pixel(shadowed, shadowed.width / 2, Int(layout.capture.maxY) + 15)
    let farCorner = pixel(shadowed, 3, 3)
    #expect(below.r < farCorner.r - 15,
            "The backdrop right under the capture should be darker than the far corner")
}

@MainActor
@Test
func aWindowFrameDrawsATitleBarAboveTheCapture() {
    let composed = PostProcessingCompositor.render(
        makeImage(),
        settings: BeautifySettings(
            enabled: true, styleID: "slate", paddingFraction: 0.1,
            cornerRadius: 0, shadow: .none, windowFrame: true
        ),
        scale: 1
    )
    #expect(composed.height == 168, "100pt capture + 28pt title bar + 20pt margins")
    let bar = pixel(composed, 120, 30)
    #expect(bar.r > 190 && bar.g > 190 && bar.b > 190, "Title bar strip, not capture content")
    let content = pixel(composed, 120, 90)
    #expect(content.r > 200 && content.g < 120, "and the capture below it")
}

@MainActor
@Test
func aMeshBackdropIsAnActualGradientAndIsCachedBySizeAndStyle() {
    Backdrops.resetMeshCache()
    let settings = BeautifySettings(
        enabled: true, styleID: "aurora", paddingFraction: 0.25, cornerRadius: 0, shadow: .none
    )
    let composed = PostProcessingCompositor.render(makeImage(), settings: settings, scale: 1)
    let topLeft = pixel(composed, 3, 3)
    let bottomRight = pixel(composed, composed.width - 4, composed.height - 4)
    #expect(topLeft != bottomRight, "A mesh gradient is not a flat fill")
    #expect(topLeft.r < 200 && topLeft.g < 200, "and neither corner is the capture's red")

    #expect(Backdrops.renderedMeshCount == 1,
            "The mesh really rendered through ImageRenderer rather than falling back")
    _ = PostProcessingCompositor.render(makeImage(), settings: settings, scale: 1)
    #expect(Backdrops.renderedMeshCount == 1,
            "and re-composing at the same size reuses it instead of rendering again")
}

@MainActor
@Test
func aSourceWithTransparentCornersLetsTheBackdropThroughWithoutAHalo() {
    // A source with transparent edges: the backdrop has to show through them
    // cleanly, whatever put them there.
    let ctx = CGContext(
        data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.addPath(CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: 200, height: 100),
        cornerWidth: 24, cornerHeight: 24, transform: nil
    ))
    ctx.fillPath()

    let composed = PostProcessingCompositor.render(
        ctx.makeImage()!,
        settings: BeautifySettings(
            enabled: true, styleID: "paper", paddingFraction: 0.1,
            cornerRadius: 0, shadow: .none
        ),
        scale: 1
    )
    let throughTheCorner = pixel(composed, 22, 22)
    #expect(throughTheCorner.r > 220 && throughTheCorner.g > 220 && throughTheCorner.b > 210,
            "The paper backdrop should show through, with no dark premultiplication halo")
}

// MARK: - Effects

@MainActor
@Test
func neutralEffectsSkipCoreImageEntirely() {
    let source = makeImage(NSColor(white: 0.5, alpha: 1))
    #expect(ImageEffects.apply(.neutral, to: source) === source,
            "Neutral must not even build a filter")
}

@MainActor
@Test
func brightnessRaisesAndSaturationCollapsesTheSampledColour() {
    let grey = makeImage(width: 40, height: 40, NSColor(white: 0.5, alpha: 1))
    var values = EffectValues.neutral
    values.brightness = 0.3
    let brighter = ImageEffects.apply(values, to: grey)
    #expect(pixel(brighter, 20, 20).r > pixel(grey, 20, 20).r + 30)

    let red = makeImage(width: 40, height: 40, .systemRed)
    var flat = EffectValues.neutral
    flat.saturation = 0
    let grey2 = ImageEffects.apply(flat, to: red)
    let sample = pixel(grey2, 20, 20)
    #expect(abs(sample.r - sample.g) < 12 && abs(sample.g - sample.b) < 12,
            "Zero saturation should collapse the patch toward grey, got \(sample)")
}

@MainActor
@Test
func effectsChangeALargeCaptureRatherThanSilentlyDoingNothing() {
    // ADR 0003's failure mode is silence, so this asserts on content.
    let large = makeImage(width: 3200, height: 1800, NSColor(white: 0.5, alpha: 1))
    var values = EffectValues.neutral
    values.brightness = 0.3
    let brighter = ImageEffects.apply(values, to: large)
    #expect(brighter.width == 3200 && brighter.height == 1800)
    #expect(pixel(brighter, 1600, 900).r > pixel(large, 1600, 900).r + 30)
}

@MainActor
@Test
func effectsMoveTheCaptureAndLeaveTheBackdropAlone() {
    // The test that pins the composition order.
    var values = EffectValues.neutral
    values.brightness = 0.3
    let settings = BeautifySettings(
        enabled: true, styleID: "slate", paddingFraction: 0.1, cornerRadius: 0, shadow: .none
    )
    let grey = makeImage(NSColor(white: 0.5, alpha: 1))
    let plain = PostProcessingCompositor.render(grey, settings: settings, scale: 1)
    let effected = PostProcessingCompositor.render(
        ImageEffects.apply(values, to: grey), settings: settings, scale: 1
    )
    #expect(pixel(effected, 2, 2) == pixel(plain, 2, 2), "The backdrop is not the capture")
    #expect(pixel(effected, 120, 70).r > pixel(plain, 120, 70).r + 30,
            "but the capture itself moved")
}

@MainActor
@Test
func everyPresetMovesTheImageAndResetPutsItBack() {
    let grey = makeImage(width: 40, height: 40, NSColor(white: 0.5, alpha: 1))
    for preset in EffectPreset.all {
        let applied = ImageEffects.apply(preset.values, to: grey)
        #expect(pixel(applied, 20, 20) != pixel(grey, 20, 20),
                "\(preset.name) should visibly change the capture")
    }
    #expect(ImageEffects.apply(.neutral, to: grey) === grey, "and reset returns the original")
}

// MARK: - Backdrop styles

@Test
func theStyleListIsCuratedAndIdentifiersAreStable() {
    var solids = 0, linears = 0, meshes = 0
    for style in Backdrops.all {
        switch style.kind {
        case .solid: solids += 1
        case .linear: linears += 1
        case .mesh: meshes += 1
        }
    }
    #expect(solids >= 2 && linears >= 3 && meshes >= 3)
    #expect(Set(Backdrops.all.map(\.id)).count == Backdrops.all.count, "Identifiers are unique")
    #expect(Backdrops.style("no-such-style").id == Backdrops.defaultID,
            "A style that no longer exists falls back rather than failing")
}
