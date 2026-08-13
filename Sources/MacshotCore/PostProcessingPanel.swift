import AppKit

/// A swatch standing for one backdrop style. Carries the style's identifier
/// rather than its colour, because the identifier is what persists.
final class BackdropSwatchButton: NSView {
    let styleID: String
    var isActive = false { didSet { updateAppearance() } }
    var onClick: ((String) -> Void)?

    private let swatch = NSView()

    init(style: BackdropStyle) {
        self.styleID = style.id
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding
        )
        swatch.frame = NSRect(x: 3, y: 3, width: 20, height: 20)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding + 3
        )
        swatch.layer?.backgroundColor = style.swatchColor.cgColor
        addSubview(swatch)
        toolTip = style.name
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onClick?(styleID) }

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
        layer?.borderWidth = isActive ? 2 : 0
        layer?.borderColor = (ChromeTintRole.active.tintColor ?? .controlAccentColor).cgColor
    }
}

/// The post-processing controls, in a small panel attached above the toolbar.
/// They live here rather than in the tool-options row because that row is
/// keyed to the active annotation tool and these controls belong to the image,
/// not to a tool.
final class PostProcessingPanelView: NSView {
    var onStyleSelected: ((String) -> Void)?
    var onPaddingChanged: ((CGFloat) -> Void)?
    var onCornerRadiusChanged: ((CGFloat) -> Void)?
    var onShadowSelected: ((ShadowIntensity) -> Void)?
    var onWindowFrameToggled: ((Bool) -> Void)?

    private var swatches: [BackdropSwatchButton] = []
    private let paddingSlider: OptionSlider
    let radiusSlider: OptionSlider
    private let shadowControl = SegmentedOptionControl(
        titles: ShadowIntensity.allCases.map(\.label),
        tooltips: ShadowIntensity.allCases.map(\.tooltip)
    )
    let windowFrameToggle = ToggleOptionButton(
        title: "◰", tooltip: "Draw a macOS window frame around the capture"
    )

    static let cornerRadiusRange: ClosedRange<CGFloat> = 0...48

    private let rowHeight: CGFloat = 30
    private let width: CGFloat = 320
    private let rows = 4

    init() {
        self.paddingSlider = OptionSlider(
            range: 0...0.25, format: { String(format: "Padding %.0f%%", $0 * 100) }
        )
        self.radiusSlider = OptionSlider(
            range: Self.cornerRadiusRange, format: { String(format: "Corners %.0f", $0) }
        )
        super.init(frame: .zero)
        frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows) * rowHeight + 8)
        wantsLayer = true
        GlassChrome.installBackdrop(in: self, radius: .large)

        var x: CGFloat = 10
        for style in Backdrops.all {
            let swatch = BackdropSwatchButton(style: style)
            swatch.onClick = { [weak self] id in self?.onStyleSelected?(id) }
            swatch.frame.origin = NSPoint(x: x, y: rowY(0) + 1)
            addSubview(swatch)
            swatches.append(swatch)
            x += swatch.frame.width + 4
        }

        paddingSlider.onChange = { [weak self] value in self?.onPaddingChanged?(value) }
        radiusSlider.onChange = { [weak self] value in self?.onCornerRadiusChanged?(value) }
        for (index, slider) in [paddingSlider, radiusSlider].enumerated() {
            slider.frame = NSRect(x: 10, y: rowY(index + 1) + 3, width: width - 20, height: 24)
            addSubview(slider)
        }

        shadowControl.onSelect = { [weak self] index in
            self?.onShadowSelected?(ShadowIntensity.allCases[index])
        }
        shadowControl.frame.origin = NSPoint(x: 10, y: rowY(3) + 3)
        addSubview(shadowControl)

        windowFrameToggle.onToggle = { [weak self] on in self?.onWindowFrameToggled?(on) }
        windowFrameToggle.frame.origin = NSPoint(
            x: shadowControl.frame.maxX + 10, y: rowY(3) + 3
        )
        addSubview(windowFrameToggle)
    }

    required init?(coder: NSCoder) { nil }

    /// Rows are stated top-down; the view is not flipped, so this is where that
    /// is turned around, once.
    private func rowY(_ index: Int) -> CGFloat {
        frame.height - 4 - CGFloat(index + 1) * rowHeight
    }

    func configure(_ settings: BeautifySettings) {
        for swatch in swatches { swatch.isActive = swatch.styleID == settings.styleID }
        paddingSlider.value = settings.paddingFraction
        radiusSlider.value = settings.cornerRadius
        shadowControl.selectedIndex =
            ShadowIntensity.allCases.firstIndex(of: settings.shadow) ?? 0
        windowFrameToggle.isOn = settings.windowFrame
        windowFrameToggle.toolTip = "Draw a macOS window frame around the capture"
    }
}

