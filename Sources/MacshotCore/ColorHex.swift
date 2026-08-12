import AppKit

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA" (with or without the hash) → sRGB color. A
    /// six-digit value decodes fully opaque, so config written before opacity
    /// existed still means what it always meant.
    convenience init?(hexString: String) {
        let hex = Self.strippedHex(hexString)
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else {
            return nil
        }
        let carriesAlpha = hex.count == 8
        let rgb = carriesAlpha ? value >> 8 : value
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: carriesAlpha ? CGFloat(value & 0xFF) / 255 : 1
        )
    }

    /// Whether a stored value carries its own alpha. Callers that used to
    /// supply a default alpha use this to tell "the user chose opaque" from
    /// "this value predates the choice".
    static func hexStringCarriesAlpha(_ hexString: String) -> Bool {
        strippedHex(hexString).count == 8
    }

    /// "#RRGGBB" of the color's sRGB components (alpha dropped) — the color
    /// sampler's user-facing output format.
    var hexRGBString: String {
        let c = components
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// "#RRGGBBAA" — the persisted form, so a chosen opacity survives relaunch.
    var hexRGBAString: String {
        let c = components
        return String(format: "#%02X%02X%02X%02X", c.r, c.g, c.b, c.a)
    }

    private static func strippedHex(_ hexString: String) -> String {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        return hex
    }

    private var components: (r: Int, g: Int, b: Int, a: Int) {
        guard let srgb = usingColorSpace(.sRGB) else { return (0, 0, 0, 255) }
        return (
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()),
            Int((srgb.alphaComponent * 255).rounded())
        )
    }
}
