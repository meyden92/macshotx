import AppKit

// MARK: - Picker view

final class RegionPickerView: NSView {
    var onCommit: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: Capture-overlay session hooks
    // All nil in the post-capture editor, where every overlay behaviour they
    // gate stays inert.

    /// A drag-selection commit was chosen; carries the selection rectangle.
    /// When set, `confirm()` routes here instead of baking locally, so the
    /// session can hold the commit while the frozen image is in flight.
    var onCommitRequested: ((NSRect) -> Void)?
    /// Selection activity: true when a gesture claims the selection, false
    /// when a gesture ends without one.
    var onSelectionActivity: ((Bool) -> Void)?
    var onTabPressed: (() -> Void)?
    var onFullscreenKey: (() -> Void)?
    /// A click with no drag while idle and snap is off.
    var onIdleClick: (() -> Void)?
    /// A click with no drag on a snap-highlighted window.
    var onSnapClick: ((WindowCandidate) -> Void)?
    /// Resolve the snap target for a pointer position (Cocoa global
    /// coordinates); returns the candidate plus its rect in this view's space.
    var onSnapHover: ((NSPoint) -> (candidate: WindowCandidate, rect: NSRect)?)?
    /// The pointer moved over this overlay — the session keys its window.
    var onPointerMoved: (() -> Void)?
    /// Content for the idle helper card; nil hides it.
    var helperCardContent: (() -> HelperCard.Content?)?
    /// The user chose a tool here — the session mirrors it everywhere else.
    var onToolChosen: ((Tool) -> Void)?

    private var frozen: CGImage?
    private var frozenImage: NSImage?
    private var scale: CGFloat
    /// When false (post-capture editor), Done without a selection exports the
    /// full image; the select tool acts as a crop (PRD §6.5.1).
    private let requiresSelection: Bool
    private let onStylesChanged: ((EditorStyles) -> Void)?
    /// Subject isolation, injected with a default. The only new injection point
    /// in the phase, and it exists so the "subject found" and "no subject"
    /// branches are testable without depending on how a model behaves against a
    /// synthetic bitmap.
    private let isolateSubject: SubjectIsolator
    private let onBeautifyDefaultsChanged: ((BeautifyDefaults) -> Void)?
    private var renderer: AnnotationRenderer

    /// 1×1 transparent stand-in so annotations render before the frozen
    /// screenshot arrives; blur/pixelate no-op against it by design.
    private static let clearPixel: CGImage = {
        let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }()

    private var currentTool: Tool = .select
    private var strokeStyle: StrokeStyle = .default
    private var highlighterStyle: StrokeStyle = .highlighter
    private var fillStyle: FillStyle = .redact
    private var textStyle: TextStyle = .default
    private var calloutStyle: TextStyle = .default
    private var markerColor: NSColor = .systemRed
    private var measureStyle = StrokeStyle(color: .systemRed, lineWidth: 2)
    private var loupeStyle = LoupeStyle.default
    private var loupeMagnification = LoupeGeometry.defaultMagnification
    private var spotlightStyle = SpotlightStyle.default

    private var selection: NSRect?
    /// Colour edges of the frozen screenshot, built in the background after
    /// presentation; nil until it arrives, so early gestures simply don't snap.
    var edgeIndex: EdgeIndex?
    /// The one in-flight Selection gesture; geometry lives in SelectionGeometry.
    private var selectionGesture: SelectionGesture?
    /// Rectangle the in-flight gesture currently produces (nil until the
    /// cursor has actually moved, so a bare click never creates a Selection).
    private var liveSelectionRect: NSRect?

    private var document = AnnotationDocument()
    /// The placed annotations as values. The overlay's own behaviour never
    /// reads this — it is the seam tests assert on when the thing under test is
    /// a value (an angle, a dash style) rather than a pixel.
    var annotations: [Annotation] { document.annotations }
    /// The armed auto-measure preview, if any — the same value seam as
    /// `annotations`, and for the same reason: what the preview shows is a
    /// value, and asserting on it beats synthesizing a screenshot of it.
    var autoMeasurePreview: Annotation? { autoMeasure?.preview }
    private var draftAnnotation: Annotation?
    private var dragStart: NSPoint?

    /// Armed auto-measure: the axis a held direction key asked for, plus the
    /// span currently under the cursor. The preview is the very annotation a
    /// click commits, so there is nothing for the two to disagree about.
    private var autoMeasure: (axis: MeasureGeometry.ScanAxis, preview: Annotation?)?
    /// One RGBA8 readback of the frozen image, built the first time a scan needs
    /// it and shared by every scan afterwards.
    private var scanPixels: PixelBuffer?
    /// Where the pointer was last seen over this overlay, so a scan armed by a
    /// key press knows what it is being pointed at.
    private var lastPointerPoint: CGPoint?
    /// The whole post-processing state of this capture. Beautify settings and
    /// effect values are deliberately not undo entries — they have their own
    /// toggle and their own reset, and a slider drag would otherwise flood the
    /// stack. Background removal is, because it is one destructive-looking act.
    private var composition: CompositionState
    /// The subject mask a background removal produced, in the crop's own pixels.
    private var subjectMask: CGImage?
    /// The composed preview, rebuilt only when the composition or the region it
    /// applies to changes — a slider drag would otherwise re-render the whole
    /// composition on every frame of every redraw.
    private var previewComposition: CGImage?
    private var postPanel: PostProcessingPanelView?
    /// Window snap's clean single-window image and the region it covers. When
    /// present, beautify composites it instead of the flat capture so the
    /// backdrop shows through the window's own rounded corners.
    private var windowCompanion: (image: CGImage, rect: NSRect)?
    /// Whether the effects controls are showing. The values themselves live in
    /// `composition`; this is only the panel's visibility.
    private var effectsPanelOpen = false
    private var effectsPanel: EffectsPanelView?
    /// The capture with its effects applied but no annotations, drawn over the
    /// Selection when beautify is off. Annotations then draw on top of it,
    /// which is the composition order without the beautify stages.
    private var effectedPreview: CGImage?
    /// The in-flight subject isolation, so cancelling the capture cancels it.
    private var isolationTask: Task<Void, Never>?
    private var isolationRunning = false

    /// What the loupe tool would place if the user clicked right now. Rendered
    /// through the same case as the committed annotation, so nothing changes
    /// appearance on mouse-up — and readable as a value, for the same reason
    /// `annotations` is.
    private(set) var hoverPreview: Annotation?

    private var editingTextField: InlineTextView?
    private var editingTextBox: CGRect?
    private var editingCalloutAnchor: CGPoint?
    /// Set while re-editing a placed annotation rather than typing a new one.
    private var editingAnnotationID: AnnotationDocument.ID?
    private var editingOriginalContent = ""

    /// The annotation being re-edited is hidden while its editor sits over it,
    /// so the old words do not show through the new ones.
    private var hiddenWhileEditing: AnnotationDocument.ID? { editingAnnotationID }

    /// The selected set, in z-order. Single selection is its one-element case;
    /// there is no separate code path for it.
    private var selectedIDs: [AnnotationDocument.ID] = []
    /// Handles, the rotation knob and the options row address exactly one
    /// annotation — a set of several has no single box to resize and no single
    /// style to show — so they go through this rather than the set.
    private var selectedID: AnnotationDocument.ID? {
        selectedIDs.count == 1 ? selectedIDs[0] : nil
    }
    /// In-flight annotation marquee (origin, current), select tool only.
    private var marquee: (origin: CGPoint, current: CGPoint)?
    /// How many times the current clipboard content has been dropped onto this
    /// overlay, so repeated pastes stagger rather than stack.
    private var pasteCascade = 0
    /// True while a tool-options slider is being dragged. The drag previews
    /// live and records exactly one undo entry, on release.
    private var styleGestureActive = false
    private var styleGestureOriginals: [AnnotationDocument.ID: Annotation] = [:]
    private var manipulationStart: CGPoint?
    /// Pre-drag snapshot of every annotation the gesture is moving, so the whole
    /// gesture records as one grouped step at mouse-up.
    private var manipulationOriginals: [AnnotationDocument.ID: Annotation] = [:]
    private var manipulationOriginal: Annotation? {
        selectedID.flatMap { manipulationOriginals[$0] }
    }
    private var resizingHandle: ResizeHandle?
    private var movingAnnotation: Bool = false
    /// Set while a drag has hold of one of a loupe's circles, which moves alone.
    private var movingLoupeCircle: LoupeCircle?
    private var rotatingAnnotation: Bool = false
    private let handleSize: CGFloat = 10
    /// The Selection moves by a band along its edges, not by its whole
    /// interior: the inside now belongs to the annotation marquee.
    private let selectionBorderBand: CGFloat = 8
    /// Size of the floating delete affordance beside a multi-selection.
    private let deleteAffordanceSize: CGFloat = 18

    private var toolbar: RegionToolbarView?
    private var tooltip: OverlayTooltipView?
    private var notice: OverlayTooltipView?
    private var deleteAffordance: NSView?
    private var selectingHint: OverlayTooltipView?
    private var resolutionBox: ResolutionBoxView?
    private var presetsPanel: PresetsPanelView?
    private var colorPicker: ColorPickerPanelView?
    private var colorPickerTarget: ColorTarget = .stroke
    /// App-level saved palette (not per-tool), persisted with the editor styles.
    private var customPalette: [NSColor] = []
    /// Mirrors the config setting that also suppresses the idle helper card.
    private let showOverlayHints: Bool
    private let onSelectionPrefsChanged: ((SelectionPrefs) -> Void)?
    /// Active aspect lock (width/height); nil is freeform. Persisted.
    private var aspectLockRatio: CGFloat?
    private var showSizesInPoints: Bool
    /// Armed exact size in points: the next gesture places this fixed frame.
    /// Consumed by the Selection it creates; never persisted.
    private var armedExactSize: CGSize?

    /// Window snap, session-owned and mirrored here for hit-testing/drawing.
    private(set) var snapArmed = false
    private var snapHighlight: (candidate: WindowCandidate, rect: NSRect)?
    private(set) var helperCard: OverlayHelperCardView?

    init(
        frame: NSRect,
        image: CGImage?,
        scale: CGFloat,
        styles: EditorStyles = EditorStyles(),
        onStylesChanged: ((EditorStyles) -> Void)? = nil,
        requiresSelection: Bool = true,
        showOverlayHints: Bool = true,
        selectionPrefs: SelectionPrefs = SelectionPrefs(),
        onSelectionPrefsChanged: ((SelectionPrefs) -> Void)? = nil,
        beautifyDefaults: BeautifyDefaults = BeautifyDefaults(),
        onBeautifyDefaultsChanged: ((BeautifyDefaults) -> Void)? = nil,
        isolateSubject: @escaping SubjectIsolator = SubjectIsolation.live
    ) {
        self.isolateSubject = isolateSubject
        self.onBeautifyDefaultsChanged = onBeautifyDefaultsChanged
        // The look is remembered; the toggle is not. Every capture starts plain
        // and every capture starts with the effect sliders neutral.
        self.composition = CompositionState(
            beautify: BeautifySettings(remembering: beautifyDefaults)
        )
        self.frozen = image
        self.frozenImage = image.map { NSImage(cgImage: $0, size: frame.size) }
        self.renderer = AnnotationRenderer(source: image ?? Self.clearPixel, scale: scale)
        self.scale = scale
        self.requiresSelection = requiresSelection
        self.showOverlayHints = showOverlayHints
        self.onStylesChanged = onStylesChanged
        self.onSelectionPrefsChanged = onSelectionPrefsChanged
        self.aspectLockRatio = selectionPrefs.aspectLockRatio > 0
            ? CGFloat(selectionPrefs.aspectLockRatio) : nil
        self.showSizesInPoints = selectionPrefs.showSizesInPoints
        super.init(frame: frame)
        loadStyles(styles)
        wantsLayer = true
        // The chrome floats over whatever is on screen, so following the system
        // appearance is the wrong reference: in Light Mode over a dark app the
        // glass samples near-black and .labelColor draws near-black on top of
        // it. Pin the chrome to a dark HUD instead — light content on a dark
        // surface reads over a dark backdrop and a light one alike. Every piece
        // of chrome is a subview of this view, so one appearance covers them.
        appearance = NSAppearance(named: .darkAqua)
        setupToolbar()
    }

    // MARK: Capture-overlay session surface

    /// No selection, no annotations, no draft, no active text edit — the
    /// state in which the helper card shows and `F` means fullscreen.
    var isIdle: Bool {
        selection == nil && liveSelectionRect == nil && selectionGesture == nil
            && document.placed.isEmpty && draftAnnotation == nil
            && editingTextField == nil && selectedIDs.isEmpty
    }

    /// The session avoids stealing key from an overlay mid-text-edit.
    var isEditingText: Bool { editingTextField != nil }

    var hasFrozenImage: Bool { frozen != nil }

    /// Installs a frozen screenshot that arrived after the overlay was
    /// presented, without disturbing an in-progress drag. The pixels-per-point
    /// ratio is derived from the capture rather than backingScaleFactor —
    /// they differ in scaled HiDPI display modes.
    func installFrozenImage(_ image: CGImage) {
        frozen = image
        frozenImage = NSImage(cgImage: image, size: bounds.size)
        if bounds.width > 0 { scale = CGFloat(image.width) / bounds.width }
        renderer = AnnotationRenderer(source: image, scale: scale)
        // A readback of the old image would scan the wrong pixels.
        scanPixels = nil
        needsDisplay = true
    }

    /// Bakes this display's annotations over its frozen image and crops to
    /// `rect` in view points (the whole surface when nil). Nil until the
    /// frozen image has been installed.
    func bakedImage(croppingTo rect: NSRect? = nil) -> CGImage? {
        bake(rect: rect ?? bounds)
    }

    /// Cross-display clearing: another display took the selection.
    func clearWholeSelection() {
        selectionGesture = nil
        liveSelectionRect = nil
        selection = nil
        layoutChrome()
        needsDisplay = true
    }

    func setSnapArmed(_ armed: Bool) {
        snapArmed = armed
        if armed {
            refreshSnapHighlightNow()
        } else {
            snapHighlight = nil
        }
        needsDisplay = true
    }

    /// Recomputes the highlight for the pointer's current position — needed
    /// when snap arms or the window list arrives while the pointer is still.
    func refreshSnapHighlightNow() {
        guard let window else { return }
        updateSnapHighlight(atWindowPoint: window.mouseLocationOutsideOfEventStream)
    }

    /// The session pushes a tool chosen on another display; must not
    /// re-broadcast.
    func adoptTool(_ tool: Tool) {
        guard currentTool != tool else { return }
        suppressToolBroadcast = true
        setTool(tool)
        suppressToolBroadcast = false
    }

    /// The session pushes style values edited on another display.
    func adoptStyles(_ styles: EditorStyles) {
        loadStyles(styles)
        refreshToolOptions()
    }

    private var suppressToolBroadcast = false

    /// A click that neither dragged nor did anything tool-meaningful. With
    /// snap armed it captures the window under the click; with snap off, an
    /// idle overlay captures its whole display (select tool only — a misclick
    /// with a drawing tool must not commit anything).
    private func handleBareClick(with event: NSEvent, allowsDisplayCapture: Bool) {
        guard requiresSelection else { return }
        if snapArmed {
            // Re-resolve at the click itself rather than trusting the hover
            // highlight — the pointer may not have moved since the window
            // list arrived, and snap clicks only exist before a selection.
            guard selection == nil, let onSnapHover, let window else { return }
            let global = window.convertPoint(toScreen: event.locationInWindow)
            if let (candidate, _) = onSnapHover(global) {
                onSnapClick?(candidate)
            }
            return
        }
        if allowsDisplayCapture, isIdle { onIdleClick?() }
    }

    // MARK: Idle helper card

    override func viewWillDraw() {
        refreshHelperCard()
        super.viewWillDraw()
    }

    private func refreshHelperCard() {
        guard let content = isIdle ? helperCardContent?() : nil else {
            helperCard?.removeFromSuperview()
            helperCard = nil
            return
        }
        if helperCard?.content != content {
            helperCard?.removeFromSuperview()
            let card = OverlayHelperCardView(content: content)
            addSubview(card)
            helperCard = card
        }
        if let card = helperCard {
            let centered = NSPoint(
                x: (bounds.width - card.frame.width) / 2,
                y: (bounds.height - card.frame.height) / 2
            )
            if card.frame.origin != centered { card.setFrameOrigin(centered) }
        }
    }

    // MARK: Style persistence (PRD §6.5.1: styles persist per-tool)

