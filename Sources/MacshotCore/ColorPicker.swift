import AppKit

/// The colour picker: standard swatches, the user's saved palette, a
/// saturation/brightness surface with a hue slider, and opacity. It edits one
/// colour, reports every intermediate value so the canvas previews live, and
/// brackets each drag so its owner records one undo entry per gesture.
///
/// Hue, saturation and brightness are kept as the panel's own state rather than
/// read back off the colour: a fully desaturated or black colour has no hue to
/// read, and dragging through one would otherwise lose where the user was.
final class ColorPickerPanelView: NSView {
    static let standardColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]
    static let paletteSlotCount = 6

    var onColorChanged: ((NSColor) -> Void)?
    var onPaletteChanged: (([NSColor]) -> Void)?
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    private(set) var palette: [NSColor]
    private var hue: CGFloat = 0
    private var saturation: CGFloat = 1
    private var brightness: CGFloat = 1
    private var alpha: CGFloat = 1

    private(set) var standardSwatches: [SwatchButton] = []
    private(set) var paletteSwatches: [SwatchButton] = []
    private let surface = SaturationBrightnessSurface()
    private let hueStrip = HueStrip()
    private let alphaStrip = AlphaStrip()
    private let addButton = PaletteAddButton()

    private let swatchSize: CGFloat = 18
    private let gap: CGFloat = 4
    private let pad: CGFloat = 10

    /// The colour the panel currently describes.
    var color: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    override var isFlipped: Bool { true }

    init(color: NSColor, palette: [NSColor]) {
        self.palette = palette
        let width = pad * 2 + CGFloat(Self.standardColors.count) * swatchSize
            + CGFloat(Self.standardColors.count - 1) * gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        wantsLayer = true
        GlassChrome.installBackdrop(in: self, radius: .large)

        for standard in Self.standardColors {
            let swatch = SwatchButton(color: standard)
            swatch.onClick = { [weak self] picked in self?.adopt(picked) }
            addSubview(swatch)
            standardSwatches.append(swatch)
        }
        addButton.onClick = { [weak self] in self?.savePalette() }
        addSubview(addButton)

        surface.onChange = { [weak self] saturation, brightness in
            guard let self else { return }
            self.saturation = saturation
            self.brightness = brightness
            self.publish()
        }
        hueStrip.onChange = { [weak self] hue in
            guard let self else { return }
            self.hue = hue
            self.surface.hue = hue
            self.refreshStrips()
            self.publish()
        }
        alphaStrip.onChange = { [weak self] alpha in
            guard let self else { return }
            self.alpha = alpha
            self.publish()
        }
        for control in [surface as ContinuousColorControl, hueStrip, alphaStrip] {
            control.onGestureBegan = { [weak self] in self?.onGestureBegan?() }
            control.onGestureEnded = { [weak self] in self?.onGestureEnded?() }
        }
        addSubview(surface)
        addSubview(hueStrip)
        addSubview(alphaStrip)

        setColor(color)
        layoutContents(width: width)
    }

    required init?(coder: NSCoder) { nil }

    /// Points the panel at a colour without reporting a change — used when it
    /// opens, and when the selection underneath it changes.
    func setColor(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Grey has no hue of its own; keep the one the user was last on.
        if s > 0 { hue = h }
        saturation = s
        brightness = b
        alpha = a
        surface.hue = hue
        surface.saturation = s
        surface.brightness = b
        hueStrip.fraction = hue
        refreshStrips()
        refreshSwatchStates()
    }

    func setPalette(_ palette: [NSColor]) {
        self.palette = palette
        layoutContents(width: frame.width)
    }

    private func publish() {
        refreshStrips()
        refreshSwatchStates()
        onColorChanged?(color)
    }

    private func adopt(_ picked: NSColor) {
        // A swatch carries its own opacity; picking one is a whole-colour
        // choice, not a hue choice with the current alpha kept.
        setColor(picked)
        onColorChanged?(color)
    }

    private func savePalette() {
        var updated = palette.filter { !$0.matchesColor(color) }
        updated.insert(color, at: 0)
        palette = Array(updated.prefix(Self.paletteSlotCount))
        layoutContents(width: frame.width)
        onPaletteChanged?(palette)
    }

    private func clearPaletteSlot(_ slot: NSColor) {
        palette.removeAll { $0.matchesColor(slot) }
        layoutContents(width: frame.width)
        onPaletteChanged?(palette)
    }

    private func refreshStrips() {
        alphaStrip.base = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        alphaStrip.fraction = alpha
        hueStrip.fraction = hue
        surface.saturation = saturation
        surface.brightness = brightness
    }

    private func refreshSwatchStates() {
        let current = color
        for swatch in standardSwatches + paletteSwatches {
            swatch.isActive = swatch.color.matchesColor(current)
        }
    }

    private func layoutContents(width: CGFloat) {
        for swatch in paletteSwatches { swatch.removeFromSuperview() }
        paletteSwatches = []
        for saved in palette {
            let swatch = SwatchButton(color: saved)
            swatch.toolTip = "Right-click to remove from the palette"
            swatch.onClick = { [weak self] picked in self?.adopt(picked) }
            swatch.onSecondaryClick = { [weak self] picked in self?.clearPaletteSlot(picked) }
            addSubview(swatch)
            paletteSwatches.append(swatch)
        }

        var y = pad
        place(row: standardSwatches, atY: y)
        y += swatchSize + gap * 2

        place(row: paletteSwatches + [addButton], atY: y)
        y += swatchSize + gap * 2

        let inner = width - pad * 2
        surface.frame = NSRect(x: pad, y: y, width: inner, height: 88)
        y += 88 + gap * 2
        hueStrip.frame = NSRect(x: pad, y: y, width: inner, height: 12)
        y += 12 + gap * 2
        alphaStrip.frame = NSRect(x: pad, y: y, width: inner, height: 12)
        y += 12 + pad

        frame.size = NSSize(width: width, height: y)
        refreshSwatchStates()
        needsDisplay = true
    }

    private func place(row: [NSView], atY y: CGFloat) {
        var x = pad
        for view in row {
            view.frame = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)
            x += swatchSize + gap
        }
    }
}

