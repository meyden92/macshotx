import AppKit

/// The Resolution box: editable width × height fields, a px/pt unit toggle
/// and a presets button. Values and unit handling belong to the hosting view;
/// this view only displays, edits and reports. Phase 7 restyles the chrome.
@MainActor
final class ResolutionBoxView: NSView, NSTextFieldDelegate {
    /// Exactly one of the two values is non-nil: the field the user committed.
    var onSizeCommitted: ((_ width: Double?, _ height: Double?) -> Void)?
    var onUnitToggled: (() -> Void)?
    var onPresetsTapped: (() -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    let widthField: NSTextField
    let heightField: NSTextField
    var presetsTitle: String { presetsButton.title }
    private let unitButton: MiniButton
    private let presetsButton: MiniButton
    private var displayedWidth = ""
    private var displayedHeight = ""
    /// Suppresses the end-editing blip while Tab hands focus between fields,
    /// so the box never re-places itself mid-edit.
    private var switchingFields = false

    private(set) var isEditing = false {
        didSet { if oldValue != isEditing { onEditingChanged?(isEditing) } }
    }

    init() {
        func makeField() -> NSTextField {
            let field = NSTextField()
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            field.alignment = .center
            field.bezelStyle = .roundedBezel
            field.isBordered = true
            return field
        }
        widthField = makeField()
        heightField = makeField()
        unitButton = MiniButton(title: "px", width: 26)
        presetsButton = MiniButton(title: "▾", width: 22)
        super.init(frame: NSRect(x: 0, y: 0, width: 210, height: 30))
        wantsLayer = true
        // Glass follows the system appearance, so the box no longer forces dark
        // styling on its fields and its text is dynamic rather than white.
        GlassChrome.installBackdrop(in: self, radius: .small)

        let times = NSTextField(labelWithString: "×")
        times.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        times.textColor = .secondaryLabelColor

        widthField.frame = NSRect(x: 8, y: 5, width: 52, height: 20)
        times.frame = NSRect(x: 63, y: 7, width: 12, height: 16)
        heightField.frame = NSRect(x: 76, y: 5, width: 52, height: 20)
        unitButton.frame.origin = NSPoint(x: 134, y: 4)
        presetsButton.frame.origin = NSPoint(x: 164, y: 4)
        widthField.delegate = self
        heightField.delegate = self
        unitButton.onClick = { [weak self] in self?.onUnitToggled?() }
        presetsButton.onClick = { [weak self] in self?.onPresetsTapped?() }
        for view in [widthField, times, heightField, unitButton, presetsButton] as [NSView] {
            addSubview(view)
        }
        frame.size.width = presetsButton.frame.maxX + 8
    }

    required init?(coder: NSCoder) { nil }

    /// The box holds still and its fields keep their text while being edited.
    func display(width: Int, height: Int, unit: String, lock: String?) {
        display(width: "\(width)", height: "\(height)", unit: unit, lock: lock)
    }

    /// No Selection yet: the box stays reachable so presets can be armed.
    func displayEmpty(unit: String, lock: String?) {
        display(width: "–", height: "–", unit: unit, lock: lock)
    }

    private func display(width: String, height: String, unit: String, lock: String?) {
        displayedWidth = width
        displayedHeight = height
        unitButton.setTitle(unit)
        // An armed aspect lock names itself on the presets button — otherwise
        // it silently reshapes every drag with nothing on screen to explain it.
        presetsButton.setTitle(lock.map { "\($0) ▾" } ?? "▾")
        frame.size.width = presetsButton.frame.maxX + 8
        if !isEditing {
            widthField.stringValue = displayedWidth
            heightField.stringValue = displayedHeight
        }
    }

    // MARK: Field behaviour

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if !switchingFields {
            isEditing = false
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let field = control as? NSTextField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(field)
            endEditing()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            commit(field)
            switchingFields = true
            window?.makeFirstResponder(field === widthField ? heightField : widthField)
            switchingFields = false
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = displayedValue(for: field)
            endEditing()
            return true
        default:
            return false
        }
    }

    private func displayedValue(for field: NSTextField) -> String {
        field === widthField ? displayedWidth : displayedHeight
    }

    private func commit(_ field: NSTextField) {
        guard let value = Double(field.stringValue), value > 0 else {
            field.stringValue = displayedValue(for: field)
            return
        }
        if field === widthField {
            onSizeCommitted?(value, nil)
        } else {
            onSizeCommitted?(nil, value)
        }
    }

    /// Hands focus back to the overlay so its shortcuts work again.
    private func endEditing() {
        isEditing = false
        window?.makeFirstResponder(superview)
        widthField.stringValue = displayedWidth
        heightField.stringValue = displayedHeight
    }
}

/// A tiny clickable text chip used inside the Resolution box.
final class MiniButton: NSView {
    var onClick: (() -> Void)?
    private let label: NSTextField
    private let minimumWidth: CGFloat

    var title: String { label.stringValue }

    init(title: String, width: CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = ChromeTintRole.neutral.contentColor
        label.alignment = .center
        self.label = label
        minimumWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        wantsLayer = true
        // A chip inside the box: its radius is the box's, less the inset.
        layer?.cornerRadius = ChromeMetrics.concentricRadius(
            parent: ChromeMetrics.RadiusTier.small.radius, inset: ChromeMetrics.tightPadding
        )
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(label)
        setTitle(title)
    }

    required init?(coder: NSCoder) { nil }

    /// The chip grows to fit its title: the presets button carries the active
    /// aspect lock's name, whose length varies.
    func setTitle(_ title: String) {
        label.stringValue = title
        let width = max(minimumWidth, ceil(label.attributedStringValue.size().width) + 10)
        frame.size.width = width
        label.frame = NSRect(x: 0, y: 3, width: width, height: 15)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// In-overlay presets panel (not a system menu): one column of rows.
@MainActor
final class PresetsPanelView: NSView {
    struct Entry {
        let title: String
        /// The row the Selection is currently constrained by; it gets a tick.
        var isActive = false
        let action: () -> Void
    }

    init(entries: [Entry]) {
        let rowHeight: CGFloat = 22
        let width: CGFloat = 120
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: width,
            height: CGFloat(entries.count) * rowHeight + 8
        ))
        wantsLayer = true
        GlassChrome.installBackdrop(in: self, radius: .small)
        for (i, entry) in entries.enumerated() {
            let row = PresetRowButton(
                title: entry.title, isActive: entry.isActive, action: entry.action
            )
            row.frame = NSRect(
                x: 4, y: 4 + CGFloat(i) * rowHeight,
                width: width - 8, height: rowHeight
            )
            addSubview(row)
        }
    }

    required init?(coder: NSCoder) { nil }
}

final class PresetRowButton: NSView {
    let title: String
    let isActive: Bool
    private let action: () -> Void

    init(title: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isActive = isActive
        self.action = action
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        super.init(frame: .zero)
        label.frame = NSRect(x: 8, y: 3, width: 84, height: 15)
        addSubview(label)
        if isActive {
            let tick = NSTextField(labelWithString: "✓")
            tick.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            tick.textColor = .controlAccentColor
            tick.frame = NSRect(x: 94, y: 3, width: 14, height: 15)
            addSubview(tick)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        action()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