    private func loadStyles(_ styles: EditorStyles) {
        strokeStyle = StrokeStyle(
            color: NSColor(hexString: styles.strokeColorHex) ?? .systemRed,
            lineWidth: styles.strokeLineWidth,
            dash: DashStyle(rawValue: styles.strokeDashStyle) ?? .solid,
            arrowHead: ArrowHead(rawValue: styles.arrowHeadStyle) ?? .standard,
            fillMode: FillMode(rawValue: styles.shapeFillMode) ?? .strokeOnly,
            fillColor: NSColor(hexString: styles.shapeFillColorHex)
                ?? NSColor.systemRed.withAlphaComponent(0.3),
            cornerRadius: styles.rectangleCornerRadius
        )
        let highlighterColor = NSColor(hexString: styles.highlighterColorHex) ?? .systemYellow
        highlighterStyle = StrokeStyle(
            // A stored six-digit value predates user-controlled opacity, so it
            // still means "the built-in highlighter look".
            color: NSColor.hexStringCarriesAlpha(styles.highlighterColorHex)
                ? highlighterColor
                : highlighterColor.withAlphaComponent(0.35),
            lineWidth: styles.highlighterLineWidth
        )
        textStyle = TextStyle(
            color: NSColor(hexString: styles.textColorHex) ?? .systemRed,
            fontSize: styles.textFontSize
        ).withRichDefaults(styles.textRichDefaults)
        calloutStyle = TextStyle(
            color: NSColor(hexString: styles.calloutColorHex) ?? .systemRed,
            fontSize: styles.calloutFontSize
        ).withRichDefaults(styles.calloutRichDefaults)
        fillStyle = FillStyle(color: NSColor(hexString: styles.fillColorHex) ?? .black)
        markerColor = NSColor(hexString: styles.stepMarkerColorHex) ?? .systemRed
        measureStyle = StrokeStyle(
            color: NSColor(hexString: styles.measureColorHex) ?? .systemRed,
            lineWidth: styles.measureLineWidth
        )
        loupeStyle = LoupeStyle(
            outlineColor: NSColor(hexString: styles.loupeOutlineColorHex) ?? .white,
            outlineVisible: styles.loupeOutlineVisible
        )
        loupeMagnification = styles.loupeMagnification
        spotlightStyle = SpotlightStyle(
            shape: SpotlightShape(rawValue: styles.spotlightShape) ?? .rectangle,
            strength: styles.spotlightDimStrength
        )
        customPalette = styles.customPaletteHex.compactMap { NSColor(hexString: $0) }
    }

    private func persistStyles() {
        guard let onStylesChanged else { return }
        var styles = EditorStyles()
        styles.strokeColorHex = strokeStyle.color.hexRGBAString
        styles.strokeLineWidth = strokeStyle.lineWidth
        styles.highlighterColorHex = highlighterStyle.color.hexRGBAString
        styles.highlighterLineWidth = highlighterStyle.lineWidth
        styles.textColorHex = textStyle.color.hexRGBAString
        styles.textFontSize = textStyle.fontSize
        styles.calloutColorHex = calloutStyle.color.hexRGBAString
        styles.calloutFontSize = calloutStyle.fontSize
        styles.fillColorHex = fillStyle.color.hexRGBAString
        styles.stepMarkerColorHex = markerColor.hexRGBAString
        styles.measureColorHex = measureStyle.color.hexRGBAString
        styles.measureLineWidth = measureStyle.lineWidth
        styles.loupeOutlineColorHex = loupeStyle.outlineColor.hexRGBAString
        styles.loupeOutlineVisible = loupeStyle.outlineVisible
        styles.loupeMagnification = loupeMagnification
        styles.spotlightShape = spotlightStyle.shape.rawValue
        styles.spotlightDimStrength = spotlightStyle.strength
        styles.customPaletteHex = customPalette.map(\.hexRGBAString)
        styles.strokeDashStyle = strokeStyle.dash.rawValue
        styles.arrowHeadStyle = strokeStyle.arrowHead.rawValue
        styles.shapeFillMode = strokeStyle.fillMode.rawValue
        styles.shapeFillColorHex = strokeStyle.fillColor.hexRGBAString
        styles.rectangleCornerRadius = strokeStyle.cornerRadius
        styles.textRichDefaults = textStyle.richDefaults
        styles.calloutRichDefaults = calloutStyle.richDefaults
        onStylesChanged(styles)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    /// The capture overlay may be presented before macshot is active; the
    /// first click must start a drag, not just activate the app. The
    /// detached editor keeps the standard click-to-focus behaviour.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { requiresSelection }

    private func setupToolbar() {
        let toolbar = RegionToolbarView(tools: Tool.allCases)
        toolbar.onToolSelected = { [weak self] tool in self?.setTool(tool) }
        toolbar.onPostProcessingToggled = { [weak self] control in
            self?.togglePostProcessing(control)
        }
        toolbar.onDone = { [weak self] in self?.confirm() }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
        toolbar.onColorWellClicked = { [weak self] in self?.toggleColorPicker(target: .stroke) }
        toolbar.onLineWidthSelected = { [weak self] width in self?.applyLineWidth(width) }
        toolbar.onDashSelected = { [weak self] dash in self?.applyDash(dash) }
        toolbar.onArrowHeadSelected = { [weak self] head in self?.applyArrowHead(head) }
        toolbar.onFlip = { [weak self] in self?.flipSelected() }
        toolbar.onFillModeSelected = { [weak self] mode in self?.applyFillMode(mode) }
        toolbar.onFillColorWellClicked = { [weak self] in self?.toggleColorPicker(target: .fill) }
        toolbar.onCornerRadiusSelected = { [weak self] radius in self?.applyCornerRadius(radius) }
        toolbar.onFontFamilySelected = { [weak self] family in self?.applyTextStyle { $0.fontFamily = family } }
        toolbar.onTraitToggled = { [weak self] trait, on in
            self?.applyTextStyle { trait.write(on, into: &$0) }
        }
        toolbar.onAlignmentSelected = { [weak self] alignment in
            self?.applyTextStyle { $0.alignment = alignment }
        }
        toolbar.onTextBackgroundToggled = { [weak self] on in
            self?.applyTextStyle { $0.backgroundColor = .some(on ? Self.defaultTextBackground : nil) }
        }
        toolbar.onTextOutlineToggled = { [weak self] on in
            self?.applyTextStyle { $0.outlineColor = .some(on ? Self.defaultTextOutline : nil) }
        }
        toolbar.onTextBackgroundWellClicked = { [weak self] in
            self?.toggleColorPicker(target: .textBackground)
        }
        toolbar.onTextOutlineWellClicked = { [weak self] in
            self?.toggleColorPicker(target: .textOutline)
        }
        toolbar.onFontSizeSelected = { [weak self] size in self?.applyFontSize(size) }
        toolbar.onMagnificationSelected = { [weak self] value in self?.applyMagnification(value) }
        toolbar.onSpotlightShapeSelected = { [weak self] shape in self?.applySpotlightShape(shape) }
        toolbar.onDimStrengthSelected = { [weak self] value in self?.applyDimStrength(value) }
        toolbar.onOutlineVisibilityToggled = { [weak self] on in
            self?.applyOutlineVisibility(on)
        }
        toolbar.onStyleGestureBegan = { [weak self] in self?.beginStyleGesture() }
        toolbar.onStyleGestureEnded = { [weak self] in self?.endStyleGesture() }

        let x = (bounds.width - toolbar.frame.width) / 2
        toolbar.frame.origin = NSPoint(x: x, y: 24)
        toolbar.onButtonHover = { [weak self] text, buttonFrame in
            self?.showTooltip(text, near: buttonFrame)
        }
        addSubview(toolbar)
        self.toolbar = toolbar
        toolbar.setCurrent(.select)
        refreshToolOptions()

        let hint = OverlayTooltipView(
            text: "Space to move · Shift for square · Option to ignore edges"
        )
        hint.isHidden = true
        addSubview(hint)
        selectingHint = hint

        let box = ResolutionBoxView()
        box.isHidden = true
        box.onSizeCommitted = { [weak self] width, height in
            self?.commitTypedSize(width: width, height: height)
        }
        box.onUnitToggled = { [weak self] in
            guard let self else { return }
            self.showSizesInPoints.toggle()
            self.persistSelectionPrefs()
            self.refreshResolutionBox()
        }
        box.onPresetsTapped = { [weak self] in self?.togglePresetsPanel() }
        box.onEditingChanged = { [weak self] editing in
            // Re-placement was deferred while a field held focus.
            if !editing { self?.layoutChrome() }
        }
        addSubview(box)
        resolutionBox = box
        layoutChrome()
    }

    // MARK: Chrome placement

    /// Positions the tool strip and the selecting-state hint around the
    /// Selection via the pure placement solver. In the capture overlay the
    /// strip hides while no Selection exists; the post-capture editor keeps
    /// its fixed strip so annotating without a crop still works.
    private func layoutChrome() {
        guard let toolbar else { return }
        let activeSelection = liveSelectionRect ?? selection
        if requiresSelection {
            toolbar.isHidden = (activeSelection == nil)
        }
        let hintVisible = showOverlayHints && selectionGesture != nil && liveSelectionRect != nil
        selectingHint?.isHidden = !hintVisible
        refreshResolutionBox()

        guard let activeSelection else {
            let fixed = NSPoint(x: (bounds.width - toolbar.frame.width) / 2, y: 24)
            if toolbar.frame.origin != fixed { toolbar.setFrameOrigin(fixed) }
            if let box = resolutionBox, !box.isEditing {
                let corner = NSPoint(
                    x: bounds.maxX - box.frame.width - ChromePlacement.margin,
                    y: safeAreaTopInset + ChromePlacement.margin
                )
                if box.frame.origin != corner { box.setFrameOrigin(corner) }
            }
            return
        }
        // The box holds still while one of its fields has focus.
        let boxPlaceable = resolutionBox.map { !$0.isHidden && !$0.isEditing } ?? false
        let placed = ChromePlacement.solve(
            bounds: bounds,
            safeAreaTop: safeAreaTopInset,
            selection: activeSelection,
            boxes: .init(
                toolStrip: toolbar.isHidden ? nil : toolbar.frame.size,
                resolutionBox: boxPlaceable ? resolutionBox?.frame.size : nil,
                hint: hintVisible ? selectingHint?.frame.size : nil
            )
        )
        if let rect = placed.toolStrip, toolbar.frame.origin != rect.origin {
            toolbar.setFrameOrigin(rect.origin)
        }
        if let rect = placed.resolutionBox, let box = resolutionBox,
           box.frame.origin != rect.origin {
            box.setFrameOrigin(rect.origin)
        }
        if let rect = placed.hint, let hint = selectingHint, hint.frame.origin != rect.origin {
            hint.setFrameOrigin(rect.origin)
        }
    }

    // MARK: Resolution box

    /// The aspect locks the presets panel offers, also used to name the lock
    /// the box shows.
    private static let aspectPresets: [(String, CGFloat?)] = [
        ("Freeform", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5),
        ("16:10", 1.6), ("16:9", 16.0 / 9), ("21:9", 21.0 / 9), ("9:16", 9.0 / 16)
    ]

    /// The preset row the armed lock corresponds to: "Freeform" when there is
    /// no lock, the named ratio when one matches, nil for a Custom ratio.
    private var activePresetTitle: String? {
        guard let ratio = aspectLockRatio else { return "Freeform" }
        return Self.aspectPresets.first { _, preset in
            preset.map { abs($0 - ratio) < 0.0005 } ?? false
        }?.0
    }

    /// What the box shows for the armed lock; nil while freeform.
    private var aspectLockLabel: String? {
        guard let ratio = aspectLockRatio else { return nil }
        return activePresetTitle ?? String(format: "%.2f:1", ratio)
    }

    private func refreshResolutionBox() {
        guard let box = resolutionBox else { return }
        box.isHidden = false
        let unit = showSizesInPoints ? "pt" : "px"
        let lock = aspectLockLabel
        guard let active = liveSelectionRect ?? selection else {
            // Still reachable with no Selection, so presets can be armed.
            box.displayEmpty(unit: unit, lock: lock)
            return
        }
        let factor = showSizesInPoints ? 1 : scale
        box.display(
            width: Int((active.width * factor).rounded()),
            height: Int((active.height * factor).rounded()),
            unit: unit,
            lock: lock
        )
    }

    private func persistSelectionPrefs() {
        var prefs = SelectionPrefs()
        prefs.aspectLockRatio = Double(aspectLockRatio ?? 0)
        prefs.showSizesInPoints = showSizesInPoints
        onSelectionPrefsChanged?(prefs)
    }

    /// A committed field resizes the Selection about its own centre; under a
    /// lock the other dimension is derived.
    private func commitTypedSize(width: Double?, height: Double?) {
        guard let current = selection else { return }
        let factor = showSizesInPoints ? 1 : scale
        var newWidth = current.width
        var newHeight = current.height
        if let width {
            newWidth = width / factor
            if let ratio = aspectLockRatio { newHeight = newWidth / ratio }
        }
        if let height {
            newHeight = height / factor
            if let ratio = aspectLockRatio { newWidth = newHeight * ratio }
        }
        selection = SelectionGeometry.resizedAboutCenter(
            current,
            to: CGSize(width: newWidth, height: newHeight),
            ratio: aspectLockRatio,
            in: bounds
        )
        layoutChrome()
        needsDisplay = true
    }

    private func togglePresetsPanel() {
        if let panel = presetsPanel {
            panel.removeFromSuperview()
            presetsPanel = nil
            return
        }
        let sizes: [(String, CGSize)] = [
            ("1920×1080", CGSize(width: 1920, height: 1080)),
            ("1280×720", CGSize(width: 1280, height: 720)),
            ("1080×1080", CGSize(width: 1080, height: 1080)),
            ("1080×1920", CGSize(width: 1080, height: 1920)),
            ("800×600", CGSize(width: 800, height: 600)),
            ("640×480", CGSize(width: 640, height: 480))
        ]
        let active = activePresetTitle
        var entries: [PresetsPanelView.Entry] = Self.aspectPresets.map { title, ratio in
            .init(title: title, isActive: title == active) { [weak self] in
                self?.pickPreset { $0.applyAspectLock(ratio) }
            }
        }
        entries.append(.init(title: "Custom", isActive: active == nil) { [weak self] in
            self?.pickPreset { picker in
                guard let current = picker.selection, current.height > 0 else { return }
                picker.applyAspectLock(current.width / current.height)
            }
        })
        entries += sizes.map { title, size in
            .init(title: title) { [weak self] in self?.pickPreset { $0.applyExactSize(size) } }
        }
        let panel = PresetsPanelView(entries: entries)
        var origin = NSPoint(
            x: resolutionBox?.frame.minX ?? 0,
            y: (resolutionBox?.frame.maxY ?? 0) + 4
        )
        origin.x = min(max(origin.x, 8), bounds.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, 8), bounds.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
        addSubview(panel)
        presetsPanel = panel
    }

    private func pickPreset(_ apply: (RegionPickerView) -> Void) {
        presetsPanel?.removeFromSuperview()
        presetsPanel = nil
        apply(self)
    }

    private func applyAspectLock(_ ratio: CGFloat?) {
        aspectLockRatio = ratio
        persistSelectionPrefs()
        if let ratio, let current = selection {
            selection = SelectionGeometry.resizedAboutCenter(
                current,
                to: CGSize(width: current.width, height: current.width / ratio),
                ratio: ratio,
                in: bounds
            )
        }
        layoutChrome()
        needsDisplay = true
    }

    /// Exact sizes are always device pixels regardless of the unit toggle.
    private func applyExactSize(_ pixels: CGSize) {
        let size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        if let current = selection {
            selection = SelectionGeometry.resizedAboutCenter(
                current, to: size,
                ratio: size.height > 0 ? size.width / size.height : nil,
                in: bounds
            )
            layoutChrome()
            needsDisplay = true
        } else {
            armedExactSize = size
        }
    }

    private var safeAreaTopInset: CGFloat {
        guard requiresSelection, let screen = window?.screen else { return 0 }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(screen.safeAreaInsets.top, menuBar)
    }

    private func showTooltip(_ text: String?, near buttonFrameInToolbar: NSRect) {
        tooltip?.removeFromSuperview()
        tooltip = nil
        guard let text, let toolbar else { return }
        let buttonFrame = convert(buttonFrameInToolbar, from: toolbar)
        let tip = OverlayTooltipView(text: text)
        var origin = NSPoint(
            x: buttonFrame.midX - tip.frame.width / 2,
            y: buttonFrame.minY - 6 - tip.frame.height
        )
        // Above the button; below when the display edge would clip it.
        if origin.y < ChromePlacement.margin {
            origin.y = buttonFrame.maxY + 6
        }
        origin.x = min(
            max(origin.x, ChromePlacement.margin),
            bounds.maxX - tip.frame.width - ChromePlacement.margin
        )
        tip.setFrameOrigin(origin)
        addSubview(tip)
        tooltip = tip
    }

    private func setTool(_ tool: Tool) {
        // Whatever was being typed is committed rather than abandoned: the
        // words are the user's work, the tool switch is not a cancel.
        commitTextEditing()
        currentTool = tool
        toolbar?.setCurrent(tool)
        draftAnnotation = nil
        dragStart = nil
        disarmAutoMeasure()
        clearHoverPreview()
        selectionGesture = nil
        liveSelectionRect = nil
        clearSelection()
        refreshToolOptions()
        layoutChrome()
        needsDisplay = true
        // Switching tools kills an in-flight gesture; tell the session so a
        // claimed-but-never-committed selection doesn't stay latched.
        onSelectionActivity?(selection != nil)
        if !suppressToolBroadcast { onToolChosen?(tool) }
    }

    private func refreshToolOptions() {
        // A control being dragged owns its own value; rewriting the row
        // mid-drag would fight the cursor.
        guard !styleGestureActive else { return }
        // A selected placed element takes over the row so it can be restyled
        // in place; otherwise the row reflects the active tool's defaults.
        let selected = selectedAnnotations
        if let first = selected.first {
            // A set shows what all of its members have in common; the values
            // come off the first, which is what a restyle would overwrite.
            let options = selected.dropFirst().reduce(first.options) {
                $0.intersection($1.options)
            }
            var style = first.style
            // The dim strength is not any one annotation's: every spotlight
            // carries the same value, and the row edits it for all of them.
            if style.dimStrength != nil { style.dimStrength = spotlightStyle.strength }
            toolbar?.configureToolOptions(options: options, style: style)
            if let color = style.color { colorPicker?.setColor(color) }
            return
        }
        if let color = currentColor(for: currentTool) { colorPicker?.setColor(color) }
        restyleOpenEditor()
        toolbar?.configureToolOptions(
            options: currentTool.options, style: currentToolStyle
        )
    }

    /// A continuous control is being dragged: live values preview straight onto
    /// the annotation and the whole drag is recorded once, on release.
    private func beginStyleGesture() {
        styleGestureActive = true
        styleGestureOriginals = [:]
        for id in selectedIDs {
            styleGestureOriginals[id] = document.annotation(for: id)
        }
    }

    private func endStyleGesture() {
        styleGestureActive = false
        if styleGestureOriginals.isEmpty {
            // Nothing selected means the drag moved the tool's own default.
            persistStyles()
        } else {
            document.beginGroup()
            for (id, before) in styleGestureOriginals {
                document.commitChange(id, from: before)
            }
            document.endGroup()
        }
        styleGestureOriginals = [:]
        refreshToolOptions()
    }

    // MARK: Post-processing

    /// Whether the confirmed image can carry transparency: an isolated subject
    /// with no backdrop behind it. State, not a pixel scan.
    var mayContainTransparency: Bool { composition.mayContainTransparency }

    /// The mask belongs to one crop, so the crop stops moving while it is
    /// applied. Undoing the removal unlocks it again.
    var isSelectionLocked: Bool { composition.backgroundRemoved }

    /// True while the beautify preview owns the overlay. The capture is
    /// read-only then: annotating into a scaled, offset composition would mean
    /// inverse-transforming every event for a flow — draw, then dress up, then
    /// confirm — that does not need it.
    var isBeautifying: Bool { composition.beautify.enabled }

    /// Installs Window snap's shadow-free companion image for a region. Only
    /// beautify consumes it: with beautify off the flat capture is still what a
    /// window capture produces, exactly as before.
    func setWindowCompanion(_ image: CGImage?, for rect: NSRect) {
        windowCompanion = image.map { (image: $0, rect: rect) }
        invalidateComposition()
        postPanel?.configure(composition.beautify, carriesOwnFrame: windowCompanion != nil)
    }

    /// True when the source carries its own corners and title bar, so the
    /// compositor must not add either.
    private func companionSource(for rect: NSRect) -> CGImage? {
        guard composition.beautify.enabled, let windowCompanion,
              windowCompanion.rect == rect
        else { return nil }
        return windowCompanion.image
    }

    /// What post-processing applies to: the Selection, or — in the detached
    /// editor, where no crop means the whole image — everything.
    private var postProcessingRect: NSRect? {
        if let selection { return selection }
        return requiresSelection ? nil : bounds
    }

    private func togglePostProcessing(_ control: PostProcessingControl) {
        switch control {
        case .beautify:
            composition.beautify.enabled.toggle()
            if composition.beautify.enabled {
                commitTextEditing()
                clearSelection()
                closeColorPicker()
            }
        case .effects:
            effectsPanelOpen.toggle()
        case .removeBackground:
            removeBackground()
            return
        }
        refreshPostProcessing()
    }

    /// Rebuilds everything the composition state drives: the panel, the toolbar
    /// state, the cached preview and the display.
    private func refreshPostProcessing() {
        invalidateComposition()
        toolbar?.setPostProcessing(.beautify, active: composition.beautify.enabled)
        toolbar?.setPostProcessing(.effects, active: effectsPanelOpen)
        toolbar?.setPostProcessing(
            .removeBackground, active: isolationRunning || composition.backgroundRemoved
        )
        toolbar?.setToolsDisabled(
            isBeautifying ? "Turn Beautify off to keep editing" : nil
        )
        if composition.beautify.enabled {
            showPostPanel()
        } else {
            postPanel?.removeFromSuperview()
            postPanel = nil
        }
        if effectsPanelOpen {
            showEffectsPanel()
        } else {
            effectsPanel?.removeFromSuperview()
            effectsPanel = nil
        }
        layoutChrome()
        needsDisplay = true
    }

    private func invalidateComposition() {
        previewComposition = nil
        effectedPreview = nil
    }

    /// A control moved: re-compose and redraw, without rebuilding the panel
    /// underneath the cursor that is still on the control.
    private func redrawComposition() {
        invalidateComposition()
        persistBeautifyDefaults()
        needsDisplay = true
    }

    private func persistBeautifyDefaults() {
        onBeautifyDefaultsChanged?(composition.beautify.remembered)
    }

    private func showPostPanel() {
        if postPanel == nil {
            let panel = PostProcessingPanelView()
            panel.onStyleSelected = { [weak self] id in
                self?.composition.beautify.styleID = id
                self?.persistBeautifyDefaults()
                self?.refreshPostProcessing()
            }
            panel.onPaddingChanged = { [weak self] value in
                self?.composition.beautify.paddingFraction = value
                self?.redrawComposition()
            }
            panel.onCornerRadiusChanged = { [weak self] value in
                self?.composition.beautify.cornerRadius = value
                self?.redrawComposition()
            }
            panel.onShadowSelected = { [weak self] shadow in
                self?.composition.beautify.shadow = shadow
                self?.redrawComposition()
            }
            panel.onWindowFrameToggled = { [weak self] on in
                self?.composition.beautify.windowFrame = on
                self?.redrawComposition()
            }
            addSubview(panel)
            postPanel = panel
        }
        postPanel?.configure(
            composition.beautify, carriesOwnFrame: windowCompanion != nil
        )
        positionPostPanel()
    }

    private func showEffectsPanel() {
        if effectsPanel == nil {
            let panel = EffectsPanelView()
            panel.onValuesChanged = { [weak self] values in
                self?.composition.effects = values
                self?.redrawComposition()
            }
            addSubview(panel)
            effectsPanel = panel
        }
        effectsPanel?.configure(composition.effects)
        positionPostPanel()
    }

    /// The panels stack upward from the toolbar, so both can be open at once.
    private func positionPostPanel() {
        var top = toolbar?.frame.minY ?? bounds.midY
        for panel in [postPanel, effectsPanel].compactMap({ $0 }) {
            var origin = NSPoint(
                x: (toolbar?.frame.midX ?? bounds.midX) - panel.frame.width / 2,
                y: top - panel.frame.height - 6
            )
            origin.x = min(max(origin.x, 8), bounds.maxX - panel.frame.width - 8)
            origin.y = min(max(origin.y, 8), bounds.maxY - panel.frame.height - 8)
            panel.setFrameOrigin(origin)
            top = origin.y
        }
    }

    /// One click, one undo entry, one Vision call. The mask is computed for one
    /// specific crop, which is why the Selection locks while it is applied:
    /// letting the crop change afterwards would either re-run Vision on every
    /// drag or leave a stale mask revealing background as the Selection grows.
    private func removeBackground() {
        guard !isolationRunning, !composition.backgroundRemoved,
              let rect = postProcessingRect,
              let source = captureImage(
                rect: rect, previewBound: SubjectIsolation.workingSize, includeAnnotations: false
              )
        else { return }
        isolationRunning = true
        refreshPostProcessing()
        let isolate = isolateSubject
        isolationTask = Task { [weak self] in
            let mask = await isolate(source)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finishBackgroundRemoval(mask: mask) }
        }
    }

