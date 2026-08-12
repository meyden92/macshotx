import AppKit

/// Text measurement and attributes for text and callout annotations. One place
/// builds the attributes, so the renderer, the bake, the inline editor and the
/// box arithmetic can never disagree about what the text looks like.
enum TextLayout {
    /// The box a bare click gets, so click-to-type still feels like it always
    /// did — the user types rather than sizing a box first.
    static let defaultBoxSize = CGSize(width: 220, height: 30)
    /// Nothing narrower than this is useful, and a zero-width box would make
    /// wrapping meaningless.
    static let minimumBoxSize = CGSize(width: 24, height: 16)
    /// How far a callout's bubble stands off its text box.
    static let calloutPadding = CGSize(width: 10, height: 6)

    /// The families offered by the font popup, system first.
    static var fontFamilies: [String] {
        [systemFamilyName] + NSFontManager.shared.availableFontFamilies.sorted()
    }

    /// The label the popup shows for "whatever the system font is".
    static let systemFamilyName = "System"

    static func font(for style: TextStyle) -> NSFont {
        let size = style.fontSize
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }

        let base: NSFont
        if style.fontFamily.isEmpty || style.fontFamily == systemFamilyName {
            base = NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
            guard style.italic else { return base }
        } else if let family = NSFontManager.shared.font(
            withFamily: style.fontFamily, traits: traits, weight: style.bold ? 9 : 5, size: size
        ) {
            return family
        } else {
            base = NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        }
        // A family that has no italic cut keeps the upright face rather than
        // falling back to a different family.
        return NSFontManager.shared.convert(base, toHaveTrait: traits) 
    }

    static func paragraphStyle(for style: TextStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = style.alignment.nsAlignment
        return paragraph
    }

    static func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style),
            .foregroundColor: style.color,
            .paragraphStyle: paragraphStyle(for: style)
        ]
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// The same text set up to stroke its glyph outlines only. Drawn under the
    /// filled pass, so half the centred stroke ends up covered and the fill's
    /// own edge stays crisp.
    static func outlineAttributes(for style: TextStyle) -> [NSAttributedString.Key: Any]? {
        guard let outline = style.outlineColor, style.outlineWidth > 0 else { return nil }
        var attributes = attributes(for: style)
        attributes[.strokeColor] = outline
        // NSAttributedString measures stroke width as a percentage of the font
        // size; positive means stroke without filling.
        attributes[.strokeWidth] = style.outlineWidth / max(style.fontSize, 1) * 100 * 2
        attributes[.foregroundColor] = NSColor.clear
        return attributes
    }

    static func attributed(_ content: String, style: TextStyle) -> NSAttributedString {
        NSAttributedString(string: content, attributes: attributes(for: style))
    }

    /// The height this content needs when wrapped to `width`.
    static func height(_ content: String, style: TextStyle, width: CGFloat) -> CGFloat {
        let text = content.isEmpty ? " " : content
        let bounds = attributed(text, style: style).boundingRect(
            with: CGSize(width: max(width, minimumBoxSize.width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height)
    }

    /// The box as it is actually drawn: the width the user chose, and enough
    /// height for the content to fit. The box grows downward rather than
    /// clipping, so text is never invisible.
    static func fittedBox(_ box: CGRect, content: String, style: TextStyle) -> CGRect {
        let width = max(box.width, minimumBoxSize.width)
        let needed = height(content, style: style, width: width)
        return CGRect(
            x: box.minX,
            y: box.minY,
            width: width,
            height: max(max(box.height, minimumBoxSize.height), needed)
        )
    }
}

/// The inline editor: a plain multi-line text view styled to match how the
/// annotation will finally render, so what is typed is what gets baked. The
/// single-line field it replaces could not wrap, and wrapping is the whole
/// point of the text box.
final class InlineTextView: NSTextView {
    private var placeholder = ""

    /// Configured after construction rather than in an initialiser: NSTextView
    /// builds its whole text stack in `init(frame:)`, and going through
    /// `init(frame:textContainer:)` with no container leaves it with no text
    /// storage at all — the view then silently swallows everything set on it.
    func prepare() {
        isRichText = false
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = NSColor.white.withAlphaComponent(0.92)
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
    }

    func applyStyle(_ style: TextStyle, placeholder: String) {
        self.placeholder = placeholder
        font = TextLayout.font(for: style)
        textColor = style.color
        insertionPointColor = style.color
        alignment = style.alignment.nsAlignment
        defaultParagraphStyle = TextLayout.paragraphStyle(for: style)
        typingAttributes = TextLayout.attributes(for: style)
        // The editor shows the annotation's own plate when it has one, so what
        // is typed reads the way it will be baked.
        backgroundColor = style.backgroundColor ?? NSColor.white.withAlphaComponent(0.92)
        if !string.isEmpty {
            textStorage?.setAttributes(
                TextLayout.attributes(for: style),
                range: NSRange(location: 0, length: (string as NSString).length)
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 22),
            .foregroundColor: NSColor.black.withAlphaComponent(0.3)
        ]
        (placeholder as NSString).draw(at: .zero, withAttributes: attributes)
    }
}

/// The independent typography toggles. They combine, so they are separate
/// on/offs rather than segments of one control.
enum TextTrait: CaseIterable {
    case bold, italic, underline, strikethrough

    var order: Int {
        switch self {
        case .bold: return 0
        case .italic: return 1
        case .underline: return 2
        case .strikethrough: return 3
        }
    }

    func isOn(in style: AnnotationStyle) -> Bool {
        switch self {
        case .bold: return style.bold ?? false
        case .italic: return style.italic ?? false
        case .underline: return style.underline ?? false
        case .strikethrough: return style.strikethrough ?? false
        }
    }

    func write(_ on: Bool, into style: inout AnnotationStyle) {
        switch self {
        case .bold: style.bold = on
        case .italic: style.italic = on
        case .underline: style.underline = on
        case .strikethrough: style.strikethrough = on
        }
    }
}

extension TextStyle {
    /// The typography axes as they are persisted, and back again. Colour and
    /// size stay in their own long-standing config fields.
    var richDefaults: RichTextDefaults {
        var defaults = RichTextDefaults()
        defaults.fontFamily = fontFamily
        defaults.bold = bold
        defaults.italic = italic
        defaults.underline = underline
        defaults.strikethrough = strikethrough
        defaults.alignment = alignment.rawValue
        defaults.backgroundColorHex = backgroundColor?.hexRGBAString ?? ""
        defaults.outlineColorHex = outlineColor?.hexRGBAString ?? ""
        defaults.outlineWidth = outlineWidth
        return defaults
    }

    func withRichDefaults(_ defaults: RichTextDefaults) -> TextStyle {
        var style = self
        style.fontFamily = defaults.fontFamily
        style.bold = defaults.bold
        style.italic = defaults.italic
        style.underline = defaults.underline
        style.strikethrough = defaults.strikethrough
        style.alignment = TextAlignment(rawValue: defaults.alignment) ?? .left
        style.backgroundColor = NSColor(hexString: defaults.backgroundColorHex)
        style.outlineColor = NSColor(hexString: defaults.outlineColorHex)
        style.outlineWidth = defaults.outlineWidth
        return style
    }
}
