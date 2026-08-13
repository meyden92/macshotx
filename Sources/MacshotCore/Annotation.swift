import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum ToolGroup {
    case selection
    case shapes
    case drawing
    case text
    case markers
    case redaction
}

enum Tool: String, CaseIterable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case pen
    case highlighter
    case spotlight
    case text
    case callout
    case stepMarker
    case measure
    case loupe
    case fillRect
    case fillFreehand
    case blur
    case pixelate

    var group: ToolGroup {
        switch self {
        case .select: return .selection
        case .rectangle, .ellipse, .line, .arrow: return .shapes
        case .pen, .highlighter, .spotlight: return .drawing
        case .text, .callout: return .text
        case .stepMarker, .measure, .loupe: return .markers
        case .fillRect, .fillFreehand, .blur, .pixelate: return .redaction
        }
    }

    var keyEquivalent: String {
        switch self {
        case .select: return "s"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .pen: return "p"
        case .highlighter: return "h"
        // Dim the rest; S, P, O, T, L and H are all taken.
        case .spotlight: return "d"
        case .text: return "t"
        case .callout: return "c"
        case .stepMarker: return "n"
        case .measure: return "m"
        // Magnifying glass; L belongs to the line tool.
        case .loupe: return "g"
        case .fillRect: return "f"
        case .fillFreehand: return ""
        case .blur: return "b"
        case .pixelate: return "x"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "rectangle.dashed"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .spotlight: return "circle.dashed.inset.filled"
        case .text: return "textformat"
        case .callout: return "bubble.left"
        case .stepMarker: return "1.circle.fill"
        case .measure: return "ruler"
        case .loupe: return "magnifyingglass"
        case .fillRect: return "rectangle.fill"
        case .fillFreehand: return "scribble.variable"
        case .blur: return "drop.degreesign"
        case .pixelate: return "square.grid.3x3.square"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select region"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .spotlight: return "Spotlight"
        case .text: return "Text"
        case .callout: return "Callout"
        case .stepMarker: return "Step marker"
        case .measure: return "Measure"
        case .loupe: return "Loupe"
        case .fillRect: return "Filled redact"
        case .fillFreehand: return "Freehand redact"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        }
    }
}

/// How a stroke is broken up. Applies to lines and arrows only in this phase;
/// rectangle and ellipse strokes stay solid.
enum DashStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted

    var label: String {
        switch self {
        case .solid: return "——"
        case .dashed: return "– –"
        case .dotted: return "·  ·"
        }
    }

    var tooltip: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }
}

/// Which head an arrow wears. Size always derives from the line width.
enum ArrowHead: String, Codable, CaseIterable {
    case standard, thick, doubleEnded, openV, tail

    var label: String {
        switch self {
        case .standard: return "→"
        case .thick: return "➜"
        case .doubleEnded: return "↔"
        case .openV: return "›"
        case .tail: return "⇥"
        }
    }

    var tooltip: String {
        switch self {
        case .standard: return "Standard head"
        case .thick: return "Thick head"
        case .doubleEnded: return "Head at both ends"
        case .openV: return "Open V"
        case .tail: return "Head with a tail flare"
        }
    }
}

/// How a closed shape is painted. Stroke-only is what macshot has always done
/// and stays the default, so existing configs and existing captures look the
/// same.
enum FillMode: String, Codable, CaseIterable {
    case strokeOnly, fillOnly, strokeAndFill

    var label: String {
        switch self {
        case .strokeOnly: return "□"
        case .fillOnly: return "■"
        case .strokeAndFill: return "▣"
        }
    }

    var tooltip: String {
        switch self {
        case .strokeOnly: return "Stroke only"
        case .fillOnly: return "Fill only"
        case .strokeAndFill: return "Stroke and fill"
        }
    }

    var paintsFill: Bool { self != .strokeOnly }
    var paintsStroke: Bool { self != .fillOnly }
}

struct StrokeStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    /// Only the rect-like kinds rotate; a line's direction is its geometry.
    /// Reachable through `Annotation.rotated(to:)`, which refuses the rest.
    var rotation: CGFloat = 0
    var dash: DashStyle = .solid
    /// Carried by arrows; a line has no head to pick.
    var arrowHead: ArrowHead = .standard
    /// Carried by the closed shapes. `fillColor` is independent of `color`,
    /// opacity included, so a tinted box can have a solid border.
    var fillMode: FillMode = .strokeOnly
    var fillColor: NSColor = NSColor.systemRed.withAlphaComponent(0.3)
    /// Rectangles only, clamped against the rect at draw time.
    var cornerRadius: CGFloat = 0

    static let `default` = StrokeStyle(color: .systemRed, lineWidth: 3.0)
    static let highlighter = StrokeStyle(
        color: NSColor.systemYellow.withAlphaComponent(0.35),
        lineWidth: 22.0
    )
}

/// Which shape a spotlight's bright region takes.
enum SpotlightShape: String, Codable, CaseIterable {
    case rectangle, ellipse

    var label: String {
        switch self {
        case .rectangle: return "▭"
        case .ellipse: return "⬭"
        }
    }

    var tooltip: String {
        switch self {
        case .rectangle: return "Rectangular spotlight"
        case .ellipse: return "Elliptical spotlight"
        }
    }
}

/// A spotlight's shape, plus the dim strength. The strength is an overlay-level
/// value written to every spotlight at once — a single composed layer can only
/// have one opacity, so storing a different one per annotation would make
/// "which wins?" unanswerable. Keeping it on the annotation is what makes a
/// change to it an ordinary, undoable style change.
struct SpotlightStyle: Equatable, Codable {
    var shape: SpotlightShape = .rectangle
    var strength: CGFloat = SpotlightGeometry.defaultStrength

    static let `default` = SpotlightStyle()
}

extension SpotlightStyle {
    fileprivate mutating func apply(_ style: AnnotationStyle) {
        if let shape = style.spotlightShape { self.shape = shape }
        if let strength = style.dimStrength { self.strength = strength }
    }
}

