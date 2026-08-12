import AppKit

/// The visual language of overlay chrome, in one place. Every chrome surface
/// reads its numbers from here; no chrome code carries a literal radius, inset
/// or control size again, which is what stops the next control inventing a
/// sixth visual language.
enum ChromeMetrics {
    /// Radius tiers. Large is for surfaces (toolbar strip, cards, panels),
    /// small for pills and buttons inside them, tooltip for the little chips.
    enum RadiusTier {
        case large, small, tooltip

        var radius: CGFloat {
            switch self {
            case .large: return 16
            case .small: return 9
            case .tooltip: return 8
            }
        }
    }

    /// Padding scale.
    static let padding: CGFloat = 8
    static let tightPadding: CGFloat = 4
    /// Standard control height, and the shorter one the option controls use.
    static let controlHeight: CGFloat = 36
    static let optionControlHeight: CGFloat = 24
    /// How far apart two chrome surfaces sit before they read as separate.
    static let surfaceSpacing: CGFloat = 8
    static let symbolPointSize: CGFloat = 16
    static let symbolWeight: NSFont.Weight = .medium

    /// Concentricity: an inner surface inset by `inset` inside a parent of
    /// `parent` radius takes the parent's radius minus that inset, so a nested
    /// pill sits inside its container instead of looking bolted on.
    static func concentricRadius(parent: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, parent - inset)
    }
}

/// The closed set of chrome tints. Colours are the dynamic system ones,
/// resolved when they are drawn — the accent roles read the user's control
/// accent, never a hard-coded blue.
enum ChromeTintRole {
    case neutral
    case active
    case primary
    case destructive

    /// Nil means untinted glass, which is what a strip, a card or a tooltip
    /// wants.
    var tintColor: NSColor? {
        switch self {
        case .neutral: return nil
        case .active, .primary: return .controlAccentColor
        case .destructive: return .systemRed
        }
    }

    /// What a label or symbol on this surface should be drawn in.
    var contentColor: NSColor {
        switch self {
        case .neutral: return .labelColor
        case .active, .primary, .destructive: return .white
        }
    }
}

/// Which material the chrome should use. A pure function of the accessibility
/// flags, so it is testable without rendering anything.
enum ChromeMaterial: Equatable {
    case glass
    /// The system's own reduced material — never a hand-mixed opaque colour.
    case reduced

    static func resolve(reduceTransparency: Bool) -> ChromeMaterial {
        reduceTransparency ? .reduced : .glass
    }

    static var current: ChromeMaterial {
        resolve(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }
}

/// Builds overlay chrome surfaces. Chrome code never constructs a glass view
/// itself, so the rules about content placement and tint are honoured by
/// construction rather than remembered.
@MainActor
enum GlassChrome {
    /// A glass surface wrapping `content`. The content is assigned as the glass
    /// view's own `contentView`, which is the only placement the platform makes
    /// z-order and legibility guarantees for.
    static func surface(
        _ content: NSView,
        radius: ChromeMetrics.RadiusTier = .large,
        tint: ChromeTintRole = .neutral
    ) -> NSView {
        switch ChromeMaterial.current {
        case .glass:
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius.radius
            glass.tintColor = tint.tintColor
            glass.contentView = content
            glass.frame = content.frame
            content.frame = CGRect(origin: .zero, size: content.frame.size)
            content.autoresizingMask = [.width, .height]
            return glass
        case .reduced:
            let effect = reducedMaterialView(radius: radius, tint: tint)
            effect.frame = content.frame
            content.frame = CGRect(origin: .zero, size: content.frame.size)
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            return effect
        }
    }

    /// Installs the same material *behind* a chrome view that owns its own
    /// children, rather than around it. Used where a view's children are part
    /// of its published shape and moving them inside a content view would
    /// change the hierarchy rather than the clothing — AppKit guarantees
    /// sibling z-order, so the content still draws above the material.
    static func installBackdrop(
        in view: NSView,
        radius: ChromeMetrics.RadiusTier = .large,
        tint: ChromeTintRole = .neutral
    ) {
        let backdrop: NSView
        switch ChromeMaterial.current {
        case .glass:
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius.radius
            glass.tintColor = tint.tintColor
            backdrop = glass
        case .reduced:
            backdrop = reducedMaterialView(radius: radius, tint: tint)
        }
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.width, .height]
        // Never in front of the content, and never in the way of a click.
        view.addSubview(backdrop, positioned: .below, relativeTo: nil)
    }

    /// Groups nearby surfaces so they sample their backdrop once, consistently,
    /// and merge fluidly instead of sampling each other.
    static func container(spacing: CGFloat = ChromeMetrics.surfaceSpacing) -> NSView {
        guard ChromeMaterial.current == .glass else { return NSView() }
        let container = NSGlassEffectContainerView()
        container.spacing = spacing
        return container
    }

    private static func reducedMaterialView(
        radius: ChromeMetrics.RadiusTier, tint: ChromeTintRole
    ) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius.radius
        effect.layer?.masksToBounds = true
        if let tintColor = tint.tintColor {
            let tintLayer = NSView()
            tintLayer.wantsLayer = true
            tintLayer.layer?.backgroundColor = tintColor.withAlphaComponent(0.85).cgColor
            tintLayer.frame = effect.bounds
            tintLayer.autoresizingMask = [.width, .height]
            effect.addSubview(tintLayer)
        }
        return effect
    }
}

/// A view that never takes a click. Chrome material and purely decorative
/// affordances use it so the overlay's own hit-testing is untouched.
final class NonInteractiveView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