/// Brightness, contrast, saturation and sharpness, plus the presets and the
/// reset that write them. A preset is not an extra processing stage: it moves
/// these four sliders, so there is exactly one source of truth for effect state
/// and the user can see and tweak what a preset did.
final class EffectsPanelView: NSView {
    var onValuesChanged: ((EffectValues) -> Void)?

    private let brightness: OptionSlider
    private let contrast: OptionSlider
    private let saturation: OptionSlider
    private let sharpness: OptionSlider
    private var values = EffectValues.neutral
    private var presetButtons: [OptionActionButton] = []

    private let rowHeight: CGFloat = 28
    private let width: CGFloat = 320

    init() {
        brightness = OptionSlider(
            range: EffectValues.brightnessRange,
            format: { String(format: "Brightness %+.2f", $0) }
        )
        contrast = OptionSlider(
            range: EffectValues.contrastRange, format: { String(format: "Contrast %.2f", $0) }
        )
        saturation = OptionSlider(
            range: EffectValues.saturationRange, format: { String(format: "Saturation %.2f", $0) }
        )
        sharpness = OptionSlider(
            range: EffectValues.sharpnessRange, format: { String(format: "Sharpness %.2f", $0) }
        )
        super.init(frame: .zero)
        frame = NSRect(x: 0, y: 0, width: width, height: rowHeight * 5 + 8)
        wantsLayer = true
        GlassChrome.installBackdrop(in: self, radius: .large)

        brightness.onChange = { [weak self] value in self?.write { $0.brightness = value } }
        contrast.onChange = { [weak self] value in self?.write { $0.contrast = value } }
        saturation.onChange = { [weak self] value in self?.write { $0.saturation = value } }
        sharpness.onChange = { [weak self] value in self?.write { $0.sharpness = value } }
        for (index, slider) in [brightness, contrast, saturation, sharpness].enumerated() {
            slider.frame = NSRect(
                x: 10, y: frame.height - 4 - CGFloat(index + 1) * rowHeight,
                width: width - 20, height: 24
            )
            addSubview(slider)
        }

        var x: CGFloat = 10
        let presetRowY = frame.height - 4 - rowHeight * 5 + 2
        for preset in EffectPreset.all {
            let button = OptionActionButton(
                title: preset.name, tooltip: "Set the sliders to \(preset.name)"
            )
            button.onClick = { [weak self] in self?.apply(preset.values) }
            button.frame.origin = NSPoint(x: x, y: presetRowY)
            addSubview(button)
            presetButtons.append(button)
            x += button.frame.width + 4
        }
        let reset = OptionActionButton(title: "Reset", tooltip: "Back to the untouched capture")
        reset.onClick = { [weak self] in self?.apply(.neutral) }
        reset.frame.origin = NSPoint(x: x + 6, y: presetRowY)
        addSubview(reset)
    }

    /// A preset and the reset both do the same thing: write the four values and
    /// let the sliders show what happened.
    private func apply(_ newValues: EffectValues) {
        configure(newValues)
        onValuesChanged?(newValues)
    }

    required init?(coder: NSCoder) { nil }

    private func write(_ change: (inout EffectValues) -> Void) {
        change(&values)
        onValuesChanged?(values)
    }

    func configure(_ newValues: EffectValues) {
        values = newValues
        brightness.value = newValues.brightness
        contrast.value = newValues.contrast
        saturation.value = newValues.saturation
        sharpness.value = newValues.sharpness
    }
}
