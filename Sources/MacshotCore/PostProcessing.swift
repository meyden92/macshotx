import AppKit
import CoreImage

// MARK: - Composition state

/// How dark and how far the capture floats off its backdrop. Steps rather than
/// raw blur/offset/opacity numbers: three sliders to say "a bit more shadow" is
/// three ways to get it wrong.
enum ShadowIntensity: String, Codable, CaseIterable, Sendable {
    case none, soft, medium, strong

    /// Blur radius in points; the compositor scales it by the capture's own
    /// pixel scale so a Retina capture gets a Retina shadow.
    var blur: CGFloat {
        switch self {
        case .none: return 0
        case .soft: return 12
        case .medium: return 24
        case .strong: return 40
        }
    }

    /// How far the shadow drops below the capture, in points.
    var offset: CGFloat {
        switch self {
        case .none: return 0
        case .soft: return 5
        case .medium: return 10
        case .strong: return 18
        }
    }

    var opacity: CGFloat {
        switch self {
        case .none: return 0
        case .soft: return 0.25
        case .medium: return 0.35
        case .strong: return 0.45
        }
    }

    var label: String {
        switch self {
        case .none: return "○"
        case .soft: return "◔"
        case .medium: return "◑"
        case .strong: return "●"
        }
    }

    var tooltip: String {
        switch self {
        case .none: return "No shadow"
        case .soft: return "Soft shadow"
        case .medium: return "Medium shadow"
        case .strong: return "Strong shadow"
        }
    }
}

/// The decorative wrapper around a capture. `enabled` is deliberately part of
/// the value — the compositor short-circuits on it — but it is never persisted:
/// every capture starts plain.
struct BeautifySettings: Equatable, Sendable {
    var enabled = false
    var styleID = Backdrops.defaultID
    /// Fraction of the capture's longer side, so the same number looks the same
    /// on a small capture and a large one.
    var paddingFraction: CGFloat = 0.08
    /// Points, clamped at draw time to half the capture's shorter side.
    var cornerRadius: CGFloat = 12
    var shadow = ShadowIntensity.medium
    var windowFrame = false

    /// The remembered look, with the toggle deliberately left off: every
    /// capture starts plain.
    init(remembering defaults: BeautifyDefaults) {
        // A style that no longer exists falls back rather than failing.
        styleID = Backdrops.style(defaults.styleID).id
        paddingFraction = defaults.paddingFraction
        cornerRadius = defaults.cornerRadius
        shadow = ShadowIntensity(rawValue: defaults.shadow) ?? .medium
        windowFrame = defaults.windowFrame
    }

    init(
        enabled: Bool = false,
        styleID: String = Backdrops.defaultID,
        paddingFraction: CGFloat = 0.08,
        cornerRadius: CGFloat = 12,
        shadow: ShadowIntensity = .medium,
        windowFrame: Bool = false
    ) {
        self.enabled = enabled
        self.styleID = styleID
        self.paddingFraction = paddingFraction
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.windowFrame = windowFrame
    }

    var remembered: BeautifyDefaults {
        var defaults = BeautifyDefaults()
        defaults.styleID = styleID
        defaults.paddingFraction = paddingFraction
        defaults.cornerRadius = cornerRadius
        defaults.shadow = shadow.rawValue
        defaults.windowFrame = windowFrame
        return defaults
    }
}

/// Brightness, contrast, saturation and sharpness. Neutral is the identity, and
/// the compositor must skip Core Image entirely there.
struct EffectValues: Equatable, Sendable {
    var brightness: CGFloat = 0
    var contrast: CGFloat = 1
    var saturation: CGFloat = 1
    var sharpness: CGFloat = 0

    static let neutral = EffectValues()
    var isNeutral: Bool { self == .neutral }

    static let brightnessRange: ClosedRange<CGFloat> = -0.5...0.5
    static let contrastRange: ClosedRange<CGFloat> = 0.5...1.5
    static let saturationRange: ClosedRange<CGFloat> = 0...2
    static let sharpnessRange: ClosedRange<CGFloat> = 0...2
}

/// A named set of effect values. A preset writes the four sliders rather than
/// acting as an extra stage, so there is one source of truth for effect state
/// and the user can see and tweak what a preset did.
struct EffectPreset: Equatable, Sendable {
    let name: String
    let values: EffectValues

    static let all: [EffectPreset] = [
        EffectPreset(
            name: "Punch",
            values: EffectValues(brightness: 0.04, contrast: 1.15, saturation: 1.2, sharpness: 0.4)
        ),
        EffectPreset(
            name: "Soft",
            values: EffectValues(brightness: 0.08, contrast: 0.9, saturation: 0.95, sharpness: 0)
        ),
        EffectPreset(
            name: "Mono",
            values: EffectValues(brightness: 0.02, contrast: 1.1, saturation: 0, sharpness: 0.2)
        ),
        EffectPreset(
            name: "Crisp",
            values: EffectValues(brightness: 0, contrast: 1.05, saturation: 1, sharpness: 1.2)
        )
    ]
}