/// Shared mouse handling for the picker's drag surfaces: a press starts a
/// gesture, every move reports, and the release closes it.
class ContinuousColorControl: NSView {
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    override var isFlipped: Bool { true }

    func report(at point: CGPoint) {}

    override func mouseDown(with event: NSEvent) {
        onGestureBegan?()
        report(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        report(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        report(at: convert(event.locationInWindow, from: nil))
        onGestureEnded?()
    }

    func clamped(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    func drawMarker(at center: CGPoint, radius: CGFloat) {
        let ring = NSBezierPath(ovalIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        NSColor.white.setStroke()
        ring.lineWidth = 2
        ring.stroke()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let outer = NSBezierPath(ovalIn: CGRect(
            x: center.x - radius - 1, y: center.y - radius - 1,
            width: radius * 2 + 2, height: radius * 2 + 2
        ))
        outer.lineWidth = 1
        outer.stroke()
    }
}

/// Saturation left-to-right, brightness top-to-bottom, over the current hue.
final class SaturationBrightnessSurface: ContinuousColorControl {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 1 { didSet { needsDisplay = true } }
    var brightness: CGFloat = 1 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat, CGFloat) -> Void)?

    override func report(at point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        onChange?(
            clamped(point.x / bounds.width),
            clamped(1 - point.y / bounds.height)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let pure = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
        NSGradient(starting: .white, ending: pure)?.draw(in: bounds, angle: 0)
        NSGradient(
            starting: NSColor.black.withAlphaComponent(0), ending: .black
        )?.draw(in: bounds, angle: 90)
        drawMarker(
            at: CGPoint(x: saturation * bounds.width, y: (1 - brightness) * bounds.height),
            radius: 4
        )
    }
}

/// A horizontal strip whose fraction is picked by dragging across it.
class ColorStripControl: ContinuousColorControl {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat) -> Void)?

    override func report(at point: CGPoint) {
        guard bounds.width > 0 else { return }
        onChange?(clamped(point.x / bounds.width))
    }

    func drawTrack() {}

    override func draw(_ dirtyRect: NSRect) {
        drawTrack()
        drawMarker(at: CGPoint(x: fraction * bounds.width, y: bounds.midY), radius: 5)
    }
}

final class HueStrip: ColorStripControl {
    override func drawTrack() {
        let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
            NSColor(hue: CGFloat($0), saturation: 1, brightness: 1, alpha: 1)
        }
        NSGradient(colors: stops)?.draw(in: bounds, angle: 0)
    }
}

final class AlphaStrip: ColorStripControl {
    var base: NSColor = .systemRed { didSet { needsDisplay = true } }

    override func drawTrack() {
        drawCheckerboard(in: bounds, cell: 6)
        NSGradient(
            starting: base.withAlphaComponent(0), ending: base.withAlphaComponent(1)
        )?.draw(in: bounds, angle: 0)
    }
}

/// The transparency backdrop: without it a translucent colour reads as a light
/// solid one against the panel.
func drawCheckerboard(in rect: NSRect, cell: CGFloat) {
    NSColor.white.setFill()
    rect.fill()
    NSColor(white: 0.75, alpha: 1).setFill()
    var row = 0
    var y = rect.minY
    while y < rect.maxY {
        var x = rect.minX + (row.isMultiple(of: 2) ? 0 : cell)
        while x < rect.maxX {
            NSRect(x: x, y: y, width: cell, height: cell)
                .intersection(rect).fill()
            x += cell * 2
        }
        y += cell
        row += 1
    }
}