/// The loupe's chrome: the rings around both circles and the connector between
/// them, as one unit. Radii live on the annotation, not here — they are
/// geometry, not appearance.
struct LoupeStyle: Equatable {
    var outlineColor: NSColor
    var outlineVisible: Bool = true

    static let `default` = LoupeStyle(outlineColor: .white)
}

extension LoupeStyle {
    fileprivate mutating func apply(_ style: AnnotationStyle) {
        if let color = style.color { self.outlineColor = color }
        if let visible = style.outlineVisible { self.outlineVisible = visible }
    }
}

extension LoupeStyle: Codable {
    private enum CodingKeys: String, CodingKey { case outlineColor, outlineVisible }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outlineColor = NSColor(
            hexString: try c.decodeIfPresent(String.self, forKey: .outlineColor) ?? ""
        ) ?? LoupeStyle.default.outlineColor
        outlineVisible = try c.decodeIfPresent(Bool.self, forKey: .outlineVisible) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outlineColor.hexRGBAString, forKey: .outlineColor)
        try c.encode(outlineVisible, forKey: .outlineVisible)
    }
}

struct FillStyle: Equatable {
    var color: NSColor
    /// Carried by the filled rect only — see `StrokeStyle.rotation`.
    var rotation: CGFloat = 0

    static let redact = FillStyle(color: .black)
}

/// Where wrapped lines sit inside the text box.
enum TextAlignment: String, Codable, CaseIterable {
    case left, center, right

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    var label: String {
        switch self {
        case .left: return "⇤"
        case .center: return "↔"
        case .right: return "⇥"
        }
    }

    var tooltip: String {
        switch self {
        case .left: return "Align left"
        case .center: return "Align centre"
        case .right: return "Align right"
        }
    }
}

/// Typography for text and callouts. Per-annotation, not per-character: there
/// are no mixed runs inside one annotation, which is what keeps the style a
/// value the options row can show and the clipboard can carry.
struct TextStyle: Equatable {
    var color: NSColor
    var fontSize: CGFloat
    /// See `StrokeStyle.rotation`.
    var rotation: CGFloat = 0
    /// Empty means the system font, which is what text has always used.
    var fontFamily: String = ""
    /// Bold by default, because that is how macshot has always drawn text.
    var bold: Bool = true
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var alignment: TextAlignment = .left
    /// Optional plate behind the text, so a label stays readable over a busy
    /// screenshot. Nil is off.
    var backgroundColor: NSColor?
    /// Optional contrasting stroke around the glyphs, so white text reads over
    /// white. Nil is off.
    var outlineColor: NSColor?
    var outlineWidth: CGFloat = 2

    static let `default` = TextStyle(color: .systemRed, fontSize: 22)
}

/// The style axes shared across annotation kinds. Each is optional so "this
/// kind has no such axis" is representable: reading gives what the annotation
/// carries, writing an axis a kind does not carry is ignored. Adding an axis
/// means extending this struct and the kinds that carry it — not every case of
/// a separate switch per axis, which is what restyling used to cost.
struct AnnotationStyle: Equatable {
    var color: NSColor?
    var lineWidth: CGFloat?
    var fontSize: CGFloat?
    var dash: DashStyle?
    var arrowHead: ArrowHead?
    var fillMode: FillMode?
    var fillColor: NSColor?
    var cornerRadius: CGFloat?
    var fontFamily: String?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var alignment: TextAlignment?
    /// Doubly optional: the outer nil means "leave it alone", the inner nil
    /// means "turn it off". Without that, switching a background off would be
    /// indistinguishable from not touching it.
    var backgroundColor: NSColor??
    var outlineColor: NSColor??
    var outlineWidth: CGFloat?
    /// The loupe's, and geometry rather than appearance: writing it rescales the
    /// lens. It rides here because the options row is fed one composed value,
    /// and a control that had to bypass that would be the odd one out.
    var magnification: CGFloat?
    var outlineVisible: Bool?
    var spotlightShape: SpotlightShape?
    var dimStrength: CGFloat?
}

/// Which style axes a tool — or a placed annotation — actually offers. The
/// tool-options row renders what this says and nothing else, so "does the
/// highlighter have a font size?" is answered in one place instead of once per
/// control.
struct AnnotationOptions: OptionSet {
    let rawValue: Int

    static let color = AnnotationOptions(rawValue: 1 << 0)
    static let lineWidth = AnnotationOptions(rawValue: 1 << 1)
    static let fontSize = AnnotationOptions(rawValue: 1 << 2)
    static let dash = AnnotationOptions(rawValue: 1 << 3)
    static let arrowHead = AnnotationOptions(rawValue: 1 << 4)
    /// An action rather than an axis, and only ever on a placed arrow: there is
    /// nothing to flip about a tool's default style.
    static let flip = AnnotationOptions(rawValue: 1 << 5)
    static let fillMode = AnnotationOptions(rawValue: 1 << 6)
    static let cornerRadius = AnnotationOptions(rawValue: 1 << 7)
    static let fontFamily = AnnotationOptions(rawValue: 1 << 8)
    static let textTraits = AnnotationOptions(rawValue: 1 << 9)
    static let alignment = AnnotationOptions(rawValue: 1 << 10)
    static let textBackground = AnnotationOptions(rawValue: 1 << 11)
    static let textOutline = AnnotationOptions(rawValue: 1 << 12)
    static let magnification = AnnotationOptions(rawValue: 1 << 13)
    /// The loupe's rings and connector, on or off as one.
    static let outlineVisible = AnnotationOptions(rawValue: 1 << 14)
    static let spotlightShape = AnnotationOptions(rawValue: 1 << 15)
    static let dimStrength = AnnotationOptions(rawValue: 1 << 16)