/// The whole post-processing state of one capture. Plain comparable data: the
/// neutral value must produce output byte-identical to an un-composited bake,
/// which is what lets every other path be tested through one function.
struct CompositionState: Equatable, Sendable {
    var beautify = BeautifySettings()
    var effects = EffectValues.neutral

    static let neutral = CompositionState()
    var isNeutral: Bool { self == CompositionState.neutral }
}

// MARK: - Layout

/// Where the capture sits inside the composed canvas. All pixels, all integral,
/// so tests assert exact sizes with no floating-point slack.
struct CompositionLayout: Equatable {
    /// The whole composed image.
    var canvas: CGSize
    /// The capture and, when a window frame is on, its title bar — the unit the
    /// shadow surrounds and the backdrop sits behind.
    var capture: CGRect
    /// How much of `capture`'s top the title bar takes; zero without a frame.
    var titleBarHeight: CGFloat

    /// The capture content itself, below any title bar.
    var content: CGRect {
        CGRect(
            x: capture.minX, y: capture.minY + titleBarHeight,
            width: capture.width, height: capture.height - titleBarHeight
        )
    }
}

/// Composites a capture onto a backdrop. Preview and bake both go through here,
/// differing only in the pixel scale passed in — that invariant is what makes a
/// unit test of this type a statement about what the user sees *and* about what
/// is exported. Any code path that renders a preview without it is a bug.
enum PostProcessingCompositor {
    /// Height of the macOS-style title bar strip, in points.
    static let titleBarPoints: CGFloat = 28

    /// The one layout formula. The margin is `max(padding, shadowBlur +
    /// |shadowOffset|)` on every side, so a shadow bigger than the padding grows
    /// the canvas instead of being clipped, and the capture stays centred.
    static func layout(
        captureSize: CGSize,
        padding: CGFloat,
        shadowBlur: CGFloat,
        shadowOffset: CGFloat,
        titleBarHeight: CGFloat = 0
    ) -> CompositionLayout {
        let margin = max(0, max(padding, shadowBlur + abs(shadowOffset))).rounded()
        let occupied = CGSize(
            width: captureSize.width.rounded(),
            height: (captureSize.height + titleBarHeight).rounded()
        )
        return CompositionLayout(
            canvas: CGSize(
                width: occupied.width + margin * 2,
                height: occupied.height + margin * 2
            ),
            capture: CGRect(
                x: margin, y: margin, width: occupied.width, height: occupied.height
            ),
            titleBarHeight: titleBarHeight.rounded()
        )
    }

    /// The layout `settings` imply for a capture of `captureSize` pixels.
    static func layout(
        captureSize: CGSize, settings: BeautifySettings, scale: CGFloat
    ) -> CompositionLayout {
        layout(
            captureSize: captureSize,
            padding: (settings.paddingFraction * max(captureSize.width, captureSize.height))
                .rounded(),
            shadowBlur: settings.shadow.blur * scale,
            shadowOffset: settings.shadow.offset * scale,
            titleBarHeight: settings.windowFrame ? (titleBarPoints * scale).rounded() : 0
        )
    }