/// The tool-options row's colour control: shows the current colour over a
/// checkerboard so its opacity is visible, and opens the picker.
final class ColorWellButton: NSView {
    var onClick: (() -> Void)?
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    /// A swatch is pure colour with no label, so the tooltip is the only thing
    /// saying which colour it stands for.
    init(tooltip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = tooltip
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let well = bounds.insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: well).addClip()
        drawCheckerboard(in: well, cell: 5)
        color.setFill()
        well.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let ring = NSBezierPath(ovalIn: well)
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// A compact segmented picker for the tool-options row. Text titles rather than
/// symbols, because the options it stands for — dash patterns, arrow heads —
/// read better as little pictures of themselves than as SF Symbols.
final class SegmentedOptionControl: NSView {
    var onSelect: ((Int) -> Void)?

    private(set) var segments: [SegmentButton] = []
    private let segmentWidth: CGFloat = 26
    private let height: CGFloat = 20

    init(titles: [String], tooltips: [String]) {
        super.init(frame: .zero)
        for (index, title) in titles.enumerated() {
            let segment = SegmentButton(title: title)
            segment.toolTip = index < tooltips.count ? tooltips[index] : nil
            segment.onClick = { [weak self] in self?.onSelect?(index) }
            segment.frame = NSRect(
                x: CGFloat(index) * segmentWidth, y: 0,
                width: segmentWidth, height: height
            )
            addSubview(segment)
            segments.append(segment)
        }
        frame = NSRect(
            x: 0, y: 0, width: CGFloat(titles.count) * segmentWidth, height: height
        )
    }

    required init?(coder: NSCoder) { nil }

    var selectedIndex: Int = 0 {
        didSet {
            for (index, segment) in segments.enumerated() {
                segment.isActive = index == selectedIndex
            }
        }
    }
}

final class SegmentButton: NSView {
    var onClick: (() -> Void)?
    var isActive = false { didSet { updateAppearance() } }

    private let label: NSTextField

    init(title: String) {
        label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding + 4
        )
        addSubview(label)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 15) / 2, width: bounds.width, height: 15)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Layer colours are resolved CGColors, so they are re-resolved when the
    /// effective appearance changes rather than staying frozen at the value
    /// they had when the control was built.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let role: ChromeTintRole = isActive ? .active : .neutral
        layer?.backgroundColor = role.tintColor?.cgColor ?? NSColor.clear.cgColor
        label.textColor = isActive ? role.contentColor : .secondaryLabelColor
    }
}

/// An independent on/off in the options row — bold, italic and friends combine
/// rather than excluding each other, so they cannot be segments of one control.
final class ToggleOptionButton: NSView {
    var onToggle: ((Bool) -> Void)?
    var isOn = false { didSet { updateAppearance() } }

    private let label: NSTextField

    init(title: String, tooltip: String, italic: Bool = false) {
        label = NSTextField(labelWithString: title)
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.font = italic
            ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            : base
        label.alignment = .center
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding + 4
        )
        toolTip = tooltip
        addSubview(label)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }

    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4 } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onToggle?(!isOn)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Layer colours are resolved CGColors, so they are re-resolved when the
    /// effective appearance changes rather than staying frozen at the value
    /// they had when the control was built.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let role: ChromeTintRole = isOn ? .active : .neutral
        layer?.backgroundColor = role.tintColor?.cgColor ?? NSColor.clear.cgColor
        label.textColor = isOn ? role.contentColor : .secondaryLabelColor
    }
}

/// A one-shot action in the options row, as opposed to a style axis.
final class OptionActionButton: NSView {
    var onClick: (() -> Void)?

    private let label: NSTextField

    init(title: String, tooltip: String) {
        label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        // Wide enough for a word, still square for a single glyph.
        super.init(frame: NSRect(
            x: 0, y: 0, width: max(26, label.intrinsicContentSize.width + 14), height: 20
        ))
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding + 4
        )
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        toolTip = tooltip
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 15) / 2, width: bounds.width, height: 15)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The "save the current colour" slot at the end of the palette row.
final class PaletteAddButton: NSView {
    var onClick: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        toolTip = "Save the current colour to the palette"
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor.white.withAlphaComponent(0.5).setStroke()
        ring.lineWidth = 1
        ring.setLineDash([3, 2], count: 2, phase: 0)
        ring.stroke()

        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY))
        plus.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY))
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 4))
        plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 4))
        NSColor.white.setStroke()
        plus.lineWidth = 1.5
        plus.stroke()
    }
}

extension NSColor {
    /// Colours round-trip lossily through hex and colour spaces, so identity is
    /// a tolerance check rather than `==`.
    func matchesColor(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.deviceRGB),
              let b = other.usingColorSpace(.deviceRGB)
        else { return self == other }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
            && abs(a.alphaComponent - b.alphaComponent) < 0.02
    }
}