    /// Everything a text-bearing annotation offers.
    static let richText: AnnotationOptions = [
        .color, .fontSize, .fontFamily, .textTraits, .alignment,
        .textBackground, .textOutline
    ]
}

extension Tool {
    var options: AnnotationOptions {
        switch self {
        case .select, .blur, .pixelate: return []
        case .pen, .highlighter: return [.color, .lineWidth]
        // No colour: emphasis by subtraction is always black, and the strength
        // is one value for the whole composed layer.
        case .spotlight: return [.spotlightShape, .dimStrength]
        case .rectangle: return [.color, .lineWidth, .fillMode, .cornerRadius]
        case .ellipse: return [.color, .lineWidth, .fillMode]
        case .line: return [.color, .lineWidth, .dash]
        case .arrow: return [.color, .lineWidth, .dash, .arrowHead]
        case .measure: return [.color, .lineWidth]
        case .loupe: return [.color, .magnification, .outlineVisible]
        case .text, .callout: return .richText
        case .stepMarker, .fillRect, .fillFreehand: return [.color]
        }
    }
}

extension Annotation {
    /// A placed annotation offers what the tool that drew it offers, plus the
    /// actions that only make sense once something is actually placed.
    var options: AnnotationOptions {
        if case .arrow = self { return tool.options.union(.flip) }
        return tool.options
    }
}

extension StrokeStyle {
    fileprivate mutating func apply(_ style: AnnotationStyle) {
        if let color = style.color { self.color = color }
        if let lineWidth = style.lineWidth { self.lineWidth = lineWidth }
        if let dash = style.dash { self.dash = dash }
        if let arrowHead = style.arrowHead { self.arrowHead = arrowHead }
        if let fillMode = style.fillMode { self.fillMode = fillMode }
        if let fillColor = style.fillColor { self.fillColor = fillColor }
        if let cornerRadius = style.cornerRadius { self.cornerRadius = cornerRadius }
    }
}

extension FillStyle {
    fileprivate mutating func apply(_ style: AnnotationStyle) {
        if let color = style.color { self.color = color }
    }
}

extension TextStyle {
    mutating func apply(_ style: AnnotationStyle) {
        if let color = style.color { self.color = color }
        if let fontSize = style.fontSize { self.fontSize = fontSize }
        if let fontFamily = style.fontFamily { self.fontFamily = fontFamily }
        if let bold = style.bold { self.bold = bold }
        if let italic = style.italic { self.italic = italic }
        if let underline = style.underline { self.underline = underline }
        if let strikethrough = style.strikethrough { self.strikethrough = strikethrough }
        if let alignment = style.alignment { self.alignment = alignment }
        if let backgroundColor = style.backgroundColor { self.backgroundColor = backgroundColor }
        if let outlineColor = style.outlineColor { self.outlineColor = outlineColor }
        if let outlineWidth = style.outlineWidth { self.outlineWidth = outlineWidth }
    }
}

// Colors are not Codable, so each style struct spells out its own coding with
// the color as a hex string. Everything else an annotation carries — CGRect,
// CGPoint, CGFloat, String, Int — already is, which is what lets `Annotation`
// synthesize its own: a style axis added by a later slice reaches the clipboard
// without anyone remembering to extend a parallel wire format.
extension StrokeStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case color, lineWidth, rotation, dash, arrowHead
        case fillMode, fillColor, cornerRadius
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = StrokeStyle.default
        color = NSColor(hexString: try c.decodeIfPresent(String.self, forKey: .color) ?? "")
            ?? fallback.color
        lineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? fallback.lineWidth
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        dash = try c.decodeIfPresent(DashStyle.self, forKey: .dash) ?? .solid
        arrowHead = try c.decodeIfPresent(ArrowHead.self, forKey: .arrowHead) ?? .standard
        fillMode = try c.decodeIfPresent(FillMode.self, forKey: .fillMode) ?? .strokeOnly
        fillColor = NSColor(hexString: try c.decodeIfPresent(String.self, forKey: .fillColor) ?? "")
            ?? fallback.fillColor
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color.hexRGBAString, forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(dash, forKey: .dash)
        try c.encode(arrowHead, forKey: .arrowHead)
        try c.encode(fillMode, forKey: .fillMode)
        try c.encode(fillColor.hexRGBAString, forKey: .fillColor)
        try c.encode(cornerRadius, forKey: .cornerRadius)
    }
}

extension FillStyle: Codable {
    private enum CodingKeys: String, CodingKey { case color, rotation }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = NSColor(hexString: try c.decodeIfPresent(String.self, forKey: .color) ?? "")
            ?? FillStyle.redact.color
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color.hexRGBAString, forKey: .color)
        try c.encode(rotation, forKey: .rotation)
    }
}

extension TextStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case color, fontSize, rotation, fontFamily, bold, italic, underline, strikethrough
        case alignment, backgroundColor, outlineColor, outlineWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TextStyle.default
        color = NSColor(hexString: try c.decodeIfPresent(String.self, forKey: .color) ?? "")
            ?? fallback.color
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? fallback.fontSize
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? true
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        alignment = try c.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? .left
        backgroundColor = (try c.decodeIfPresent(String.self, forKey: .backgroundColor))
            .flatMap { NSColor(hexString: $0) }
        outlineColor = (try c.decodeIfPresent(String.self, forKey: .outlineColor))
            .flatMap { NSColor(hexString: $0) }
        outlineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .outlineWidth) ?? 2
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color.hexRGBAString, forKey: .color)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(bold, forKey: .bold)
        try c.encode(italic, forKey: .italic)
        try c.encode(underline, forKey: .underline)
        try c.encode(strikethrough, forKey: .strikethrough)
        try c.encode(alignment, forKey: .alignment)
        try c.encodeIfPresent(backgroundColor?.hexRGBAString, forKey: .backgroundColor)
        try c.encodeIfPresent(outlineColor?.hexRGBAString, forKey: .outlineColor)
        try c.encode(outlineWidth, forKey: .outlineWidth)
    }
}