    private func finishBackgroundRemoval(mask: CGImage?) {
        isolationRunning = false
        isolationTask = nil
        guard let mask else {
            // A failed attempt costs nothing: no state change, just a notice.
            showNotice("No subject found in this capture")
            refreshPostProcessing()
            return
        }
        subjectMask = mask
        document.setBackgroundRemoved(true)
        composition.backgroundRemoved = true
        refreshPostProcessing()
    }

    private func cancelBackgroundRemoval() {
        isolationTask?.cancel()
        isolationTask = nil
        isolationRunning = false
    }

    /// A short, non-blocking notice in the overlay chrome, on the same chip the
    /// selecting-state hint uses.
    private func showNotice(_ text: String) {
        notice?.removeFromSuperview()
        let chip = OverlayTooltipView(text: text)
        chip.setFrameOrigin(NSPoint(
            x: (bounds.width - chip.frame.width) / 2,
            y: (toolbar?.frame.maxY ?? bounds.midY) + 8
        ))
        addSubview(chip)
        notice = chip
        Task { [weak self, weak chip] in
            try? await Task.sleep(for: .seconds(3))
            guard let chip, self?.notice === chip else { return }
            chip.removeFromSuperview()
            self?.notice = nil
        }
    }

    /// True when the capture pixels themselves differ from the frozen screen,
    /// so the preview has to show them rather than the screen underneath.
    private var isTransformingCapture: Bool {
        !composition.effects.isNeutral || composition.backgroundRemoved
    }

    private func effectedCapturePreview() -> CGImage? {
        if let effectedPreview { return effectedPreview }
        guard let rect = postProcessingRect, rect.width >= 1, rect.height >= 1 else { return nil }
        let image = captureImage(rect: rect, previewBound: 1400, includeAnnotations: false)
        effectedPreview = image
        return image
    }

    /// The composed preview, rendered through the same compositor the bake uses
    /// — only the pixel scale differs, which is what makes the compositor's own
    /// tests a statement about what is on screen here.
    private func composedPreview() -> CGImage? {
        if let previewComposition { return previewComposition }
        guard let rect = postProcessingRect, rect.width >= 1, rect.height >= 1,
              let capture = captureImage(rect: rect, previewBound: 1400)
        else { return nil }
        let previewScale = CGFloat(capture.width) / rect.width
        let image = PostProcessingCompositor.render(
            capture, settings: beautifySettings(for: rect), scale: previewScale
        )
        previewComposition = image
        return image
    }