    /// Where a composed canvas is drawn on the display it is previewed on, in
    /// that display's points. Anchored so the capture content stays at 1:1
    /// exactly where it is when the padded canvas fits inside `bounds`;
    /// otherwise shrunk uniformly and centred, `margin` clear of the edges.
    /// Beautify pads outward, so a whole-display capture never fits at 1:1 —
    /// the preview scales, the bake never does (ADR 0007 as amended by ADR
    /// 0013).
    static func previewPlacement(
        of layout: CompositionLayout, capture: CGRect, in bounds: CGRect, margin: CGFloat = 24
    ) -> CGRect {
        let anchored = CGRect(
            x: capture.minX - layout.content.minX,
            y: capture.minY - layout.content.minY,
            width: layout.canvas.width, height: layout.canvas.height
        )
        if bounds.contains(anchored) { return anchored }
        let factor = min(
            1,
            min(
                (bounds.width - margin * 2) / layout.canvas.width,
                (bounds.height - margin * 2) / layout.canvas.height
            )
        )
        let size = CGSize(width: layout.canvas.width * factor, height: layout.canvas.height * factor)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// A radius can never round more than half the shorter side without turning
    /// the capture into a blob.
    static func clampedRadius(_ radius: CGFloat, for size: CGSize) -> CGFloat {
        max(0, min(radius, min(size.width, size.height) / 2))
    }

    // MARK: Rendering

    /// Stages 5–7 of the composition order: the corner-radius clip and optional
    /// window frame, the drop shadow, and the composite onto the backdrop.
    /// Earlier stages — effects, annotations — are already in `source` by the
    /// time it gets here, which is exactly why annotations are clipped by the
    /// corner radius and effects never touch the backdrop.
    @MainActor
    static func render(
        _ source: CGImage, settings: BeautifySettings, scale: CGFloat
    ) -> CGImage {
        guard settings.enabled else { return source }
        let captureSize = CGSize(width: source.width, height: source.height)
        let layout = layout(captureSize: captureSize, settings: settings, scale: scale)
        guard layout.canvas.width >= 1, layout.canvas.height >= 1,
              let ctx = CGContext(
                data: nil,
                width: Int(layout.canvas.width), height: Int(layout.canvas.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return source }

        Backdrops.draw(settings.styleID, in: ctx, size: layout.canvas)

        let radius = clampedRadius(settings.cornerRadius * scale, for: layout.capture.size)
        // CG's origin is bottom-left; the layout is stated top-down, so the
        // capture rect is flipped into the canvas here and nowhere else.
        let capture = CGRect(
            x: layout.capture.minX,
            y: layout.canvas.height - layout.capture.maxY,
            width: layout.capture.width,
            height: layout.capture.height
        )
        let framePath = CGPath(
            roundedRect: capture, cornerWidth: radius, cornerHeight: radius, transform: nil
        )

        ctx.saveGState()
        if settings.shadow != .none {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -settings.shadow.offset * scale),
                blur: settings.shadow.blur * scale,
                color: NSColor.black.withAlphaComponent(settings.shadow.opacity).cgColor
            )
        }
        // One transparency layer, so the title bar and the capture cast a single
        // shadow between them rather than one each.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addPath(framePath)
        ctx.clip()
        if layout.titleBarHeight > 0 {
            drawTitleBar(in: ctx, over: capture, height: layout.titleBarHeight, scale: scale)
        }
        ctx.draw(source, in: CGRect(
            x: capture.minX, y: capture.minY,
            width: capture.width, height: capture.height - layout.titleBarHeight
        ))
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        return ctx.makeImage() ?? source
    }

    /// A macOS-style title bar: a light strip across the top of the framed
    /// capture with three traffic-light dots. Already clipped to the frame's
    /// rounded corners by the caller.
    private static func drawTitleBar(
        in ctx: CGContext, over capture: CGRect, height: CGFloat, scale: CGFloat
    ) {
        let bar = CGRect(
            x: capture.minX, y: capture.maxY - height, width: capture.width, height: height
        )
        ctx.setFillColor(NSColor(white: 0.87, alpha: 1).cgColor)
        ctx.fill(bar)
        ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
        ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: max(1, scale)))

        let diameter = height * 0.4
        let gap = diameter * 0.6
        let colors = [
            NSColor(srgbRed: 1.0, green: 0.37, blue: 0.35, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)
        ]
        var x = bar.minX + height * 0.55
        for color in colors {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(
                x: x, y: bar.midY - diameter / 2, width: diameter, height: diameter
            ))
            x += diameter + gap
        }
    }
}

// MARK: - Image effects

/// Brightness/contrast/saturation/sharpness over the capture pixels.
///
/// ADR 0003 applies here for the same reason it applies to redaction: a
/// full-frame Core Image pass on a large or multi-display capture silently
/// produces nothing — no error, no signal. Callers pass the Selection crop, and
/// every render is nil-checked and falls back to the unfiltered image with a log
/// entry, because an unchecked optional here ships a screenshot that quietly
/// ignored the user's settings.
@MainActor
enum ImageEffects {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func apply(_ values: EffectValues, to image: CGImage) -> CGImage {
        guard !values.isNeutral else { return image }
        var ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent

        if values.brightness != 0 || values.contrast != 1 || values.saturation != 1 {
            guard let filter = CIFilter(name: "CIColorControls") else { return image }
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(values.brightness, forKey: kCIInputBrightnessKey)
            filter.setValue(values.contrast, forKey: kCIInputContrastKey)
            filter.setValue(values.saturation, forKey: kCIInputSaturationKey)
            guard let output = filter.outputImage else { return image }
            ciImage = output
        }
        if values.sharpness > 0 {
            guard let filter = CIFilter(name: "CISharpenLuminance") else { return image }
            filter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(values.sharpness, forKey: kCIInputSharpnessKey)
            guard let output = filter.outputImage else { return image }
            ciImage = output
        }

        guard let rendered = context.createCGImage(ciImage, from: extent) else {
            Log.error("Image effects render produced nothing; using the unfiltered capture")
            return image
        }
        return rendered
    }
}