// Equatable so a drag that ends exactly where it started is detectable as a
// history no-op — not for test assertions (colors round-trip lossily; tests
// compare components with a tolerance instead).
enum Annotation: Equatable, Codable {
    case rectangle(CGRect, StrokeStyle)
    case ellipse(CGRect, StrokeStyle)
    case line(from: CGPoint, to: CGPoint, StrokeStyle)
    case arrow(from: CGPoint, to: CGPoint, StrokeStyle)
    case freehand(points: [CGPoint], StrokeStyle)
    case highlighter(points: [CGPoint], StrokeStyle)
    /// A region that keeps its brightness while everything else dims. Never
    /// drawn on its own — the render pass composes every spotlight into one dim
    /// layer, which is why the strength on each of them is always the same.
    case spotlight(CGRect, SpotlightStyle)
    case text(box: CGRect, content: String, TextStyle)
    case callout(anchor: CGPoint, box: CGRect, content: String, TextStyle)
    case stepMarker(center: CGPoint, number: Int, FillStyle)
    /// A dimension line: two endpoints, drawn with end caps and a readout of the
    /// distance between them. The number is derived at draw time from the
    /// capture's pixels-per-point ratio, so it can never disagree with the line.
    case measure(from: CGPoint, to: CGPoint, StrokeStyle)
    /// A magnifier: a source circle over the detail, a lens circle showing it
    /// enlarged, and a connector between them. The magnification is the ratio of
    /// the two radii rather than a stored number of its own.
    case loupe(
        source: CGPoint, sourceRadius: CGFloat,
        lens: CGPoint, lensRadius: CGFloat,
        LoupeStyle
    )
    case fillRect(CGRect, FillStyle)
    case fillFreehand(points: [CGPoint], FillStyle)
    case blur(CGRect)
    case pixelate(CGRect)
}

extension Annotation {
    /// Whether holding Shift reshapes this kind mid-draw: true for the shapes
    /// defined entirely by their drag's two ends. A freehand stroke accumulates
    /// points and a loupe or callout tracks the cursor, so re-running the
    /// constraint on those would duplicate points or do nothing.
    var followsShiftConstraint: Bool {
        switch self {
        case .rectangle, .ellipse, .fillRect, .spotlight, .blur, .pixelate,
             .line, .arrow, .measure:
            return true
        case .freehand, .highlighter, .fillFreehand, .text, .callout,
             .stepMarker, .loupe:
            return false
        }
    }

    /// The tool that draws this kind. The style strip keys off it when a placed
    /// annotation takes the strip over from the active tool.
    var tool: Tool {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .freehand: return .pen
        case .highlighter: return .highlighter
        case .spotlight: return .spotlight
        case .text: return .text
        case .callout: return .callout
        case .stepMarker: return .stepMarker
        case .measure: return .measure
        case .loupe: return .loupe
        case .fillRect: return .fillRect
        case .fillFreehand: return .fillFreehand
        case .blur: return .blur
        case .pixelate: return .pixelate
        }
    }

    var style: AnnotationStyle {
        switch self {
        case let .freehand(_, style), let .highlighter(_, style), let .measure(_, _, style):
            return AnnotationStyle(color: style.color, lineWidth: style.lineWidth)
        case let .rectangle(_, style):
            return AnnotationStyle(
                color: style.color, lineWidth: style.lineWidth,
                fillMode: style.fillMode, fillColor: style.fillColor,
                cornerRadius: style.cornerRadius
            )
        case let .ellipse(_, style):
            return AnnotationStyle(
                color: style.color, lineWidth: style.lineWidth,
                fillMode: style.fillMode, fillColor: style.fillColor
            )
        case let .line(_, _, style):
            return AnnotationStyle(
                color: style.color, lineWidth: style.lineWidth, dash: style.dash
            )
        case let .arrow(_, _, style):
            return AnnotationStyle(
                color: style.color, lineWidth: style.lineWidth,
                dash: style.dash, arrowHead: style.arrowHead
            )
        case let .text(_, _, style), let .callout(_, _, _, style):
            return AnnotationStyle(
                color: style.color, fontSize: style.fontSize,
                fontFamily: style.fontFamily, bold: style.bold, italic: style.italic,
                underline: style.underline, strikethrough: style.strikethrough,
                alignment: style.alignment,
                backgroundColor: style.backgroundColor,
                outlineColor: style.outlineColor, outlineWidth: style.outlineWidth
            )
        case let .stepMarker(_, _, style), let .fillRect(_, style),
             let .fillFreehand(_, style):
            return AnnotationStyle(color: style.color)
        case let .spotlight(_, style):
            return AnnotationStyle(spotlightShape: style.shape, dimStrength: style.strength)
        case let .loupe(_, sourceRadius, _, lensRadius, style):
            return AnnotationStyle(
                color: style.outlineColor,
                magnification: LoupeGeometry.magnification(
                    sourceRadius: sourceRadius, lensRadius: lensRadius
                ),
                outlineVisible: style.outlineVisible
            )
        case .blur, .pixelate:
            return AnnotationStyle()
        }
    }

    /// Kinds that take a rotation handle. Stroke-path kinds already encode their
    /// direction in their geometry, and blur/pixelate crop an axis-aligned pixel
    /// region before filtering (ADR 0003), so neither rotates.
    var supportsRotation: Bool {
        switch self {
        case .rectangle, .ellipse, .fillRect, .text, .callout: return true
        default: return false
        }
    }

    /// Rotation about this annotation's own bounds centre, in radians, wrapped
    /// to [0, 2π) so a full turn compares equal to none. Always zero for the
    /// kinds that do not rotate.
    var rotation: CGFloat {
        switch self {
        case let .rectangle(_, style), let .ellipse(_, style):
            return style.rotation
        case let .fillRect(_, style):
            return style.rotation
        case let .text(_, _, style), let .callout(_, _, _, style):
            return style.rotation
        default:
            return 0
        }
    }

    /// A copy turned to `angle`; kinds that do not rotate come back unchanged.
    func rotated(to angle: CGFloat) -> Annotation {
        let angle = Annotation.wrappedAngle(angle)
        switch self {
        case .rectangle(let rect, var style):
            style.rotation = angle; return .rectangle(rect, style)
        case .ellipse(let rect, var style):
            style.rotation = angle; return .ellipse(rect, style)
        case .fillRect(let rect, var style):
            style.rotation = angle; return .fillRect(rect, style)
        case .text(let box, let content, var style):
            style.rotation = angle; return .text(box: box, content: content, style)
        case .callout(let anchor, let box, let content, var style):
            style.rotation = angle
            return .callout(anchor: anchor, box: box, content: content, style)
        default:
            return self
        }
    }

    static func wrappedAngle(_ angle: CGFloat) -> CGFloat {
        let turn = 2 * CGFloat.pi
        let wrapped = angle.truncatingRemainder(dividingBy: turn)
        return wrapped < 0 ? wrapped + turn : wrapped
    }

    /// A copy with `transform` applied to this annotation's style axes. Axes the
    /// kind does not carry are dropped, so setting a font size on a rectangle
    /// leaves it untouched.
    func applyingStyle(_ transform: (inout AnnotationStyle) -> Void) -> Annotation {
        var updated = style
        transform(&updated)
        switch self {
        case .rectangle(let rect, var style):
            style.apply(updated); return .rectangle(rect, style)
        case .ellipse(let rect, var style):
            style.apply(updated); return .ellipse(rect, style)
        case .line(let from, let to, var style):
            style.apply(updated); return .line(from: from, to: to, style)
        case .arrow(let from, let to, var style):
            style.apply(updated); return .arrow(from: from, to: to, style)
        case .freehand(let points, var style):
            style.apply(updated); return .freehand(points: points, style)
        case .highlighter(let points, var style):
            style.apply(updated); return .highlighter(points: points, style)
        case .spotlight(let rect, var style):
            style.apply(updated); return .spotlight(rect, style)
        case .text(let box, let content, var style):
            style.apply(updated); return .text(box: box, content: content, style)
        case .callout(let anchor, let box, let content, var style):
            style.apply(updated)
            return .callout(anchor: anchor, box: box, content: content, style)
        case .stepMarker(let center, let number, var style):
            style.apply(updated); return .stepMarker(center: center, number: number, style)
        case .measure(let from, let to, var style):
            style.apply(updated); return .measure(from: from, to: to, style)
        case .loupe(let source, let sourceRadius, let lens, let lensRadius, var style):
            style.apply(updated)
            // Setting a magnification holds the source and rescales the lens:
            // what the user asked to change is how hard it zooms, not how much
            // of the screen it is looking at.
            return .loupe(
                source: source, sourceRadius: sourceRadius, lens: lens,
                lensRadius: updated.magnification.map {
                    LoupeGeometry.lensRadius(sourceRadius: sourceRadius, magnification: $0)
                } ?? lensRadius,
                style
            )
        case .fillRect(let rect, var style):
            style.apply(updated); return .fillRect(rect, style)
        case .fillFreehand(let points, var style):
            style.apply(updated); return .fillFreehand(points: points, style)
        case .blur, .pixelate:
            return self
        }
    }
}