    /// Where the composition sits on screen: anchored on the Selection at 1:1
    /// when the whole canvas fits there, and otherwise shrunk uniformly and
    /// centred so a near-fullscreen Selection does not push its backdrop off
    /// the display.
    private func previewPlacement(canvas: CGSize, selection: NSRect) -> NSRect {
        let layout = PostProcessingCompositor.layout(
            captureSize: CGSize(width: selection.width, height: selection.height),
            settings: composition.beautify, scale: 1
        )
        let anchored = NSRect(
            x: selection.minX - layout.capture.minX,
            y: selection.minY - layout.capture.minY,
            width: canvas.width, height: canvas.height
        )
        if bounds.contains(anchored) { return anchored }
        let margin: CGFloat = 24
        let factor = min(
            1,
            min(
                (bounds.width - margin * 2) / canvas.width,
                (bounds.height - margin * 2) / canvas.height
            )
        )
        let size = CGSize(width: canvas.width * factor, height: canvas.height * factor)
        return NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    private func drawBeautifyPreview() {
        // The Selection's own dimming cutout, border and handles are gone: what
        // is on screen is the composition and nothing else.
        NSColor.black.withAlphaComponent(0.55).setFill()
        bounds.fill()
        guard let rect = postProcessingRect, let composed = composedPreview() else { return }
        let canvas = CGSize(
            width: CGFloat(composed.width) / scale, height: CGFloat(composed.height) / scale
        )
        // The preview may have been composed from a downscaled capture, so the
        // canvas is stated in the Selection's own points rather than the
        // preview image's pixels.
        let layout = PostProcessingCompositor.layout(
            captureSize: CGSize(width: rect.width, height: rect.height),
            settings: composition.beautify, scale: 1
        )
        _ = canvas
        let placement = previewPlacement(canvas: layout.canvas, selection: rect)
        NSImage(cgImage: composed, size: placement.size).draw(in: placement)
    }

    // MARK: Colour picker

    /// Which colour well the open picker is editing. A shape has two, and a
    /// text annotation has three.
    enum ColorTarget { case stroke, fill, textBackground, textOutline }

    static let defaultTextBackground = NSColor.white.withAlphaComponent(0.85)
    static let defaultTextOutline = NSColor.black

    /// The colour the picker should open on: the selected annotation's, or the
    /// active tool's default when nothing is selected.
    private var pickerColor: NSColor {
        let style = selectedAnnotations.first?.style ?? currentToolStyle
        switch colorPickerTarget {
        case .stroke: return style.color ?? .systemRed
        case .fill: return style.fillColor ?? strokeStyle.fillColor
        case .textBackground: return (style.backgroundColor ?? nil) ?? Self.defaultTextBackground
        case .textOutline: return (style.outlineColor ?? nil) ?? Self.defaultTextOutline
        }
    }

    private func toggleColorPicker(target: ColorTarget = .stroke) {
        if colorPicker != nil, colorPickerTarget == target {
            closeColorPicker()
            return
        }
        closeColorPicker()
        colorPickerTarget = target
        let panel = ColorPickerPanelView(color: pickerColor, palette: customPalette)
        panel.onColorChanged = { [weak self] color in self?.applyColor(color) }
        panel.onGestureBegan = { [weak self] in self?.beginStyleGesture() }
        panel.onGestureEnded = { [weak self] in self?.endStyleGesture() }
        panel.onPaletteChanged = { [weak self] palette in
            self?.customPalette = palette
            self?.persistStyles()
        }
        // Anchored above the toolbar's options row, kept on the overlay.
        var origin = NSPoint(
            x: (toolbar?.frame.midX ?? bounds.midX) - panel.frame.width / 2,
            y: (toolbar?.frame.minY ?? bounds.midY) - panel.frame.height - 6
        )
        origin.x = min(max(origin.x, 8), bounds.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, 8), bounds.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
        addSubview(panel)
        colorPicker = panel
    }

    private func closeColorPicker() {
        colorPicker?.removeFromSuperview()
        colorPicker = nil
    }

    /// The active tool's defaults as the same composed value a placed
    /// annotation reports, so the row is fed one shape either way.
    private var currentToolStyle: AnnotationStyle {
        let text = currentTool == .callout ? calloutStyle : textStyle
        return AnnotationStyle(
            color: currentColor(for: currentTool),
            lineWidth: currentLineWidth(for: currentTool),
            fontSize: currentFontSize(for: currentTool),
            dash: strokeStyle.dash,
            arrowHead: strokeStyle.arrowHead,
            fillMode: strokeStyle.fillMode,
            fillColor: strokeStyle.fillColor,
            cornerRadius: strokeStyle.cornerRadius,
            fontFamily: text.fontFamily,
            bold: text.bold,
            italic: text.italic,
            underline: text.underline,
            strikethrough: text.strikethrough,
            alignment: text.alignment,
            backgroundColor: .some(text.backgroundColor),
            outlineColor: .some(text.outlineColor),
            outlineWidth: text.outlineWidth,
            magnification: loupeMagnification,
            outlineVisible: loupeStyle.outlineVisible,
            spotlightShape: spotlightStyle.shape,
            dimStrength: spotlightStyle.strength
        )
    }

    private func currentColor(for tool: Tool) -> NSColor? {
        switch tool {
        case .rectangle, .ellipse, .line, .arrow, .pen: return strokeStyle.color
        case .highlighter: return highlighterStyle.color
        case .text: return textStyle.color
        case .callout: return calloutStyle.color
        case .stepMarker: return markerColor
        case .measure: return measureStyle.color
        case .loupe: return loupeStyle.outlineColor
        case .spotlight: return nil
        case .fillRect, .fillFreehand: return fillStyle.color
        case .select, .blur, .pixelate: return nil
        }
    }

    private func currentLineWidth(for tool: Tool) -> CGFloat? {
        switch tool {
        case .rectangle, .ellipse, .line, .arrow, .pen: return strokeStyle.lineWidth
        case .highlighter: return highlighterStyle.lineWidth
        case .measure: return measureStyle.lineWidth
        default: return nil
        }
    }

    private func currentFontSize(for tool: Tool) -> CGFloat? {
        switch tool {
        case .text: return textStyle.fontSize
        case .callout: return calloutStyle.fontSize
        default: return nil
        }
    }

    /// Applies a style change to the selected placed element, if any. Returns
    /// false when nothing is selected so the caller can fall back to the tool
    /// defaults.
    private func restyleSelected(_ transform: (Annotation) -> Annotation) -> Bool {
        guard !selectedIDs.isEmpty else { return false }
        // A restyle across the set is one grouped step, so undoing it takes the
        // whole thing back rather than one annotation at a time.
        document.beginGroup()
        for id in selectedIDs {
            guard let current = document.annotation(for: id) else { continue }
            let updated = transform(current)
            // Mid-drag values are previews; endStyleGesture records the drag.
            if styleGestureActive {
                document.updateLive(id, to: updated)
            } else {
                document.replace(id, with: updated)
            }
        }
        document.endGroup()
        refreshToolOptions()
        needsDisplay = true
        return true
    }

    private func applyColor(_ color: NSColor) {
        switch colorPickerTarget {
        case .fill:
            applyFillColor(color)
            return
        case .textBackground:
            applyTextStyle { $0.backgroundColor = .some(color) }
            return
        case .textOutline:
            applyTextStyle { $0.outlineColor = .some(color) }
            return
        case .stroke:
            break
        }
        if restyleSelected({ $0.applyingStyle { style in style.color = color } }) { return }
        switch currentTool {
        case .rectangle, .ellipse, .line, .arrow, .pen:
            strokeStyle.color = color
        case .highlighter:
            // Transparency is part of the colour now, so the highlighter takes
            // whatever alpha the picker gave it.
            highlighterStyle.color = color
        case .text:
            textStyle.color = color
        case .callout:
            calloutStyle.color = color
        case .stepMarker:
            markerColor = color
        case .measure:
            measureStyle.color = color
        case .loupe, .spotlight:
            return
        case .fillRect, .fillFreehand:
            fillStyle.color = color
        case .select, .blur, .pixelate:
            return
        }
        persistStyles()
        refreshToolOptions()
    }

    private func applyLineWidth(_ width: CGFloat) {
        if restyleSelected({ $0.applyingStyle { style in style.lineWidth = width } }) { return }
        switch currentTool {
        case .rectangle, .ellipse, .line, .arrow, .pen:
            strokeStyle.lineWidth = width
        case .highlighter:
            highlighterStyle.lineWidth = width
        case .measure:
            measureStyle.lineWidth = width
        default:
            return
        }
        // A drag persists once, at its end, instead of on every tick.
        if !styleGestureActive { persistStyles() }
        refreshToolOptions()
    }

    private func applyFontSize(_ size: CGFloat) {
        if restyleSelected({ $0.applyingStyle { style in style.fontSize = size } }) { return }
        switch currentTool {
        case .text:
            textStyle.fontSize = size
        case .callout:
            calloutStyle.fontSize = size
        default:
            return
        }
        if !styleGestureActive { persistStyles() }
        refreshToolOptions()
    }

    /// One path for every typography axis: it either restyles the selected
    /// annotation or moves the active text tool's default.
    private func applyTextStyle(_ transform: (inout AnnotationStyle) -> Void) {
        if restyleSelected({ $0.applyingStyle(transform) }) { return }
        var style = AnnotationStyle()
        transform(&style)
        switch currentTool {
        case .text: textStyle.apply(style)
        case .callout: calloutStyle.apply(style)
        default: return
        }
        if !styleGestureActive { persistStyles() }
        refreshToolOptions()
    }

    private func applyFillColor(_ color: NSColor) {
        if restyleSelected({ $0.applyingStyle { style in style.fillColor = color } }) { return }
        guard currentTool == .rectangle || currentTool == .ellipse else { return }
        strokeStyle.fillColor = color
        if !styleGestureActive { persistStyles() }
        refreshToolOptions()
    }

    private func applyFillMode(_ mode: FillMode) {
        if restyleSelected({ $0.applyingStyle { style in style.fillMode = mode } }) { return }
        guard currentTool == .rectangle || currentTool == .ellipse else { return }
        strokeStyle.fillMode = mode
        persistStyles()
        refreshToolOptions()
    }

    private func applyCornerRadius(_ radius: CGFloat) {
        if restyleSelected({ $0.applyingStyle { style in style.cornerRadius = radius } }) { return }
        guard currentTool == .rectangle else { return }
        strokeStyle.cornerRadius = radius
        if !styleGestureActive { persistStyles() }
        refreshToolOptions()
    }

    /// With a loupe selected this rescales its lens; with nothing selected it
    /// sets what the next placement will use.
    private func applyMagnification(_ value: CGFloat) {
        if restyleSelected({ $0.applyingStyle { style in style.magnification = value } }) { return }
        guard currentTool == .loupe else { return }
        loupeMagnification = value
        if !styleGestureActive { persistStyles() }
        refreshToolOptions()
    }

    private func applyOutlineVisibility(_ visible: Bool) {
        if restyleSelected({ $0.applyingStyle { style in style.outlineVisible = visible } }) {
            return
        }
        guard currentTool == .loupe else { return }
        loupeStyle.outlineVisible = visible
        persistStyles()
        refreshToolOptions()
    }

    private func applySpotlightShape(_ shape: SpotlightShape) {
        if restyleSelected({ $0.applyingStyle { style in style.spotlightShape = shape } }) {
            return
        }
        guard currentTool == .spotlight else { return }
        spotlightStyle.shape = shape
        persistStyles()
        refreshToolOptions()
    }

    /// One composed layer can only have one opacity, so this writes the strength
    /// to every spotlight at once — as a single undoable step — rather than to
    /// whichever one happens to be selected. It also moves the tool's default,
    /// so the next spotlight matches the ones already placed.
    private func applyDimStrength(_ strength: CGFloat) {
        spotlightStyle.strength = strength
        let spotlights = document.placed.filter {
            if case .spotlight = $0.annotation { return true }
            return false
        }
        if !spotlights.isEmpty {
            document.beginGroup()
            for placed in spotlights {
                guard let current = document.annotation(for: placed.id) else { continue }
                let updated = current.applyingStyle { $0.dimStrength = strength }
                if styleGestureActive {
                    document.updateLive(placed.id, to: updated)
                } else {
                    document.replace(placed.id, with: updated)
                }
            }
            document.endGroup()
        }
        if !styleGestureActive { persistStyles() }
        refreshToolOptions()
        needsDisplay = true
    }

    private func applyDash(_ dash: DashStyle) {
        if restyleSelected({ $0.applyingStyle { style in style.dash = dash } }) { return }
        guard currentTool == .line || currentTool == .arrow else { return }
        strokeStyle.dash = dash
        persistStyles()
        refreshToolOptions()
    }

    private func applyArrowHead(_ head: ArrowHead) {
        if restyleSelected({ $0.applyingStyle { style in style.arrowHead = head } }) { return }
        guard currentTool == .arrow else { return }
        strokeStyle.arrowHead = head
        persistStyles()
        refreshToolOptions()
    }

    /// Flip is an action on a placed arrow, not a default: with nothing
    /// selected there is no direction to swap.
    private func flipSelected() {
        _ = restyleSelected { AnnotationGeometry.flipped($0) }
    }

    private func clearSelection() {
        let hadSelection = !selectedIDs.isEmpty
        selectedIDs = []
        marquee = nil
        resizingHandle = nil
        movingAnnotation = false
        movingLoupeCircle = nil
        rotatingAnnotation = false
        manipulationStart = nil
        manipulationOriginals = [:]
        if hadSelection { refreshToolOptions() }
    }

    /// The selected set as values, in z-order.
    private var selectedAnnotations: [Annotation] {
        selectedIDs.compactMap { document.annotation(for: $0) }
    }

    /// The combined outline drawn around the selected set, and the region a drag
    /// grabs to move the whole set.
    private var selectedSetBounds: CGRect? {
        AnnotationGeometry.combinedBounds(of: selectedAnnotations)?.insetBy(dx: -3, dy: -3)
    }

    /// The floating delete affordance, offered only for a set of several — the
    /// keyboard and the toolbar already cover a single selection.
    private var deleteAffordanceRect: CGRect? {
        guard selectedIDs.count > 1, let bounds = selectedSetBounds else { return nil }
        // Kept on the overlay, so a set against the top or right edge still has
        // a reachable affordance.
        return CGRect(
            x: min(bounds.maxX + 6, self.bounds.maxX - deleteAffordanceSize - 2),
            y: max(self.bounds.minY + 2, bounds.minY - deleteAffordanceSize - 6),
            width: deleteAffordanceSize,
            height: deleteAffordanceSize
        )
    }

    private var marqueeRect: CGRect? {
        guard let marquee else { return nil }
        return CGRect(
            x: min(marquee.origin.x, marquee.current.x),
            y: min(marquee.origin.y, marquee.current.y),
            width: abs(marquee.current.x - marquee.origin.x),
            height: abs(marquee.current.y - marquee.origin.y)
        )
    }

    /// Live membership while the marquee is dragged: everything it touches, in
    /// z-order.
    private func selectMarqueedAnnotations() {
        guard let rect = marqueeRect else { return }
        let hits = AnnotationGeometry.indices(in: document.annotations, touching: rect)
        selectedIDs = hits.map { document.placed[$0].id }
        refreshToolOptions()
    }

    /// Snapshots what a manipulation is about to change, so mouse-up can record
    /// the whole gesture against where it started.
    private func beginManipulation(at point: CGPoint, of ids: [AnnotationDocument.ID]) {
        manipulationStart = point
        manipulationOriginals = [:]
        for id in ids {
            manipulationOriginals[id] = document.annotation(for: id)
        }
        needsDisplay = true
    }

    /// Records a finished manipulation. A multi-annotation gesture lands as one
    /// grouped step; a gesture that ended where it started records nothing.
    private func commitManipulation() {
        document.beginGroup()
        for id in selectedIDs {
            if let original = manipulationOriginals[id] {
                document.commitChange(id, from: original)
            }
        }
        document.endGroup()
    }

    // MARK: Duplicate, copy and paste

    /// Cmd+C. An empty set is a no-op: copying the capture itself belongs to
    /// the pipeline, not to this.
    private func copySelection() {
        guard !selectedIDs.isEmpty else { return }
        AnnotationClipboard.write(selectedAnnotations, to: .general)
        // The next paste starts the cascade over, next to what was copied.
        pasteCascade = 0
    }

    private func pasteAnnotations() {
        guard let pasted = AnnotationClipboard.read(from: .general) else { return }
        place(pasted)
    }

    private func duplicateSelection() {
        guard !selectedIDs.isEmpty else { return }
        place(selectedAnnotations)
    }

    /// Drops a set onto the canvas offset from where it came from, cascading so
    /// repeated pastes stagger instead of stacking, as one undo entry however
    /// many annotations it created. They arrive selected, ready to be dragged.
    private func place(_ annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        pasteCascade += 1
        let landed = AnnotationGeometry.offset(
            annotations, steps: pasteCascade, within: bounds
        )
        document.beginGroup()
        let ids = landed.map { document.insert($0) }
        document.endGroup()
        selectedIDs = ids
        refreshToolOptions()
        needsDisplay = true
    }

    /// Removes the whole selected set as one undo step.
    private func deleteSelection() {
        guard !selectedIDs.isEmpty else { return }
        document.beginGroup()
        for id in selectedIDs { document.remove(id) }
        document.endGroup()
        clearSelection()
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // The beautify preview is a review mode: the capture is read-only until
        // the toggle goes off again.
        guard !isBeautifying else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastPointerPoint = point
        clearHoverPreview()
        // A click on the overlay itself is a click outside the picker and
        // outside any open editor; both would have swallowed their own.
        closeColorPicker()
        commitTextEditing()

        // A click while auto-measure is armed commits what the preview showed,
        // and stays armed: the key is still held, so the user can sweep on and
        // take another span.
        if let preview = autoMeasure?.preview {
            document.insert(preview)
            needsDisplay = true
            return
        }

        // An armed fixed-size frame follows the cursor; the click (or the end
        // of a drag) commits it in place at mouse-up.
        if case .placingFixedSize? = selectionGesture?.kind {
            updateSelectionGesture(at: point)
            return
        }

        // Anchored mode: a left-click commits the Selection where it stands.
        if case .anchored? = selectionGesture?.kind {
            if let rect = liveSelectionRect {
                selection = rect
            }
            selectionGesture = nil
            liveSelectionRect = nil
            onSelectionActivity?(selection != nil)
            layoutChrome()
            needsDisplay = true
            return
        }

        if event.clickCount == 2 {
            // Double-clicking words re-opens them for editing; double-clicking
            // empty canvas inside the Selection still confirms the capture.
            if let id = hitAnnotationID(at: point), reEditTextAnnotation(id) {
                return
            }
            if currentTool == .select, selection != nil {
                confirm()
                return
            }
        }

        if let affordance = deleteAffordanceRect, affordance.contains(point) {
            deleteSelection()
            return
        }

        // Grabbing an existing element takes priority over the active tool, so a
        // placed annotation is always selectable/movable/resizable — no need to
        // switch back to the select tool first.
        if let id = selectedID, let selected = document.annotation(for: id) {
            // The rotation handle floats clear of the box, so it is checked
            // first only to keep the two grabs from ever competing.
            if AnnotationGeometry.isOnRotationHandle(point, of: selected, handleSize: handleSize) {
                rotatingAnnotation = true
                beginManipulation(at: point, of: [id])
                return
            }
            if let handle = AnnotationGeometry.handle(
                at: point, on: selected, handleSize: handleSize
            ) {
                resizingHandle = handle
                beginManipulation(at: point, of: [id])
                return
            }
        }

        let shift = event.modifierFlags.contains(.shift)

        // A set of several drags as one unit from anywhere inside its combined
        // outline; Shift is reserved for changing who is in the set.
        if !shift, selectedIDs.count > 1,
           let bounds = selectedSetBounds, bounds.contains(point) {
            movingAnnotation = true
            beginManipulation(at: point, of: selectedIDs)
            return
        }

        if let id = hitAnnotationID(at: point) {
            if shift {
                // Shift-click fixes up a marquee that caught one item too many.
                if let existing = selectedIDs.firstIndex(of: id) {
                    selectedIDs.remove(at: existing)
                } else {
                    selectedIDs.append(id)
                }
                refreshToolOptions()
                needsDisplay = true
                return
            }
            // Body hit. Prime a move drag (only kicks in once the mouse actually
            // moves; a bare click just selects).
            selectedIDs = [id]
            resizingHandle = nil
            movingAnnotation = true
            movingLoupeCircle = document.annotation(for: id).flatMap {
                AnnotationGeometry.loupeCircle(of: $0, at: point)
            }
            beginManipulation(at: point, of: [id])
            refreshToolOptions()
            return
        }

        // With the select tool, an existing Selection resizes via its handles and
        // moves via a band along its edges. Its interior over empty canvas now
        // belongs to the annotation marquee.
        if currentTool == .select, let existing = selection, !isSelectionLocked {
            if let handle = AnnotationGeometry.rectHandle(at: point, in: existing, handleSize: handleSize) {
                beginSelectionGesture(.resizing(handle: handle, original: existing), at: point, with: event)
                return
            }
            if existing.contains(point) {
                if existing.insetBy(dx: selectionBorderBand, dy: selectionBorderBand).contains(point) {
                    clearSelection()
                    marquee = (origin: point, current: point)
                    needsDisplay = true
                    return
                }
                beginSelectionGesture(.moving(original: existing, grab: point), at: point, with: event)
                return
            }
        }

        // Empty space: drop any selection and run the active tool.
        clearSelection()
        switch currentTool {
        case .select:
            selection = nil
            beginSelectionGesture(.drawing(origin: point), at: point, with: event)
        case .text:
            dragStart = point
            startTextEditing(in: CGRect(origin: point, size: TextLayout.defaultBoxSize))
        default:
            dragStart = point
            draftAnnotation = makeDraft(at: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isBeautifying else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Manipulating a grabbed element wins over whatever the active tool does.
        if rotatingAnnotation, let id = selectedID, let original = manipulationOriginal {
            // Turned from the pre-drag angle every tick, so the handle tracks
            // the pointer instead of accumulating drift.
            document.updateLive(id, to: AnnotationGeometry.rotate(
                original,
                towards: point,
                snapping: event.modifierFlags.contains(.shift)
            ))
        } else if let handle = resizingHandle,
           let id = selectedID,
           let original = manipulationOriginal {
            document.updateLive(id, to: AnnotationGeometry.resize(
                original, handle: handle, to: handleTarget(point, on: original)
            ))
        } else if movingAnnotation, let start = manipulationStart {
            // The whole set moves by the same delta, so its internal
            // arrangement survives the drag.
            let dx = point.x - start.x
            let dy = point.y - start.y
            for (id, original) in manipulationOriginals {
                document.updateLive(id, to: movingLoupeCircle.map {
                    AnnotationGeometry.translate(original, circle: $0, dx: dx, dy: dy)
                } ?? AnnotationGeometry.translate(original, dx: dx, dy: dy))
            }
        } else if marquee != nil {
            marquee?.current = point
            selectMarqueedAnnotations()
        } else if selectionGesture != nil {
            updateSelectionGesture(at: point)
        } else if currentTool == .text, let start = dragStart, editingTextField != nil {
            // Dragging with the text tool sizes the box the editor sits in, so
            // the user can set the wrap width before typing a word.
            resizeTextEditor(from: start, to: point)
        } else if let draft = draftAnnotation, let start = dragStart {
            draftAnnotation = updatedDraft(draft, dragStart: start, current: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isBeautifying else { return }
        if let gesture = selectionGesture {
            // A gesture that never produced a rectangle (a bare click) leaves
            // the committed Selection as it was.
            let wasBareClick = liveSelectionRect == nil
            if let rect = liveSelectionRect {
                selection = rect
                // An armed exact size is consumed by the Selection it creates.
                if case .placingFixedSize = gesture.kind { armedExactSize = nil }
            }
            selectionGesture = nil
            liveSelectionRect = nil
            invalidateComposition()
            onSelectionActivity?(selection != nil)
            layoutChrome()
            needsDisplay = true
            if wasBareClick { handleBareClick(with: event, allowsDisplayCapture: true) }
            return
        }
        if marquee != nil {
            marquee = nil
            needsDisplay = true
            return
        }
        if resizingHandle != nil || movingAnnotation || rotatingAnnotation {
            // One drag is one step; a drag that ended where it started records
            // nothing inside the document.
            commitManipulation()
            resizingHandle = nil
            movingAnnotation = false
            movingLoupeCircle = nil
            rotatingAnnotation = false
            manipulationStart = nil
            manipulationOriginals = [:]
        } else if currentTool == .text {
            // Commit handled by the text field's delegate
        } else if case let .callout(anchor, box, _, _)? = draftAnnotation {
            // Callout: the drag aimed the bubble; now type its text. A bare
            // click puts the bubble at a default offset above the anchor.
            var origin = box.origin
            if hypot(origin.x - anchor.x, origin.y - anchor.y) < 4 {
                origin = CGPoint(x: anchor.x + 24, y: max(8, anchor.y - 64))
            }
            draftAnnotation = nil
            dragStart = nil
            commitTextEditing()
            startTextEditing(
                in: CGRect(origin: origin, size: TextLayout.defaultBoxSize),
                calloutAnchor: anchor
            )
        } else if let draft = draftAnnotation, isMeaningful(draft) {
            document.insert(settled(draft))
            draftAnnotation = nil
            dragStart = nil
        } else {
            let discardedToolClick = draftAnnotation != nil
            draftAnnotation = nil
            dragStart = nil
            // A tool click that drew nothing still snap-captures the window
            // under it; with snap off it stays a no-op.
            if discardedToolClick {
                handleBareClick(with: event, allowsDisplayCapture: false)
            }
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    /// Right-click pins a corner: the opposite corner then tracks the cursor
    /// hands-free, and a left-click commits. Inert once a Selection exists.
    override func rightMouseDown(with event: NSEvent) {
        guard !isBeautifying else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard currentTool == .select, selection == nil else { return }
        if case .anchored? = selectionGesture?.kind {
            // Re-anchor at the new point.
            liveSelectionRect = nil
            beginSelectionGesture(.anchored(anchor: point), at: point, with: event)
            return
        }
        guard selectionGesture == nil else { return }
        beginSelectionGesture(.anchored(anchor: point), at: point, with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isBeautifying else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastPointerPoint = point
        onPointerMoved?()
        if isAutoMeasureArmed {
            updateAutoMeasurePreview(at: point)
            return
        }
        refreshHoverPreview(at: point)
        // Anchored tracking: mouse-moved drives the gesture exactly as a drag.
        if case .anchored? = selectionGesture?.kind {
            updateSelectionGesture(at: point)
            return
        }
        // Armed exact size: a ghost frame of that size follows the cursor.
        if let size = armedExactSize, selection == nil, currentTool == .select {
            if selectionGesture == nil {
                beginSelectionGesture(.placingFixedSize(size), at: point, with: nil)
            }
            updateSelectionGesture(at: point)
            return
        }
        updateSnapHighlight(atWindowPoint: event.locationInWindow)
        if let toolbar, toolbar.frame.contains(point) { return }
        let overElement: Bool
        if let id = selectedID, let selected = document.annotation(for: id),
           AnnotationGeometry.handle(at: point, on: selected, handleSize: handleSize) != nil
            || AnnotationGeometry.isOnRotationHandle(
                point, of: selected, handleSize: handleSize
            ) {
            overElement = true
        } else {
            overElement = hitAnnotationID(at: point) != nil
        }
        (overElement ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    /// With snap armed and no selection in progress, the topmost window under
    /// the pointer highlights; the session resolves who that is.
    private func updateSnapHighlight(atWindowPoint point: NSPoint) {
        guard snapArmed, let onSnapHover,
              selection == nil, selectionGesture == nil
        else { return }
        guard let window else { return }
        let global = window.convertPoint(toScreen: point)
        let next = onSnapHover(global)
        if next?.candidate.id != snapHighlight?.candidate.id
            || next?.rect != snapHighlight?.rect {
            snapHighlight = next
            needsDisplay = true
        }
    }

    private func makeDraft(at point: CGPoint) -> Annotation? {
        let emptyRect = CGRect(origin: point, size: .zero)
        switch currentTool {
        case .select, .text: return nil
        case .rectangle: return .rectangle(emptyRect, strokeStyle)
        case .ellipse: return .ellipse(emptyRect, strokeStyle)
        case .line: return .line(from: point, to: point, strokeStyle)
        case .arrow: return .arrow(from: point, to: point, strokeStyle)
        case .pen: return .freehand(points: [point], strokeStyle)
        case .highlighter: return .highlighter(points: [point], highlighterStyle)
        case .callout:
            return .callout(
                anchor: point, box: CGRect(origin: point, size: .zero), content: "", calloutStyle
            )
        case .stepMarker:
            return .stepMarker(
                center: point,
                number: document.nextStepMarkerNumber,
                FillStyle(color: markerColor)
            )
        case .measure: return .measure(from: point, to: point, measureStyle)
        case .loupe: return loupeDraft(source: point, lens: nil)
        case .spotlight: return .spotlight(emptyRect, spotlightStyle)
        case .fillRect: return .fillRect(emptyRect, fillStyle)
        case .fillFreehand: return .fillFreehand(points: [point], fillStyle)
        case .blur: return .blur(emptyRect)
        case .pixelate: return .pixelate(emptyRect)
        }
    }

    private func updatedDraft(
        _ draft: Annotation,
        dragStart start: CGPoint,
        current: CGPoint
    ) -> Annotation {
        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        switch draft {
        case let .rectangle(_, style): return .rectangle(rect, style)
        case let .ellipse(_, style): return .ellipse(rect, style)
        case let .line(from, _, style): return .line(from: from, to: current, style)
        case let .arrow(from, _, style): return .arrow(from: from, to: current, style)
        case let .freehand(points, style): return .freehand(points: points + [current], style)
        case let .highlighter(points, style): return .highlighter(points: points + [current], style)
        case let .callout(anchor, _, content, style):
            return .callout(
                anchor: anchor,
                box: CGRect(origin: current, size: .zero),
                content: content,
                style
            )
        case let .stepMarker(_, number, style):
            return .stepMarker(center: current, number: number, style)
        case let .measure(from, _, style):
            return .measure(from: from, to: measureEndpoint(current, anchoredAt: from), style)
        case let .loupe(source, sourceRadius, _, _, style):
            // The lens follows the cursor; its radius keeps tracking the current
            // magnification, so the drag previews what a release will commit.
            return .loupe(
                source: source, sourceRadius: sourceRadius,
                lens: current,
                lensRadius: LoupeGeometry.lensRadius(
                    sourceRadius: sourceRadius, magnification: loupeMagnification
                ),
                style
            )
        case let .fillRect(_, style): return .fillRect(rect, style)
        case let .spotlight(_, style): return .spotlight(rect, style)
        case let .fillFreehand(points, style): return .fillFreehand(points: points + [current], style)
        case .blur: return .blur(rect)
        case .pixelate: return .pixelate(rect)
        case .text:
            return draft
        }
    }

    // MARK: Loupe

    /// A loupe with its source where the user pointed and its lens either where
    /// they dragged it or at the default offset. One helper, so the hover
    /// preview, the drag and a bare click cannot drift apart.
    private func loupeDraft(source: CGPoint, lens: CGPoint?) -> Annotation {
        let radius = LoupeGeometry.defaultSourceRadius
        return .loupe(
            source: source,
            sourceRadius: radius,
            lens: lens ?? CGPoint(
                x: source.x + LoupeGeometry.defaultLensOffset.dx,
                y: source.y + LoupeGeometry.defaultLensOffset.dy
            ),
            lensRadius: LoupeGeometry.lensRadius(
                sourceRadius: radius, magnification: loupeMagnification
            ),
            loupeStyle
        )
    }

    /// A draft as it should land. Only the loupe has anything to settle: a click
    /// that never dragged leaves the lens sitting on its own source, which is not
    /// a magnifier, so it takes the default offset instead — the same allowance
    /// the callout makes for a bare click.
    private func settled(_ annotation: Annotation) -> Annotation {
        guard case let .loupe(source, _, lens, _, _) = annotation,
              hypot(lens.x - source.x, lens.y - source.y) < 4
        else { return annotation }
        return loupeDraft(source: source, lens: nil)
    }

    private func refreshHoverPreview(at point: CGPoint) {
        let next = currentTool == .loupe && draftAnnotation == nil
            ? loupeDraft(source: point, lens: nil)
            : nil
        guard next != hoverPreview else { return }
        hoverPreview = next
        needsDisplay = true
    }

    private func clearHoverPreview() {
        guard hoverPreview != nil else { return }
        hoverPreview = nil
        needsDisplay = true
    }

    // MARK: Auto-measure

    /// Arrow keys drive the scan. Letters were all either taken by a tool or
    /// meaningless here, and the modifiers are spoken for by snapping.
    private static func scanAxis(forKeyCode code: UInt16) -> MeasureGeometry.ScanAxis? {
        switch code {
        case 123, 124: return .horizontal
        case 125, 126: return .vertical
        default: return nil
        }
    }

    /// True while a direction key is arming the scan. Nothing is committed until
    /// the user clicks, so releasing the key leaves the capture untouched.
    private var isAutoMeasureArmed: Bool { autoMeasure != nil }

    private func armAutoMeasure(_ axis: MeasureGeometry.ScanAxis) {
        autoMeasure = (axis: axis, preview: nil)
        // The pointer may not move again before the click, so the span is
        // resolved where it already is.
        if let point = lastPointerPoint { updateAutoMeasurePreview(at: point) }
        needsDisplay = true
    }

    private func disarmAutoMeasure() {
        guard autoMeasure != nil else { return }
        autoMeasure = nil
        needsDisplay = true
    }

    private func updateAutoMeasurePreview(at point: CGPoint) {
        guard let axis = autoMeasure?.axis else { return }
        autoMeasure = (axis: axis, preview: autoMeasuredSpan(at: point, along: axis))
        needsDisplay = true
    }

    /// The span under the cursor as a finished measure annotation. Device-pixel
    /// edges convert back to overlay points across the whole of the boundary
    /// pixels, so the readout is exactly the span the scan found.
    private func autoMeasuredSpan(
        at point: CGPoint, along axis: MeasureGeometry.ScanAxis
    ) -> Annotation? {
        guard let frozen else { return nil }
        if scanPixels == nil { scanPixels = PixelBuffer(image: frozen) }
        guard let pixels = scanPixels,
              let span = MeasureGeometry.boundarySpan(
                in: pixels,
                x: Int(point.x * scale), y: Int(point.y * scale),
                along: axis
              )
        else { return nil }
        let low = CGFloat(span.low) / scale
        let high = CGFloat(span.high + 1) / scale
        switch axis {
        case .vertical:
            return .measure(
                from: CGPoint(x: point.x, y: low), to: CGPoint(x: point.x, y: high), measureStyle
            )
        case .horizontal:
            return .measure(
                from: CGPoint(x: low, y: point.y), to: CGPoint(x: high, y: point.y), measureStyle
            )
        }
    }

    private func clampedToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// A measure endpoint: held inside this overlay, then snapped to the axis
    /// through the endpoint that is standing still. Each capture overlay covers
    /// one display, so confining the endpoint here is what keeps a measurement
    /// from ever spanning two of them.
    private func measureEndpoint(_ point: CGPoint, anchoredAt anchor: CGPoint) -> CGPoint {
        MeasureGeometry.snapped(clampedToBounds(point), anchoredAt: anchor)
    }

    /// Where a resize drag may put a handle. Only a measurement constrains it —
    /// its endpoints stay on this display; every other kind is free to hang off
    /// the edge and be cropped.
    private func handleTarget(_ point: CGPoint, on annotation: Annotation) -> CGPoint {
        guard case .measure = annotation else { return point }
        return clampedToBounds(point)
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation {
        case let .rectangle(rect, _),
             let .ellipse(rect, _),
             let .fillRect(rect, _),
             let .spotlight(rect, _),
             let .blur(rect),
             let .pixelate(rect):
            return rect.width >= 1 && rect.height >= 1
        case let .line(from, to, _), let .arrow(from, to, _), let .measure(from, to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 1
        case let .freehand(points, _),
             let .highlighter(points, _):
            return points.count >= 2
        case let .fillFreehand(points, _):
            return points.count >= 3
        case .stepMarker, .loupe:
            return true
        case let .text(_, content, _):
            return !content.isEmpty
        case let .callout(_, _, content, _):
            return !content.isEmpty
        }
    }

    // MARK: Annotation hit-testing

    /// The document's z-order is positional, so the topmost hit comes back as an
    /// index; everything downstream addresses the annotation by identifier.
    private func hitAnnotationID(at point: CGPoint) -> AnnotationDocument.ID? {
        AnnotationGeometry.hitIndex(in: document.annotations, at: point)
            .map { document.placed[$0].id }
    }

    // MARK: Selection gesture plumbing

    private func beginSelectionGesture(
        _ kind: SelectionGesture.Kind,
        at point: CGPoint,
        with event: NSEvent?
    ) {
        var gesture = SelectionGesture(kind: kind, at: point)
        gesture.shiftHeld = event?.modifierFlags.contains(.shift) ?? false
        gesture.optionHeld = event?.modifierFlags.contains(.option) ?? false
        gesture.lockedRatio = aspectLockRatio
        selectionGesture = gesture
        layoutChrome()
        needsDisplay = true
    }

    private func updateSelectionGesture(at point: CGPoint) {
        guard var gesture = selectionGesture else { return }
        let hadRect = liveSelectionRect != nil
        liveSelectionRect = SelectionGeometry.rectangle(
            for: &gesture, at: point, in: bounds, snapping: edgeIndex, pixelScale: scale
        )
        selectionGesture = gesture
        // The claim happens when the gesture first produces a rectangle, not
        // on mouse-down — a bare click must never steal another display's
        // selection.
        if !hadRect, liveSelectionRect != nil { onSelectionActivity?(true) }
        layoutChrome()
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        if var gesture = selectionGesture {
            gesture.shiftHeld = event.modifierFlags.contains(.shift)
            gesture.optionHeld = event.modifierFlags.contains(.option)
            // Re-evaluate at the stored cursor point so pressing or releasing
            // a modifier reshapes the rectangle without cursor movement.
            if liveSelectionRect != nil {
                liveSelectionRect = SelectionGeometry.rectangle(
                    for: &gesture, at: gesture.lastPoint, in: bounds,
                    snapping: edgeIndex, pixelScale: scale
                )
            }
            selectionGesture = gesture
            layoutChrome()
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // While a Resolution box field holds focus its editor owns the keys;
        // nothing here — least of all the tool shortcuts — may fire.
        if resolutionBox?.isEditing == true {
            return
        }
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if event.keyCode == 53 {
            // Esc peels one layer: the colour picker first, then anchored
            // state, then annotation selection, then the capture itself.
            if colorPicker != nil {
                closeColorPicker()
                needsDisplay = true
                return
            }
            if isAutoMeasureArmed {
                disarmAutoMeasure()
                return
            }
            if case .anchored? = selectionGesture?.kind {
                selectionGesture = nil
                liveSelectionRect = nil
                onSelectionActivity?(selection != nil)
                layoutChrome()
                needsDisplay = true
                return
            }
            if !selectedIDs.isEmpty {
                // Escape mid-drag cancels the manipulation: restore the pre-drag
                // annotations so no unrecorded (and therefore un-undoable) change
                // is left behind.
                for (id, original) in manipulationOriginals {
                    document.updateLive(id, to: original)
                }
                clearSelection()
                needsDisplay = true
                return
            }
            cancelBackgroundRemoval()
            onCancel?()
            return
        }
        // Backspace (51) or forward delete (117)
        if event.keyCode == 51 || event.keyCode == 117 {
            if !selectedIDs.isEmpty {
                deleteSelection()
                return
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            confirm()
            return
        }
        // Arrow keys arm the auto-measure scan, but only when the measure tool
        // is active and nothing is selected — otherwise they fall through to
        // whatever the editing model does with them.
        if let axis = Self.scanAxis(forKeyCode: event.keyCode),
           currentTool == .measure, selectedIDs.isEmpty {
            // Auto-repeat must not re-arm: re-resolving the span on every
            // repeat would flicker the preview under a still cursor.
            if !event.isARepeat { armAutoMeasure(axis) }
            return
        }
        // Tab (48) toggles window snap; the session decides whether it takes.
        if event.keyCode == 48, let onTabPressed {
            onTabPressed()
            return
        }
        // Space (49): reposition the in-flight Selection gesture. Inert when
        // no gesture is in flight.
        if event.keyCode == 49 {
            if !event.isARepeat, var gesture = selectionGesture, liveSelectionRect != nil {
                gesture.pressSpace()
                selectionGesture = gesture
            }
            return
        }
        if cmd, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z":
                if shift { redo() } else { undo() }
                return
            case "c":
                copySelection()
                return
            case "v":
                pasteAnnotations()
                return
            case "d":
                duplicateSelection()
                return
            default:
                break
            }
        }
        if event.modifierFlags.contains(.option),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let control = PostProcessingControl.allCases.first(where: { $0.keyEquivalent == key }) {
            togglePostProcessing(control)
            return
        }
        // A tool shortcut while the capture is read-only would silently do
        // nothing; the toolbar already says why.
        if isBeautifying { return }
        if !cmd, let key = event.charactersIgnoringModifiers?.lowercased() {
            // `F` is fullscreen-from-the-overlay when the overlay under the
            // cursor is idle; the session decides and otherwise reasserts the
            // fill-rect tool, so the shortcut keeps its meaning everywhere else.
            if key == "f", let onFullscreenKey {
                onFullscreenKey()
                return
            }
            let tool = Tool.allCases.first { !$0.keyEquivalent.isEmpty && $0.keyEquivalent == key }
            if let tool {
                setTool(tool)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if Self.scanAxis(forKeyCode: event.keyCode) != nil, isAutoMeasureArmed {
            disarmAutoMeasure()
            return
        }
        if event.keyCode == 49 {
            if var gesture = selectionGesture {
                gesture.releaseSpace()
                selectionGesture = gesture
            }
            return
        }
        super.keyUp(with: event)
    }

    private func undo() {
        document.undo()
        reconcileAfterHistory()
    }

    private func redo() {
        document.redo()
        reconcileAfterHistory()
    }

    /// After undo/redo, keep the annotation selection only while the annotation
    /// still exists, and re-read the style strip from the document so it never
    /// shows values for something that is not drawn.
    private func reconcileAfterHistory() {
        if composition.backgroundRemoved != document.backgroundRemoved {
            composition.backgroundRemoved = document.backgroundRemoved
            refreshPostProcessing()
        }
        let survivors = selectedIDs.filter { document.contains($0) }
        if survivors.count != selectedIDs.count {
            if survivors.isEmpty {
                clearSelection()
            } else {
                selectedIDs = survivors
            }
        }
        refreshToolOptions()
        needsDisplay = true
    }

    // MARK: Text editing

    /// Re-opens a placed text or callout for editing. Returns false for
    /// anything else, so a double-click on a rectangle falls through.
    private func reEditTextAnnotation(_ id: AnnotationDocument.ID) -> Bool {
        guard let annotation = document.annotation(for: id) else { return false }
        commitTextEditing()
        switch annotation {
        case let .text(box, content, style):
            clearSelection()
            startTextEditing(
                in: TextLayout.fittedBox(box, content: content, style: style),
                content: content,
                editing: id
            )
            return true
        case let .callout(anchor, box, content, style):
            clearSelection()
            startTextEditing(
                in: TextLayout.fittedBox(box, content: content, style: style),
                calloutAnchor: anchor,
                content: content,
                editing: id
            )
            return true
        default:
            return false
        }
    }

    /// Opens the inline editor over `box`. `editing` names the annotation being
    /// re-edited, if any; a commit then replaces it instead of inserting.
    private func startTextEditing(
        in box: CGRect,
        calloutAnchor: CGPoint? = nil,
        content: String = "",
        editing id: AnnotationDocument.ID? = nil
    ) {
        let style = calloutAnchor != nil ? calloutStyle : textStyle
        let editor = InlineTextView(frame: box)
        editor.prepare()
        editor.delegate = self
        editor.string = content
        editor.applyStyle(style, placeholder: calloutAnchor != nil ? "Callout" : "Text")
        addSubview(editor)
        window?.makeFirstResponder(editor)
        editingTextField = editor
        editingTextBox = box
        editingCalloutAnchor = calloutAnchor
        editingAnnotationID = id
        editingOriginalContent = content
        sizeTextEditorToContent()
        needsDisplay = true
    }

    /// Keeps the open editor looking like what will be baked, so a style change
    /// mid-typing previews where the user is typing.
    private func restyleOpenEditor() {
        guard let editor = editingTextField else { return }
        let style = editingCalloutAnchor != nil ? calloutStyle : textStyle
        editor.applyStyle(style, placeholder: editingCalloutAnchor != nil ? "Callout" : "Text")
        sizeTextEditorToContent()
    }

    /// Live re-wrap while the text tool's initial drag sizes the box.
    private func resizeTextEditor(from start: CGPoint, to point: CGPoint) {
        guard editingTextField != nil else { return }
        let box = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: max(abs(point.x - start.x), TextLayout.minimumBoxSize.width),
            height: max(abs(point.y - start.y), TextLayout.minimumBoxSize.height)
        )
        editingTextBox = box
        editingTextField?.frame = box
        sizeTextEditorToContent()
    }

    /// The editor grows downward as the content wraps past its height, so what
    /// is being typed is never hidden.
    private func sizeTextEditorToContent() {
        guard let editor = editingTextField, let box = editingTextBox else { return }
        let style = editingCalloutAnchor != nil ? calloutStyle : textStyle
        editor.frame = TextLayout.fittedBox(box, content: editor.string, style: style)
    }

    private func commitTextEditing() {
        guard let editor = editingTextField, let box = editingTextBox else { return }
        let content = editor.string
        let calloutAnchor = editingCalloutAnchor
        let editedID = editingAnnotationID
        clearTextEditorState()

        if content.isEmpty {
            // An emptied label leaves nothing behind rather than an invisible
            // artifact with a hit box.
            if let editedID { document.remove(editedID) }
            needsDisplay = true
            return
        }
        let updated: Annotation = calloutAnchor.map {
            .callout(anchor: $0, box: box, content: content, calloutStyle)
        } ?? .text(box: box, content: content, textStyle)

        if let editedID, let existing = document.annotation(for: editedID) {
            // Re-edit keeps the annotation's own style and geometry; only the
            // words changed.
            document.replace(editedID, with: reContented(existing, content: content))
        } else {
            document.insert(updated)
        }
        needsDisplay = true
    }

    /// The same annotation carrying different words.
    private func reContented(_ annotation: Annotation, content: String) -> Annotation {
        switch annotation {
        case let .text(box, _, style):
            return .text(box: box, content: content, style)
        case let .callout(anchor, box, _, style):
            return .callout(anchor: anchor, box: box, content: content, style)
        default:
            return annotation
        }
    }

    private func cancelTextEditing() {
        // Escape during a re-edit is not destructive: the annotation was never
        // changed, so dropping the editor restores what was there.
        clearTextEditorState()
        needsDisplay = true
    }

    private func clearTextEditorState() {
        editingTextField?.removeFromSuperview()
        editingTextField = nil
        editingTextBox = nil
        editingCalloutAnchor = nil
        editingAnnotationID = nil
        editingOriginalContent = ""
        window?.makeFirstResponder(self)
    }

    // MARK: Confirm + bake

    private func confirm() {
        commitTextEditing()
        var rect = selection ?? liveSelectionRect
        if rect == nil && !requiresSelection {
            // Post-capture editor: no crop selection means export everything.
            rect = bounds
        }
        guard let rect, rect.width >= 1, rect.height >= 1 else { return }
        // Capture overlay: the session bakes (and can hold the commit until
        // the frozen image lands).
        if let onCommitRequested {
            onCommitRequested(rect)
            return
        }
        guard let baked = bake(rect: rect) else { return }
        onCommit?(baked)
    }

    /// The capture as pixels, before any beautify staging: the crop of the
    /// frozen image with background removal and image effects applied, then the
    /// annotations drawn over it. That order is the spec's, and it is why
    /// effects never touch a red arrow and why annotations are later clipped by
    /// the corner radius.
    ///
    /// `previewBound` caps the working size so a slider drag composes from a
    /// small image; the bake passes nil and works at full capture resolution.
    private func captureImage(
        rect: NSRect, previewBound: CGFloat? = nil, includeAnnotations: Bool = true
    ) -> CGImage? {
        guard let frozen else { return nil }
        let pixelRect = CGRect(
            x: rect.minX * scale, y: rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height)
        )
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        // The window companion is already exactly the window, corners and all.
        guard var source = companionSource(for: rect) ?? frozen.cropping(to: pixelRect)
        else { return nil }

        // ADR 0003: the Core Image pass runs on this crop, never on the whole
        // frozen screen, and never at more than the working size it needs.
        if let bound = previewBound {
            let longest = max(pixelRect.width, pixelRect.height)
            if longest > bound, let shrunk = resized(source, by: bound / longest) {
                source = shrunk
            }
        }
        if composition.backgroundRemoved, let mask = subjectMask {
            source = SubjectIsolation.applying(mask: mask, to: source) ?? source
        }
        source = ImageEffects.apply(composition.effects, to: source)

        let width = source.width
        let height = source.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4 * width,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Switch to view-point, top-left origin coords for annotation rendering,
        // shifted so the crop's own top-left is the origin.
        let pointScale = CGFloat(width) / rect.width
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: pointScale, y: -pointScale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)

        if includeAnnotations {
            // Push NSGraphicsContext so NSString/NSAttributedString drawing works for text-bearing annotations
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            // The bake has no Selection dimming of its own, so the composed
            // spotlight layer covers the whole frozen frame before the crop.
            renderer.draw(document.annotations, in: ctx, dimmedWithin: bounds)

            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }

    private func resized(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func bake(rect: NSRect) -> CGImage? {
        guard let capture = captureImage(rect: rect) else { return nil }
        // Preview and bake share this call; only the pixel scale differs.
        return PostProcessingCompositor.render(
            capture, settings: beautifySettings(for: rect), scale: scale
        )
    }

    /// The beautify settings as the compositor should see them for `rect`: on
    /// the window-companion path the source already carries its own corners and
    /// title bar, so those two stages are dropped rather than applied twice.
    private func beautifySettings(for rect: NSRect) -> BeautifySettings {
        var settings = composition.beautify
        if companionSource(for: rect) != nil {
            settings.cornerRadius = 0
            settings.windowFrame = false
        }
        return settings
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Before the frozen image arrives the background stays clear, so the
        // live desktop shows through and the surface reads as the screen,
        // frozen.
        frozenImage?.draw(in: bounds)

        if isBeautifying {
            drawBeautifyPreview()
            return
        }

        // Effects and background removal change the capture pixels themselves,
        // so the preview draws them over the frozen screen; the annotations then
        // draw on top, which is the composition order without beautify's stages.
        if isTransformingCapture, let rect = postProcessingRect,
           let effected = effectedCapturePreview() {
            NSImage(cgImage: effected, size: rect.size).draw(in: rect)
        }

        // The highlight hides the moment a selection gesture begins, but the
        // state survives so a click-no-drag can still capture the window.
        if snapArmed, selection == nil, liveSelectionRect == nil,
           selectionGesture == nil, let (_, rect) = snapHighlight {
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            rect.fill()
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2.0
            path.stroke()
        }

        if let cgCtx = NSGraphicsContext.current?.cgContext {
            // Drafts and previews go through the same list as the placed
            // annotations — drawn through the same renderer case as the value a
            // release would commit, and composed into the same dim layer, so a
            // spotlight dims live while it is being dragged.
            var pending = document.placed
                .filter { $0.id != hiddenWhileEditing }
                .map(\.annotation)
            pending += [draftAnnotation, autoMeasure?.preview, hoverPreview].compactMap { $0 }
            // A Selection already dims everything outside itself, and that area
            // is not captured; clipping to it keeps the two dims from stacking
            // and makes the preview inside match the export.
            renderer.draw(
                pending, in: cgCtx,
                dimmedWithin: liveSelectionRect ?? selection ?? bounds
            )
        }

        if let id = selectedID, let selected = document.annotation(for: id) {
            drawSelectionIndicator(for: selected)
        } else if selectedIDs.count > 1 {
            drawSetIndicator()
        }
        refreshDeleteAffordance()

        if let rect = marqueeRect {
            NSColor.systemBlue.withAlphaComponent(0.15).setFill()
            rect.fill()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.0
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
        }

        let activeSelection = liveSelectionRect ?? selection
        if let active = activeSelection {
            let dimPath = NSBezierPath(rect: bounds)
            dimPath.appendRect(active)
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.40).setFill()
            dimPath.fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: active)
            border.lineWidth = 1.0
            border.stroke()

            // Thin guide line along each snapped edge, confirming the lock.
            if let snap = selectionGesture?.snapState, snap != .none {
                NSColor.systemBlue.setStroke()
                let guide = NSBezierPath()
                if let x = snap.left {
                    guide.move(to: NSPoint(x: x, y: active.minY - 12))
                    guide.line(to: NSPoint(x: x, y: active.maxY + 12))
                }
                if let x = snap.right {
                    guide.move(to: NSPoint(x: x, y: active.minY - 12))
                    guide.line(to: NSPoint(x: x, y: active.maxY + 12))
                }
                if let y = snap.top {
                    guide.move(to: NSPoint(x: active.minX - 12, y: y))
                    guide.line(to: NSPoint(x: active.maxX + 12, y: y))
                }
                if let y = snap.bottom {
                    guide.move(to: NSPoint(x: active.minX - 12, y: y))
                    guide.line(to: NSPoint(x: active.maxX + 12, y: y))
                }
                guide.lineWidth = 1.0
                guide.stroke()
            }

            // Committed selection grows resize handles with the select tool.
            if currentTool == .select, selection != nil, selectionGesture == nil,
               !isSelectionLocked {
                for (_, point) in AnnotationGeometry.rectHandlePositions(active) {
                    let handleRect = CGRect(
                        x: point.x - handleSize / 2,
                        y: point.y - handleSize / 2,
                        width: handleSize,
                        height: handleSize
                    )
                    NSColor.white.setFill()
                    NSBezierPath(rect: handleRect).fill()
                    NSColor.systemBlue.setStroke()
                    let path = NSBezierPath(rect: handleRect)
                    path.lineWidth = 1.0
                    path.stroke()
                }
            }
        }
    }

    /// A set of several draws one combined outline and a floating delete
    /// affordance. No resize or rotation handles: there is no group resize.
    private func drawSetIndicator() {
        guard let bounds = selectedSetBounds else { return }

        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(rect: bounds)
        outline.lineWidth = 1.0
        outline.setLineDash([4, 4], count: 2, phase: 0)
        outline.stroke()

    }

    /// The floating delete affordance is chrome, so it is a glass surface rather
    /// than a drawn shape — but it never takes the click itself: the overlay's
    /// own hit test still owns `deleteAffordanceRect`, so nothing about the
    /// gesture changed.
    private func refreshDeleteAffordance() {
        guard let rect = deleteAffordanceRect else {
            deleteAffordance?.removeFromSuperview()
            deleteAffordance = nil
            return
        }
        if deleteAffordance == nil {
            let cross = NSTextField(labelWithString: "✕")
            cross.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            cross.alignment = .center
            cross.textColor = ChromeTintRole.destructive.contentColor
            let content = NonInteractiveView(
                frame: NSRect(origin: .zero, size: rect.size)
            )
            cross.frame = NSRect(x: 0, y: (rect.height - 14) / 2, width: rect.width, height: 14)
            content.addSubview(cross)
            let surface = GlassChrome.surface(content, radius: .small, tint: .destructive)
            addSubview(surface)
            deleteAffordance = surface
        }
        deleteAffordance?.frame = rect
    }

    private func drawSelectionIndicator(for annotation: Annotation) {
        let corners = AnnotationGeometry.rotatedCorners(of: annotation, outset: 3)

        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath()
        outline.move(to: corners[0])
        for corner in corners.dropFirst() { outline.line(to: corner) }
        outline.close()
        outline.lineWidth = 1.0
        outline.setLineDash([4, 4], count: 2, phase: 0)
        outline.stroke()

        // Rotation handle: a round knob on a solid stem off the top edge, so it
        // never reads as one of the square resize handles.
        if let knob = AnnotationGeometry.rotationHandlePosition(for: annotation) {
            let stem = NSBezierPath()
            stem.move(to: NSPoint(
                x: (corners[0].x + corners[1].x) / 2,
                y: (corners[0].y + corners[1].y) / 2
            ))
            stem.line(to: knob)
            stem.lineWidth = 1.0
            stem.stroke()

            let knobRect = CGRect(
                x: knob.x - handleSize / 2,
                y: knob.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect).fill()
            NSColor.systemBlue.setStroke()
            let ring = NSBezierPath(ovalIn: knobRect)
            ring.lineWidth = 1.0
            ring.stroke()
        }

        let handles = AnnotationGeometry.handlePositions(for: annotation)
        for (_, point) in handles {
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.white.setFill()
            NSBezierPath(rect: handleRect).fill()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: handleRect)
            path.lineWidth = 1.0
            path.stroke()
        }
    }
}

extension RegionPickerView: NSTextViewDelegate {
    func textView(
        _ textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelTextEditing()
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            // The editor wraps and takes newlines now, so Return types one and
            // Cmd+Return (which AppKit maps to insertLineBreak) commits.
            commitTextEditing()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        sizeTextEditorToContent()
    }
}

// MARK: - Toolbar

final class RegionToolbarView: NSView {
    var onToolSelected: ((Tool) -> Void)?
    var onPostProcessingToggled: ((PostProcessingControl) -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onColorWellClicked: (() -> Void)?
    var onLineWidthSelected: ((CGFloat) -> Void)?
    var onFontSizeSelected: ((CGFloat) -> Void)?
    var onDashSelected: ((DashStyle) -> Void)?
    var onArrowHeadSelected: ((ArrowHead) -> Void)?
    var onFlip: (() -> Void)?
    var onFillModeSelected: ((FillMode) -> Void)?
    var onFillColorWellClicked: (() -> Void)?
    var onCornerRadiusSelected: ((CGFloat) -> Void)?
    var onFontFamilySelected: ((String) -> Void)?
    var onTraitToggled: ((TextTrait, Bool) -> Void)?
    var onAlignmentSelected: ((TextAlignment) -> Void)?
    var onTextBackgroundToggled: ((Bool) -> Void)?
    var onTextBackgroundWellClicked: (() -> Void)?
    var onTextOutlineToggled: ((Bool) -> Void)?
    var onTextOutlineWellClicked: (() -> Void)?
    var onMagnificationSelected: ((CGFloat) -> Void)?
    var onOutlineVisibilityToggled: ((Bool) -> Void)?
    var onSpotlightShapeSelected: ((SpotlightShape) -> Void)?
    var onDimStrengthSelected: ((CGFloat) -> Void)?
    var onStyleGestureBegan: (() -> Void)?
    var onStyleGestureEnded: (() -> Void)?

    /// Hover feedback: the button's tooltip text (nil on exit) plus its frame
    /// in the toolbar's coordinates. The hosting view renders the tooltip.
    var onButtonHover: ((String?, NSRect) -> Void)?

    private var toolButtons: [ToolButton] = []
    private var postProcessingButtons: [PostProcessingButton] = []
    private let optionsRow: ToolOptionsRowView
    /// While a post-processing preview is up the capture is read-only, so the
    /// annotation tools dim and say why.
    private var toolsDisabledHint: String?

    init(tools: [Tool]) {
        self.optionsRow = ToolOptionsRowView()
        super.init(frame: .zero)
        wantsLayer = true
        // One glass surface for the whole strip — the tool row and the options
        // row below it — rather than one per button: fifteen tools' worth of
        // glass would blow both the sampling budget and the visual language.
        GlassChrome.installBackdrop(in: self, radius: .large)

        let buttonRowY: CGFloat = 40
        let buttonSize = ChromeMetrics.controlHeight
        let buttonPad: CGFloat = 2
        var x: CGFloat = 8
        var previousGroup: ToolGroup?

        for tool in tools {
            if let prev = previousGroup, prev != tool.group {
                x += 4
                addSeparator(at: x, y: buttonRowY + 4)
                x += 1 + 6
            }
            let button = ToolButton(tool: tool)
            button.onClick = { [weak self] in self?.onToolSelected?($0) }
            button.onHover = { [weak self, weak button] tool in
                guard let self, let button else { return }
                self.onButtonHover?(tool.map { self.tooltipText(for: $0) }, button.frame)
            }
            button.frame = NSRect(x: x, y: buttonRowY, width: buttonSize, height: buttonSize)
            addSubview(button)
            toolButtons.append(button)
            x += buttonSize + buttonPad
            previousGroup = tool.group
        }

        x += 4
        addSeparator(at: x, y: buttonRowY + 4)
        x += 1 + 6

        // Changing the image reads differently from drawing on it, so the
        // post-processing controls get their own group.
        for control in PostProcessingControl.allCases {
            let button = PostProcessingButton(control: control)
            button.onClick = { [weak self] in self?.onPostProcessingToggled?($0) }
            button.onHover = { [weak self, weak button] control in
                guard let self, let button else { return }
                self.onButtonHover?(control?.tooltip, button.frame)
            }
            button.frame = NSRect(x: x, y: buttonRowY, width: buttonSize, height: buttonSize)
            addSubview(button)
            postProcessingButtons.append(button)
            x += buttonSize + buttonPad
        }

        x += 4
        addSeparator(at: x, y: buttonRowY + 4)
        x += 1 + 6

        let cancel = TextActionButton(kind: .neutral, title: "Cancel")
        cancel.onClick = { [weak self] in self?.onCancel?() }
        cancel.onHover = { [weak self, weak cancel] hovering in
            guard let self, let cancel else { return }
            self.onButtonHover?(hovering ? "Discard capture (Esc)" : nil, cancel.frame)
        }
        cancel.frame = NSRect(x: x, y: buttonRowY, width: 64, height: 36)
        addSubview(cancel)
        x += 64 + 4

        let done = TextActionButton(kind: .primary, title: "Done")
        done.onClick = { [weak self] in self?.onDone?() }
        done.onHover = { [weak self, weak done] hovering in
            guard let self, let done else { return }
            self.onButtonHover?(hovering ? "Capture selected region (Return)" : nil, done.frame)
        }
        done.frame = NSRect(x: x, y: buttonRowY, width: 64, height: 36)
        addSubview(done)
        x += 64 + 8

        frame = NSRect(x: 0, y: 0, width: x, height: 84)

        optionsRow.onColorWellClicked = { [weak self] in self?.onColorWellClicked?() }
        optionsRow.onDashSelected = { [weak self] in self?.onDashSelected?($0) }
        optionsRow.onArrowHeadSelected = { [weak self] in self?.onArrowHeadSelected?($0) }
        optionsRow.onFlip = { [weak self] in self?.onFlip?() }
        optionsRow.onFillModeSelected = { [weak self] in self?.onFillModeSelected?($0) }
        optionsRow.onFillColorWellClicked = { [weak self] in self?.onFillColorWellClicked?() }
        optionsRow.onCornerRadiusSelected = { [weak self] in self?.onCornerRadiusSelected?($0) }
        optionsRow.onFontFamilySelected = { [weak self] in self?.onFontFamilySelected?($0) }
        optionsRow.onTraitToggled = { [weak self] in self?.onTraitToggled?($0, $1) }
        optionsRow.onAlignmentSelected = { [weak self] in self?.onAlignmentSelected?($0) }
        optionsRow.onTextBackgroundToggled = { [weak self] in self?.onTextBackgroundToggled?($0) }
        optionsRow.onTextBackgroundWellClicked = { [weak self] in
            self?.onTextBackgroundWellClicked?()
        }
        optionsRow.onTextOutlineToggled = { [weak self] in self?.onTextOutlineToggled?($0) }
        optionsRow.onTextOutlineWellClicked = { [weak self] in self?.onTextOutlineWellClicked?() }
        optionsRow.onMagnificationSelected = { [weak self] in self?.onMagnificationSelected?($0) }
        optionsRow.onSpotlightShapeSelected = { [weak self] in self?.onSpotlightShapeSelected?($0) }
        optionsRow.onDimStrengthSelected = { [weak self] in self?.onDimStrengthSelected?($0) }
        optionsRow.onOutlineVisibilityToggled = { [weak self] in
            self?.onOutlineVisibilityToggled?($0)
        }
        optionsRow.onLineWidthSelected = { [weak self] in self?.onLineWidthSelected?($0) }
        optionsRow.onFontSizeSelected = { [weak self] in self?.onFontSizeSelected?($0) }
        optionsRow.onGestureBegan = { [weak self] in self?.onStyleGestureBegan?() }
        optionsRow.onGestureEnded = { [weak self] in self?.onStyleGestureEnded?() }
        optionsRow.frame.origin = NSPoint(x: 0, y: 8)
        addSubview(optionsRow)
    }

    /// The row sizes itself to the controls it shows, so it is re-centred on
    /// every configure rather than sitting at a fixed offset.
    func configureToolOptions(options: AnnotationOptions, style: AnnotationStyle) {
        optionsRow.configure(options: options, style: style)
        optionsRow.frame.origin.x = (frame.width - optionsRow.frame.width) / 2
    }

    required init?(coder: NSCoder) { nil }

    func setCurrent(_ tool: Tool) {
        for button in toolButtons {
            button.isActive = (button.tool == tool)
        }
    }

    func setPostProcessing(_ control: PostProcessingControl, active: Bool) {
        postProcessingButtons.first { $0.control == control }?.isActive = active
    }

    /// Dims the annotation tools and replaces their hover text, so a disabled
    /// tool explains itself instead of just not responding.
    func setToolsDisabled(_ hint: String?) {
        toolsDisabledHint = hint
        for button in toolButtons {
            button.alphaValue = hint == nil ? 1 : 0.35
        }
        optionsRow.isHidden = hint != nil
    }

    private func tooltipText(for tool: Tool) -> String {
        if let toolsDisabledHint { return toolsDisabledHint }
        if tool.keyEquivalent.isEmpty {
            return tool.label
        }
        return "\(tool.label) (\(tool.keyEquivalent.uppercased()))"
    }

    private func addSeparator(at x: CGFloat, y: CGFloat) {
        let separator = NonInteractiveView(frame: NSRect(x: x, y: y, width: 1, height: 28))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)
    }
}

/// The post-processing controls in the toolbar: not tools, so they get their own
/// group, their own button and Option-modified shortcuts.
enum PostProcessingControl: String, CaseIterable {
    case beautify
    case effects
    case removeBackground

    var systemImage: String {
        switch self {
        case .beautify: return "wand.and.stars"
        case .effects: return "slider.horizontal.3"
        case .removeBackground: return "person.and.background.dotted"
        }
    }

    var label: String {
        switch self {
        case .beautify: return "Beautify"
        case .effects: return "Image effects"
        case .removeBackground: return "Remove background"
        }
    }

    /// Every plain letter that fits is already an annotation tool's.
    var keyEquivalent: String {
        switch self {
        case .beautify: return "b"
        case .effects: return "e"
        case .removeBackground: return "r"
        }
    }

    var tooltip: String { "\(label) (⌥\(keyEquivalent.uppercased()))" }
}

final class PostProcessingButton: NSView {
    let control: PostProcessingControl
    var isActive = false { didSet { updateAppearance() } }
    var onClick: ((PostProcessingControl) -> Void)?
    var onHover: ((PostProcessingControl?) -> Void)?

    private let imageView: NSImageView

    init(control: PostProcessingControl) {
        let iv = NSImageView()
        iv.image = NSImage(
            systemSymbolName: control.systemImage, accessibilityDescription: control.label
        )
        iv.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: ChromeMetrics.symbolPointSize, weight: ChromeMetrics.symbolWeight
        )
        iv.imageScaling = .scaleProportionallyUpOrDown
        self.imageView = iv
        self.control = control
        super.init(frame: NSRect(
            x: 0, y: 0, width: ChromeMetrics.controlHeight, height: ChromeMetrics.controlHeight
        ))
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding
        )
        imageView.frame = NSRect(x: 6, y: 6, width: 24, height: 24)
        addSubview(imageView)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(control) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) { onClick?(control) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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
        imageView.contentTintColor = role.contentColor
    }
}

/// Small dark chip with one line of white text: the instant in-overlay tooltip
/// and the selecting-state hint (phase 7 restyles the chrome).
final class OverlayTooltipView: NSView {
    private let label: NSTextField

    var text: String { label.stringValue }

    init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        self.label = label
        let size = label.intrinsicContentSize
        super.init(frame: NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 8))
        wantsLayer = true
        GlassChrome.installBackdrop(in: self, radius: .tooltip)
        label.frame = NSRect(x: 8, y: 4, width: size.width, height: size.height)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
}

/// Centred idle helper card: one instruction line plus the window-snap status
/// line. Not interactive — hit testing passes through, so clicking or
/// dragging over it behaves as if it were not there. Phase 7 restyles it.
final class OverlayHelperCardView: NSView {
    let content: HelperCard.Content

    init(content: HelperCard.Content) {
        self.content = content
        let instruction = NSTextField(labelWithString: content.instruction)
        instruction.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        instruction.textColor = .labelColor
        instruction.alignment = .center
        let status = NSTextField(labelWithString: content.status)
        status.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.alignment = .center

        let instructionSize = instruction.intrinsicContentSize
        let statusSize = status.intrinsicContentSize
        let width = max(instructionSize.width, statusSize.width) + 32
        let height = instructionSize.height + statusSize.height + 6 + 24
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        GlassChrome.installBackdrop(in: self, radius: .large)

        instruction.frame = NSRect(
            x: 16, y: 12 + statusSize.height + 6,
            width: width - 32, height: instructionSize.height
        )
        status.frame = NSRect(
            x: 16, y: 12, width: width - 32, height: statusSize.height
        )
        addSubview(instruction)
        addSubview(status)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ToolButton: NSView {
    let tool: Tool
    var isActive: Bool = false {
        didSet { updateAppearance() }
    }
    var onClick: ((Tool) -> Void)?
    var onHover: ((Tool?) -> Void)?

    private let imageView: NSImageView

    init(tool: Tool) {
        let iv = NSImageView()
        iv.image = NSImage(
            systemSymbolName: tool.systemImage,
            accessibilityDescription: tool.label
        )
        iv.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: ChromeMetrics.symbolPointSize, weight: ChromeMetrics.symbolWeight
        )
        iv.imageScaling = .scaleProportionallyUpOrDown
        self.imageView = iv
        self.tool = tool
        super.init(frame: NSRect(
            x: 0, y: 0, width: ChromeMetrics.controlHeight, height: ChromeMetrics.controlHeight
        ))
        wantsLayer = true
        // A pill inside the strip: the strip's radius, less the inset to it.
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding
        )
        imageView.frame = NSRect(x: 6, y: 6, width: 24, height: 24)
        addSubview(imageView)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private var isHovering = false { didSet { updateAppearance() } }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        onHover?(tool)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(tool)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Active, hovering and resting are three distinct fills; disabled is the
    /// dimming the toolbar applies when the capture is read-only.
    /// Layer colours are resolved CGColors, so they are re-resolved when the
    /// effective appearance changes rather than staying frozen at the value
    /// they had when the control was built.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let role: ChromeTintRole = isActive ? .active : .neutral
        if isActive {
            layer?.backgroundColor = role.tintColor?.cgColor
        } else {
            layer?.backgroundColor = isHovering
                ? NSColor.quaternaryLabelColor.cgColor
                : NSColor.clear.cgColor
        }
        imageView.contentTintColor = role.contentColor
    }
}

final class TextActionButton: NSView {
    enum Kind { case primary, neutral }
    let kind: Kind
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let labelView: NSTextField

    init(kind: Kind, title: String) {
        self.kind = kind
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        self.labelView = label
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: ChromeMetrics.controlHeight))
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.large.radius, inset: ChromeMetrics.padding
        )
        label.frame = NSRect(x: 0, y: 9, width: 64, height: 18)
        addSubview(label)
        updateAppearance()
    }

    /// Done is the primary action and reads in the user's accent; Cancel is
    /// deliberately quiet beside it. Re-resolved on an appearance change,
    /// because a layer colour is a resolved CGColor.
    private func updateAppearance() {
        let role: ChromeTintRole = kind == .primary ? .primary : .neutral
        layer?.backgroundColor = role.tintColor?.cgColor
            ?? NSColor.quaternaryLabelColor.cgColor
        labelView.textColor = role.contentColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The tool-options row: the contextual band under the toolbar that shows only
/// the controls the active tool — or the selected annotation — actually offers.
/// It renders whatever `AnnotationOptions` it is handed and decides nothing
/// about applicability itself.
final class ToolOptionsRowView: NSView {
    static let lineWidthRange: ClosedRange<CGFloat> = 1...40
    static let fontSizeRange: ClosedRange<CGFloat> = 10...72
    static let cornerRadiusRange: ClosedRange<CGFloat> = 0...48

    var onColorWellClicked: (() -> Void)?
    var onLineWidthSelected: ((CGFloat) -> Void)?
    var onFontSizeSelected: ((CGFloat) -> Void)?
    var onDashSelected: ((DashStyle) -> Void)?
    var onArrowHeadSelected: ((ArrowHead) -> Void)?
    var onFlip: (() -> Void)?
    var onFillModeSelected: ((FillMode) -> Void)?
    var onFillColorWellClicked: (() -> Void)?
    var onCornerRadiusSelected: ((CGFloat) -> Void)?
    var onFontFamilySelected: ((String) -> Void)?
    var onTraitToggled: ((TextTrait, Bool) -> Void)?
    var onAlignmentSelected: ((TextAlignment) -> Void)?
    var onTextBackgroundToggled: ((Bool) -> Void)?
    var onTextBackgroundWellClicked: (() -> Void)?
    var onTextOutlineToggled: ((Bool) -> Void)?
    var onTextOutlineWellClicked: (() -> Void)?
    var onMagnificationSelected: ((CGFloat) -> Void)?
    var onOutlineVisibilityToggled: ((Bool) -> Void)?
    var onSpotlightShapeSelected: ((SpotlightShape) -> Void)?
    var onDimStrengthSelected: ((CGFloat) -> Void)?
    /// A slider drag brackets its live values with these, so the whole drag
    /// lands as one undo entry and persists once instead of per tick.
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    let colorWell = ColorWellButton()
    let dashControl = SegmentedOptionControl(
        titles: DashStyle.allCases.map(\.label),
        tooltips: DashStyle.allCases.map(\.tooltip)
    )
    let headControl = SegmentedOptionControl(
        titles: ArrowHead.allCases.map(\.label),
        tooltips: ArrowHead.allCases.map(\.tooltip)
    )
    let flipButton = OptionActionButton(title: "⇄", tooltip: "Flip direction")
    let fillModeControl = SegmentedOptionControl(
        titles: FillMode.allCases.map(\.label),
        tooltips: FillMode.allCases.map(\.tooltip)
    )
    let fillColorWell = ColorWellButton()
    let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let traitToggles: [TextTrait: ToggleOptionButton] = [
        .bold: ToggleOptionButton(title: "B", tooltip: "Bold"),
        .italic: ToggleOptionButton(title: "I", tooltip: "Italic", italic: true),
        .underline: ToggleOptionButton(title: "U", tooltip: "Underline"),
        .strikethrough: ToggleOptionButton(title: "S", tooltip: "Strikethrough")
    ]
    let alignmentControl = SegmentedOptionControl(
        titles: TextAlignment.allCases.map(\.label),
        tooltips: TextAlignment.allCases.map(\.tooltip)
    )
    let backgroundToggle = ToggleOptionButton(title: "▤", tooltip: "Background behind the text")
    let backgroundWell = ColorWellButton()
    let outlineToggle = ToggleOptionButton(title: "◌", tooltip: "Outline around the glyphs")
    let outlineWell = ColorWellButton()
    let ringToggle = ToggleOptionButton(title: "◯", tooltip: "Rings and connector")
    let spotlightShapeControl = SegmentedOptionControl(
        titles: SpotlightShape.allCases.map(\.label),
        tooltips: SpotlightShape.allCases.map(\.tooltip)
    )
    private let separator: NSView
    private let widthSlider: OptionSlider
    private let fontSlider: OptionSlider
    private let radiusSlider: OptionSlider
    private let magnificationSlider: OptionSlider
    private let dimSlider: OptionSlider

    private let height: CGFloat = 24
    private let swatchSize: CGFloat = 22
    private let sliderWidth: CGFloat = 116

    init() {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        self.separator = sep
        self.widthSlider = OptionSlider(
            range: Self.lineWidthRange,
            format: { String(format: "%.0f", $0) }
        )
        self.fontSlider = OptionSlider(
            range: Self.fontSizeRange,
            format: { String(format: "%.0f", $0) }
        )
        self.radiusSlider = OptionSlider(
            range: Self.cornerRadiusRange,
            format: { String(format: "%.0f", $0) }
        )
        self.magnificationSlider = OptionSlider(
            range: LoupeGeometry.magnificationRange,
            format: { String(format: "%.1f×", $0) }
        )
        self.dimSlider = OptionSlider(
            range: SpotlightGeometry.strengthRange,
            format: { String(format: "%.0f%%", $0 * 100) }
        )
        super.init(frame: .zero)

        colorWell.onClick = { [weak self] in self?.onColorWellClicked?() }
        colorWell.frame = NSRect(x: 0, y: 1, width: swatchSize, height: swatchSize)
        addSubview(colorWell)

        dashControl.onSelect = { [weak self] index in
            self?.onDashSelected?(DashStyle.allCases[index])
        }
        headControl.onSelect = { [weak self] index in
            self?.onArrowHeadSelected?(ArrowHead.allCases[index])
        }
        flipButton.onClick = { [weak self] in self?.onFlip?() }
        for control in [dashControl, headControl, flipButton] as [NSView] {
            control.frame.origin.y = 2
            addSubview(control)
        }

        separator.frame = NSRect(x: 0, y: 4, width: 1, height: 16)
        addSubview(separator)

        fontPopup.addItems(withTitles: TextLayout.fontFamilies)
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged)
        fontPopup.controlSize = .small
        fontPopup.font = NSFont.systemFont(ofSize: 11)
        fontPopup.frame = NSRect(x: 0, y: 2, width: 116, height: 20)
        addSubview(fontPopup)

        for (trait, toggle) in traitToggles {
            toggle.onToggle = { [weak self] on in self?.onTraitToggled?(trait, on) }
            toggle.frame.origin.y = 2
            addSubview(toggle)
        }
        alignmentControl.onSelect = { [weak self] index in
            self?.onAlignmentSelected?(TextAlignment.allCases[index])
        }
        alignmentControl.frame.origin.y = 2
        addSubview(alignmentControl)

        backgroundToggle.onToggle = { [weak self] on in self?.onTextBackgroundToggled?(on) }
        outlineToggle.onToggle = { [weak self] on in self?.onTextOutlineToggled?(on) }
        backgroundWell.onClick = { [weak self] in self?.onTextBackgroundWellClicked?() }
        outlineWell.onClick = { [weak self] in self?.onTextOutlineWellClicked?() }
        for control in [backgroundToggle, outlineToggle] as [NSView] {
            control.frame.origin.y = 2
            addSubview(control)
        }
        for well in [backgroundWell, outlineWell] {
            well.frame = NSRect(x: 0, y: 1, width: swatchSize, height: swatchSize)
            addSubview(well)
        }

        fillModeControl.onSelect = { [weak self] index in
            self?.onFillModeSelected?(FillMode.allCases[index])
        }
        fillColorWell.onClick = { [weak self] in self?.onFillColorWellClicked?() }
        fillColorWell.frame = NSRect(x: 0, y: 1, width: swatchSize, height: swatchSize)
        fillModeControl.frame.origin.y = 2
        addSubview(fillModeControl)
        addSubview(fillColorWell)

        ringToggle.onToggle = { [weak self] on in self?.onOutlineVisibilityToggled?(on) }
        ringToggle.frame.origin.y = 2
        addSubview(ringToggle)

        spotlightShapeControl.onSelect = { [weak self] index in
            self?.onSpotlightShapeSelected?(SpotlightShape.allCases[index])
        }
        spotlightShapeControl.frame.origin.y = 2
        addSubview(spotlightShapeControl)

        widthSlider.onChange = { [weak self] width in self?.onLineWidthSelected?(width) }
        fontSlider.onChange = { [weak self] size in self?.onFontSizeSelected?(size) }
        radiusSlider.onChange = { [weak self] radius in self?.onCornerRadiusSelected?(radius) }
        magnificationSlider.onChange = { [weak self] value in
            self?.onMagnificationSelected?(value)
        }
        dimSlider.onChange = { [weak self] value in self?.onDimStrengthSelected?(value) }
        for slider in [widthSlider, fontSlider, radiusSlider, magnificationSlider, dimSlider] {
            slider.frame = NSRect(x: 0, y: 0, width: sliderWidth, height: height)
            slider.onGestureBegan = { [weak self] in self?.onGestureBegan?() }
            slider.onGestureEnded = { [weak self] in self?.onGestureEnded?() }
            addSubview(slider)
        }

        frame = NSRect(x: 0, y: 0, width: 0, height: height)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func fontFamilyChanged() {
        onFontFamilySelected?(fontPopup.titleOfSelectedItem ?? TextLayout.systemFamilyName)
    }

    /// Lays out just the applicable controls and shrinks to fit them, so a tool
    /// with no options takes up no room at all. It is handed the composed style
    /// value rather than one parameter per axis, so a slice that adds an axis
    /// adds it in one place.
    func configure(options: AnnotationOptions, style: AnnotationStyle) {
        let showsColor = options.contains(.color)
        let showsWidth = options.contains(.lineWidth)
        let showsFont = options.contains(.fontSize)
        let showsDash = options.contains(.dash)
        let showsHead = options.contains(.arrowHead)
        let showsFlip = options.contains(.flip)
        let showsFillMode = options.contains(.fillMode)
        let showsRadius = options.contains(.cornerRadius)
        let showsMagnification = options.contains(.magnification)
        let showsRings = options.contains(.outlineVisible)
        let showsSpotlightShape = options.contains(.spotlightShape)
        let showsDim = options.contains(.dimStrength)
        // The fill colour only exists once something is being filled; the row
        // is handed the style, so it can tell.
        let showsFillColor = showsFillMode && (style.fillMode ?? .strokeOnly).paintsFill

        var x: CGFloat = 8
        colorWell.isHidden = !showsColor
        if showsColor {
            if let color = style.color { colorWell.color = color }
            colorWell.frame.origin.x = x
            x += swatchSize + 4
        }

        separator.isHidden = !(showsColor && (showsWidth || showsFont || showsDash))
        if !separator.isHidden {
            x += 4
            separator.frame.origin.x = x
            x += 1 + 8
        }

        widthSlider.isHidden = !showsWidth
        fontSlider.isHidden = !showsFont
        radiusSlider.isHidden = !showsRadius
        magnificationSlider.isHidden = !showsMagnification
        dimSlider.isHidden = !showsDim
        for (slider, value, shown) in [
            (widthSlider, style.lineWidth, showsWidth),
            (fontSlider, style.fontSize, showsFont),
            (radiusSlider, style.cornerRadius, showsRadius),
            (magnificationSlider, style.magnification, showsMagnification),
            (dimSlider, style.dimStrength, showsDim)
        ] {
            guard shown else { continue }
            if let value { slider.value = value }
            slider.frame.origin.x = x
            x += slider.frame.width
        }

        dashControl.isHidden = !showsDash
        if showsDash {
            dashControl.selectedIndex =
                DashStyle.allCases.firstIndex(of: style.dash ?? .solid) ?? 0
            dashControl.frame.origin.x = x
            x += dashControl.frame.width + 6
        }

        headControl.isHidden = !showsHead
        if showsHead {
            headControl.selectedIndex =
                ArrowHead.allCases.firstIndex(of: style.arrowHead ?? .standard) ?? 0
            headControl.frame.origin.x = x
            x += headControl.frame.width + 6
        }

        flipButton.isHidden = !showsFlip
        if showsFlip {
            flipButton.frame.origin.x = x
            x += flipButton.frame.width
        }

        fillModeControl.isHidden = !showsFillMode
        if showsFillMode {
            fillModeControl.selectedIndex =
                FillMode.allCases.firstIndex(of: style.fillMode ?? .strokeOnly) ?? 0
            fillModeControl.frame.origin.x = x
            x += fillModeControl.frame.width + 6
        }

        fillColorWell.isHidden = !showsFillColor
        if showsFillColor {
            if let fill = style.fillColor { fillColorWell.color = fill }
            fillColorWell.frame.origin.x = x
            x += swatchSize + 4
        }

        spotlightShapeControl.isHidden = !showsSpotlightShape
        if showsSpotlightShape {
            spotlightShapeControl.selectedIndex =
                SpotlightShape.allCases.firstIndex(of: style.spotlightShape ?? .rectangle) ?? 0
            spotlightShapeControl.frame.origin.x = x
            x += spotlightShapeControl.frame.width + 6
        }

        ringToggle.isHidden = !showsRings
        if showsRings {
            ringToggle.isOn = style.outlineVisible ?? true
            ringToggle.frame.origin.x = x
            x += ringToggle.frame.width + 4
        }

        x = layOutTextControls(options: options, style: style, from: x)

        isHidden = options.isEmpty
        frame.size.width = options.isEmpty ? 0 : x + 8
    }
}

extension ToolOptionsRowView {
    /// The typography half of the row. Split out because the row would
    /// otherwise be one function long enough to hide a mistake in.
    fileprivate func layOutTextControls(
        options: AnnotationOptions, style: AnnotationStyle, from startX: CGFloat
    ) -> CGFloat {
        var x = startX
        let showsFamily = options.contains(.fontFamily)
        let showsTraits = options.contains(.textTraits)
        let showsAlignment = options.contains(.alignment)
        let showsBackground = options.contains(.textBackground)
        let showsOutline = options.contains(.textOutline)

        fontPopup.isHidden = !showsFamily
        if showsFamily {
            let family = style.fontFamily.flatMap { $0.isEmpty ? nil : $0 }
                ?? TextLayout.systemFamilyName
            fontPopup.selectItem(withTitle: family)
            fontPopup.frame.origin.x = x
            x += fontPopup.frame.width + 6
        }

        for (trait, toggle) in traitToggles.sorted(by: { $0.key.order < $1.key.order }) {
            toggle.isHidden = !showsTraits
            guard showsTraits else { continue }
            toggle.isOn = trait.isOn(in: style)
            toggle.frame.origin.x = x
            x += toggle.frame.width + 2
        }
        if showsTraits { x += 4 }

        alignmentControl.isHidden = !showsAlignment
        if showsAlignment {
            alignmentControl.selectedIndex =
                TextAlignment.allCases.firstIndex(of: style.alignment ?? .left) ?? 0
            alignmentControl.frame.origin.x = x
            x += alignmentControl.frame.width + 6
        }

        // Each of these is a toggle plus a well, and the well only exists when
        // the toggle is on — the same shape as the shape fill above.
        for (shown, toggle, well, color) in [
            (showsBackground, backgroundToggle, backgroundWell, style.backgroundColor ?? nil),
            (showsOutline, outlineToggle, outlineWell, style.outlineColor ?? nil)
        ] {
            toggle.isHidden = !shown
            well.isHidden = !(shown && color != nil)
            guard shown else { continue }
            toggle.isOn = color != nil
            toggle.frame.origin.x = x
            x += toggle.frame.width + 2
            if let color {
                well.color = color
                well.frame.origin.x = x
                x += well.frame.width + 4
            }
        }
        return x
    }
}

/// A labelled continuous slider. It reports every intermediate value so the
/// canvas previews live, and brackets the whole drag so its owner can record
/// one edit rather than one per tick.
final class OptionSlider: NSView {
    var onChange: ((CGFloat) -> Void)?
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    var value: CGFloat {
        get { CGFloat(slider.doubleValue) }
        set {
            slider.doubleValue = Double(newValue)
            valueLabel.stringValue = format(newValue)
        }
    }

    /// A control that does nothing needs to say so rather than just not
    /// responding — see the window companion path, where the window already
    /// carries its own corners.
    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            alphaValue = newValue ? 1 : 0.4
        }
    }

    private let slider: TrackingSlider
    private let valueLabel: NSTextField
    private let format: (CGFloat) -> String

    init(range: ClosedRange<CGFloat>, format: @escaping (CGFloat) -> String) {
        self.format = format
        slider = TrackingSlider()
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.controlSize = .small
        valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        super.init(frame: NSRect(x: 0, y: 0, width: 116, height: 24))

        slider.frame = NSRect(x: 0, y: 2, width: 88, height: 20)
        valueLabel.frame = NSRect(x: 92, y: 4, width: 22, height: 16)
        addSubview(slider)
        addSubview(valueLabel)

        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.onGestureBegan = { [weak self] in self?.onGestureBegan?() }
        slider.onGestureEnded = { [weak self] in self?.onGestureEnded?() }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func sliderMoved() {
        valueLabel.stringValue = format(value)
        onChange?(value)
    }
}

/// NSSlider's mouse tracking runs a modal loop until mouse-up, so bracketing
/// `super.mouseDown` is exactly the span of one drag.
private final class TrackingSlider: NSSlider {
    var onGestureBegan: (() -> Void)?
    var onGestureEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onGestureBegan?()
        super.mouseDown(with: event)
        onGestureEnded?()
    }
}

final class SwatchButton: NSView {
    let color: NSColor
    var isActive: Bool = false { didSet { updateAppearance() } }
    var onClick: ((NSColor) -> Void)?
    /// Saved palette slots are cleared with a secondary click; the standard
    /// swatches leave this nil.
    var onSecondaryClick: ((NSColor) -> Void)?

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        wantsLayer = true
        layer?.cornerRadius = 11
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onClick?(color)
    }

    override func rightMouseDown(with event: NSEvent) {
        onSecondaryClick?(color)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Swatches are laid out at more than one size (the row's and the picker's),
    /// so the pill radius follows the frame rather than a constant.
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// Layer colours are resolved CGColors, so they are re-resolved when the
    /// effective appearance changes rather than staying frozen at the value
    /// they had when the control was built.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = color.cgColor
        // The selected swatch is ringed in the user's accent; the rest take a
        // quiet separator-weight edge.
        layer?.borderColor = (isActive
            ? ChromeTintRole.active.tintColor ?? .controlAccentColor
            : .separatorColor).cgColor
        layer?.borderWidth = isActive ? 2 : 1
    }
}