enum CalloutGeometry {
    static func font(for style: TextStyle) -> NSFont {
        TextLayout.font(for: style)
    }

    /// Bubble rect for a callout: the wrapped text box plus padding. The box is
    /// what the user sizes; the bubble follows it.
    static func bubbleRect(box: CGRect, content: String, style: TextStyle) -> CGRect {
        TextLayout.fittedBox(box, content: content, style: style)
            .insetBy(dx: -TextLayout.calloutPadding.width, dy: -TextLayout.calloutPadding.height)
    }
}

@MainActor
final class AnnotationRenderer {
    let source: CGImage
    let scale: CGFloat

    init(source: CGImage, scale: CGFloat) {
        self.source = source
        self.scale = scale
    }

    private lazy var ciContext: CIContext = CIContext(options: nil)

    /// The whole surface being drawn on, in view points. The overlay derives its
    /// scale from this same image, and the bake covers the frozen frame before
    /// cropping, so the two agree — only the 1×1 stand-in used before the frozen
    /// image arrives is degenerate, and nothing is worth reading then anyway.
    var renderArea: CGRect {
        CGRect(
            x: 0, y: 0,
            width: CGFloat(source.width) / scale,
            height: CGFloat(source.height) / scale
        )
    }

    func draw(_ annotation: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // One transform wrapped around the per-kind drawing below, so the
        // overlay and the bake share it and rotation reaches the saved image
        // without any kind knowing it was rotated.
        let angle = annotation.rotation
        if angle != 0 {
            let center = AnnotationGeometry.rotationCenter(of: annotation)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angle)
            ctx.translateBy(x: -center.x, y: -center.y)
        }

        switch annotation {
        case let .rectangle(rect, style):
            let radius = AnnotationGeometry.clampedCornerRadius(style.cornerRadius, in: rect)
            let path = radius > 0
                ? CGPath(
                    roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
                )
                : CGPath(rect: rect, transform: nil)
            paint(path, style: style, in: ctx)

        case let .ellipse(rect, style):
            paint(CGPath(ellipseIn: rect, transform: nil), style: style, in: ctx)

        case let .line(from, to, style):
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(style.lineWidth)
            ctx.setLineCap(.round)
            applyDash(style, over: hypot(to.x - from.x, to.y - from.y), in: ctx)
            ctx.beginPath()
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case let .arrow(from, to, style):
            drawArrow(from: from, to: to, style: style, in: ctx)

        case let .freehand(points, style):
            drawPolyline(points, style: style, in: ctx)

        case let .highlighter(points, style):
            drawPolyline(points, style: style, in: ctx)

        case let .text(box, content, style):
            drawText(content, in: box, style: style)

        case let .callout(anchor, box, content, style):
            drawCallout(anchor: anchor, box: box, content: content, style: style, in: ctx)

        case let .stepMarker(center, number, style):
            drawStepMarker(center: center, number: number, color: style.color, in: ctx)

        case let .measure(from, to, style):
            drawMeasure(from: from, to: to, style: style, in: ctx)

        case let .loupe(sourceCenter, sourceRadius, lensCenter, lensRadius, style):
            drawLoupe(
                sourceCenter: sourceCenter, sourceRadius: sourceRadius,
                lensCenter: lensCenter, lensRadius: lensRadius,
                style: style, in: ctx
            )

        case let .fillRect(rect, style):
            ctx.setFillColor(style.color.cgColor)
            ctx.fill(rect)

        case let .fillFreehand(points, style):
            guard points.count >= 3 else { return }
            ctx.setFillColor(style.color.cgColor)
            ctx.beginPath()
            ctx.move(to: points[0])
            for p in points.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.closePath()
            ctx.fillPath()

        case .spotlight:
            // Composed once for the whole list by `draw(_:in:dimmedWithin:)`;
            // there is nothing a single spotlight can draw by itself.
            break

        case let .blur(rect):
            drawBlur(rect)

        case let .pixelate(rect):
            drawPixelate(rect)
        }
    }

    /// Draws a whole annotation list in z-order, composing every spotlight into
    /// one dim layer over `area`. The layer lands at the position of the
    /// earliest spotlight, so annotations placed before it dim with the
    /// background and later ones draw on top at full brightness.
    func draw(_ annotations: [Annotation], in ctx: CGContext, dimmedWithin area: CGRect) {
        let spotlights: [(rect: CGRect, shape: SpotlightShape)] = annotations.compactMap {
            guard case let .spotlight(rect, style) = $0 else { return nil }
            return (rect, style.shape)
        }
        var strength: CGFloat = 0
        for case let .spotlight(_, style) in annotations {
            strength = style.strength
            break
        }
        let firstSpotlight = annotations.firstIndex {
            if case .spotlight = $0 { return true }
            return false
        }
        for (index, annotation) in annotations.enumerated() {
            if index == firstSpotlight {
                drawSpotlightDim(spotlights, strength: strength, within: area, in: ctx)
            }
            draw(annotation, in: ctx)
        }
    }

    private func drawSpotlightDim(
        _ spotlights: [(rect: CGRect, shape: SpotlightShape)],
        strength: CGFloat,
        within area: CGRect,
        in ctx: CGContext
    ) {
        guard let path = SpotlightGeometry.dimPath(area: area, spotlights: spotlights) else {
            return
        }
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(strength).cgColor)
        ctx.addPath(path)
        // Even-odd over a unioned bright region: the overlap of two spotlights
        // is inside that region exactly once, so it can never dim twice.
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// Pixel region of `source` (top-left origin) covered by a view-point rect,
    /// clamped to the image so a crop can never fall out of range.
    private func sourcePixelRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
    }

    /// Pixelate everything inside `rect`: crop that region out of the source,
    /// shrink it to a grid of cells (each cell averages its pixels), then blow it
    /// back up with nearest-neighbour sampling so every cell is a hard-edged block.
    private func drawPixelate(_ rect: CGRect) {
        let pixelRect = sourcePixelRect(for: rect)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = source.cropping(to: pixelRect)
        else { return }
        let blockPoints: CGFloat = 8
        let cols = max(1, Int((rect.width / blockPoints).rounded()))
        let rows = max(1, Int((rect.height / blockPoints).rounded()))
        guard let mosaic = resample(cropped, width: cols, height: rows) else { return }
        drawImage(mosaic, in: rect, crisp: true)
    }

    /// Blur everything inside `rect`: crop the region and Gaussian-blur just that
    /// slice, so no full-screen Core Image render (and its texture-size limits) is
    /// ever involved.
    private func drawBlur(_ rect: CGRect) {
        let pixelRect = sourcePixelRect(for: rect)
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = source.cropping(to: pixelRect),
              let filter = CIFilter(name: "CIGaussianBlur")
        else { return }
        let ciImage = CIImage(cgImage: cropped)
        // Clamp so the slice's own edges sample real pixels instead of darkening.
        filter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(8.0 * scale, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let blurred = ciContext.createCGImage(output, from: ciImage.extent)
        else { return }
        drawImage(blurred, in: rect, crisp: false)
    }

    private func resample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, crisp: Bool) {
        let nsImage = NSImage(cgImage: image, size: rect.size)
        let context = NSGraphicsContext.current
        let savedInterpolation = context?.imageInterpolation
        // Pixelation must keep crisp block edges; resampling would smear them.
        if crisp { context?.imageInterpolation = .none }
        nsImage.draw(in: rect)
        if crisp, let savedInterpolation { context?.imageInterpolation = savedInterpolation }
    }

    private func drawPolyline(
        _ points: [CGPoint],
        style: StrokeStyle,
        in ctx: CGContext
    ) {
        guard points.count >= 2 else { return }
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: points[0])
        for p in points.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.strokePath()
    }

    /// Speech bubble with a tail pointing at the anchor pixel (PRD §6.5.1).
    private func drawCallout(
        anchor: CGPoint,
        box: CGRect,
        content: String,
        style: TextStyle,
        in ctx: CGContext
    ) {
        let rect = CalloutGeometry.bubbleRect(box: box, content: content, style: style)

        // Tail: triangle from the bubble's edge to the anchor, skipped when the
        // anchor sits inside the bubble.
        if !rect.insetBy(dx: -2, dy: -2).contains(anchor) {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let dx = anchor.x - center.x
            let dy = anchor.y - center.y
            let length = max(1, hypot(dx, dy))
            let direction = CGPoint(x: dx / length, y: dy / length)
            // Ray from center toward the anchor, clipped to the bubble edge.
            var t = CGFloat.greatestFiniteMagnitude
            if direction.x != 0 {
                let edgeX = direction.x > 0 ? rect.maxX : rect.minX
                t = min(t, (edgeX - center.x) / direction.x)
            }
            if direction.y != 0 {
                let edgeY = direction.y > 0 ? rect.maxY : rect.minY
                t = min(t, (edgeY - center.y) / direction.y)
            }
            let base = CGPoint(x: center.x + direction.x * t, y: center.y + direction.y * t)
            let halfWidth = min(10, max(6, style.fontSize * 0.35))
            let perpendicular = CGPoint(x: -direction.y, y: direction.x)
            ctx.setFillColor(style.color.cgColor)
            ctx.beginPath()
            ctx.move(to: anchor)
            ctx.addLine(to: CGPoint(
                x: base.x + perpendicular.x * halfWidth,
                y: base.y + perpendicular.y * halfWidth
            ))
            ctx.addLine(to: CGPoint(
                x: base.x - perpendicular.x * halfWidth,
                y: base.y - perpendicular.y * halfWidth
            ))
            ctx.closePath()
            ctx.fillPath()
        }

        ctx.setFillColor(style.color.cgColor)
        let bubblePath = CGPath(
            roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil
        )
        ctx.addPath(bubblePath)
        ctx.fillPath()

        // The bubble is the plate, so a callout's own background would be
        // redundant; everything else about its typography is the same.
        var bubbleTextStyle = style
        bubbleTextStyle.color = .white
        bubbleTextStyle.backgroundColor = nil
        drawText(content, in: box, style: bubbleTextStyle, measuredWith: style)
    }

    /// Background plate, then the glyph outline, then the glyphs. Measuring can
    /// differ from drawing for a callout, whose bubble already sized itself
    /// from the annotation's real style.
    private func drawText(
        _ content: String,
        in box: CGRect,
        style: TextStyle,
        measuredWith measuringStyle: TextStyle? = nil
    ) {
        let fitted = TextLayout.fittedBox(
            box, content: content, style: measuringStyle ?? style
        )
        if let background = style.backgroundColor {
            background.setFill()
            fitted.insetBy(dx: -4, dy: -2).fill()
        }
        if let outlineAttributes = TextLayout.outlineAttributes(for: style) {
            NSAttributedString(string: content, attributes: outlineAttributes).draw(in: fitted)
        }
        TextLayout.attributed(content, style: style).draw(in: fitted)
    }

    private func drawStepMarker(
        center: CGPoint,
        number: Int,
        color: NSColor,
        in ctx: CGContext
    ) {
        let diameter: CGFloat = 28
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: rect)

        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: textRect, withAttributes: attrs)
    }

    /// A magnifier: the frozen image under the source circle, blown up into the
    /// lens circle, and then the chrome that says which is which.
    private func drawLoupe(
        sourceCenter: CGPoint,
        sourceRadius: CGFloat,
        lensCenter: CGPoint,
        lensRadius: CGFloat,
        style: LoupeStyle,
        in ctx: CGContext
    ) {
        let sourceBox = LoupeGeometry.box(center: sourceCenter, radius: sourceRadius)
        let lensBox = LoupeGeometry.box(center: lensCenter, radius: lensRadius)

        // Crop before scaling, never scale the whole display: the same
        // discipline ADR 0003 imposes on redaction, for the same reason.
        let pixelRect = sourcePixelRect(for: sourceBox)
        if pixelRect.width >= 1, pixelRect.height >= 1,
           let detail = source.cropping(to: pixelRect) {
            ctx.saveGState()
            ctx.addEllipse(in: lensBox)
            ctx.clip()
            let context = NSGraphicsContext.current
            let savedInterpolation = context?.imageInterpolation
            // A content magnifier, unlike the colour sampler's loupe, which
            // deliberately shows the pixel grid.
            context?.imageInterpolation = .high
            NSImage(cgImage: detail, size: lensBox.size).draw(in: lensBox)
            if let savedInterpolation { context?.imageInterpolation = savedInterpolation }
            ctx.restoreGState()
        }

        // The rings and the connector are one unit: either the loupe wears
        // chrome or it is only the magnified content.
        guard style.outlineVisible else { return }
        ctx.setStrokeColor(style.outlineColor.cgColor)
        ctx.setLineWidth(LoupeGeometry.outlineWidth)
        ctx.strokeEllipse(in: sourceBox)
        ctx.strokeEllipse(in: lensBox)
        if let (start, end) = LoupeGeometry.connector(
            source: sourceCenter, sourceRadius: sourceRadius,
            lens: lensCenter, lensRadius: lensRadius
        ) {
            ctx.beginPath()
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        }
    }

    /// A dimension line: the run itself, a tick across each endpoint, and the
    /// distance in a pill at the middle.
    private func drawMeasure(
        from: CGPoint,
        to: CGPoint,
        style: StrokeStyle,
        in ctx: CGContext
    ) {
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.butt)
        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: to)

        let length = max(1, hypot(to.x - from.x, to.y - from.y))
        let reach = MeasureGeometry.capReach(forLineWidth: style.lineWidth)
        let cap = CGPoint(
            x: -(to.y - from.y) / length * reach,
            y: (to.x - from.x) / length * reach
        )
        for end in [from, to] {
            ctx.move(to: CGPoint(x: end.x - cap.x, y: end.y - cap.y))
            ctx.addLine(to: CGPoint(x: end.x + cap.x, y: end.y + cap.y))
        }
        ctx.strokePath()

        drawReadout(from: from, to: to, style: style, in: ctx)
    }

    /// The measurement itself, screen-upright: no rotation is applied here, so a
    /// line drawn right-to-left or bottom-to-top still reads the same way up.
    private func drawReadout(
        from: CGPoint,
        to: CGPoint,
        style: StrokeStyle,
        in ctx: CGContext
    ) {
        let text = MeasureGeometry.readout(from: from, to: to, pixelScale: scale) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 7, height: 3)
        let pillSize = CGSize(
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        let center = MeasureGeometry.readoutCenter(
            from: from, to: to, size: pillSize, within: renderArea
        )
        let pill = CGRect(
            x: center.x - pillSize.width / 2, y: center.y - pillSize.height / 2,
            width: pillSize.width, height: pillSize.height
        )
        ctx.setFillColor(style.color.cgColor)
        ctx.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pillSize.height / 2, cornerHeight: pillSize.height / 2,
            transform: nil
        ))
        ctx.fillPath()
        text.draw(
            in: CGRect(
                x: pill.minX + padding.width, y: pill.minY + padding.height,
                width: textSize.width, height: textSize.height
            ),
            withAttributes: attributes
        )
    }

    /// Fill first, then stroke, so a stroke+fill shape keeps a crisp border
    /// over its own tint. Both read the same path, which is what makes a corner
    /// radius apply to the fill as well as the outline.
    private func paint(_ path: CGPath, style: StrokeStyle, in ctx: CGContext) {
        if style.fillMode.paintsFill {
            ctx.setFillColor(style.fillColor.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        if style.fillMode.paintsStroke {
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(style.lineWidth)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// The dash pattern is chosen from the path's own length, so a stroke never
    /// ends on a half dash however long or heavy it is.
    private func applyDash(_ style: StrokeStyle, over length: CGFloat, in ctx: CGContext) {
        let pattern = AnnotationGeometry.dashPattern(
            style.dash, length: length, lineWidth: style.lineWidth
        )
        guard !pattern.isEmpty else { return }
        ctx.setLineDash(phase: 0, lengths: pattern)
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        style: StrokeStyle,
        in ctx: CGContext
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12.0, style.lineWidth * 4.0)

        ctx.setStrokeColor(style.color.cgColor)
        ctx.setFillColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)

        // The shaft stops short of a filled head so the two do not overdraw;
        // an open head has nothing to hide behind, so the shaft runs the whole
        // way to the point.
        let pullback = headLength * 0.6
        let head = style.arrowHead
        let shaftEnd = head == .openV ? end : pointAlong(from: end, angle: angle, back: pullback)
        let shaftStart = head == .doubleEnded
            ? pointAlong(from: start, angle: angle + .pi, back: pullback)
            : start

        if head == .thick {
            drawTaperedShaft(from: shaftStart, to: shaftEnd, style: style, in: ctx)
        } else {
            ctx.saveGState()
            applyDash(
                style,
                over: hypot(shaftEnd.x - shaftStart.x, shaftEnd.y - shaftStart.y),
                in: ctx
            )
            ctx.beginPath()
            ctx.move(to: shaftStart)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.restoreGState()
        }

        switch head {
        case .standard, .thick:
            fillHead(at: end, angle: angle, length: headLength, in: ctx)
        case .doubleEnded:
            fillHead(at: end, angle: angle, length: headLength, in: ctx)
            fillHead(at: start, angle: angle + .pi, length: headLength, in: ctx)
        case .openV:
            strokeHead(at: end, angle: angle, length: headLength, in: ctx)
        case .tail:
            fillHead(at: end, angle: angle, length: headLength, in: ctx)
            // A flare at the origin: the same V, opened wider and stroked.
            strokeHead(
                at: start, angle: angle + .pi, length: headLength * 0.7,
                spread: .pi / 3, in: ctx
            )
        }
    }

    private func pointAlong(from point: CGPoint, angle: CGFloat, back: CGFloat) -> CGPoint {
        CGPoint(x: point.x - cos(angle) * back, y: point.y - sin(angle) * back)
    }

    /// The two barbs of a head, as points behind the tip.
    private func barbs(
        at tip: CGPoint, angle: CGFloat, length: CGFloat, spread: CGFloat
    ) -> (CGPoint, CGPoint) {
        (
            CGPoint(
                x: tip.x - length * cos(angle - spread),
                y: tip.y - length * sin(angle - spread)
            ),
            CGPoint(
                x: tip.x - length * cos(angle + spread),
                y: tip.y - length * sin(angle + spread)
            )
        )
    }

    private func fillHead(
        at tip: CGPoint, angle: CGFloat, length: CGFloat, in ctx: CGContext
    ) {
        let (left, right) = barbs(at: tip, angle: angle, length: length, spread: .pi / 6)
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
    }

    private func strokeHead(
        at tip: CGPoint, angle: CGFloat, length: CGFloat,
        spread: CGFloat = .pi / 6, in ctx: CGContext
    ) {
        let (left, right) = barbs(at: tip, angle: angle, length: length, spread: spread)
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.beginPath()
        ctx.move(to: left)
        ctx.addLine(to: tip)
        ctx.addLine(to: right)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A shaft that widens toward the head, so a heavy arrow reads as one solid
    /// banner rather than a thin stick with a big point on it.
    private func drawTaperedShaft(
        from start: CGPoint, to end: CGPoint, style: StrokeStyle, in ctx: CGContext
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
        let tailHalf = style.lineWidth * 0.35
        let headHalf = style.lineWidth * 1.25
        ctx.beginPath()
        ctx.move(to: CGPoint(
            x: start.x + perpendicular.x * tailHalf, y: start.y + perpendicular.y * tailHalf
        ))
        ctx.addLine(to: CGPoint(
            x: end.x + perpendicular.x * headHalf, y: end.y + perpendicular.y * headHalf
        ))
        ctx.addLine(to: CGPoint(
            x: end.x - perpendicular.x * headHalf, y: end.y - perpendicular.y * headHalf
        ))
        ctx.addLine(to: CGPoint(
            x: start.x - perpendicular.x * tailHalf, y: start.y - perpendicular.y * tailHalf
        ))
        ctx.closePath()
        ctx.fillPath()
    }
}
