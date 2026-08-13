import AppKit

/// Composites a configured logo into a finished capture. Applied once, where
/// the capture is handed to the pipeline, so copy, save, upload and a second
/// pass through the editor all see the same image.
enum Watermark {
    /// Where the logo goes, in the capture's own pixels. CoreGraphics space:
    /// y grows upward, so "top" is the high end.
    static func frame(
        logo: CGSize, in canvas: CGSize, settings: WatermarkSettings
    ) -> CGRect {
        let margin = canvas.width * CGFloat(settings.marginPercent) / 100
        let available = CGSize(
            width: max(0, canvas.width - margin * 2),
            height: max(0, canvas.height - margin * 2)
        )
        // Requested width first, then whatever the margins actually leave —
        // an oversized logo shrinks rather than spilling over the edge.
        var width = canvas.width * CGFloat(settings.scalePercent) / 100
        var height = logo.width > 0 ? width * logo.height / logo.width : 0
        if width > available.width {
            height *= available.width / width
            width = available.width
        }
        if height > available.height {
            width *= available.height / height
            height = available.height
        }

        let x: CGFloat = switch settings.corner {
        case .topLeft, .bottomLeft: margin
        case .topRight, .bottomRight: canvas.width - margin - width
        }
        let y: CGFloat = switch settings.corner {
        case .bottomLeft, .bottomRight: margin
        case .topLeft, .topRight: canvas.height - margin - height
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `image` with the watermark drawn in, or `image` itself when the
    /// watermark is off, unconfigured, or its file cannot be read — a bad path
    /// must never cost the user the capture they just took.
    static func applied(to image: CGImage, _ settings: WatermarkSettings) -> CGImage {
        guard settings.enabled, !settings.imagePath.isEmpty,
              let logo = loadLogo(settings.imagePath)
        else { return image }

        let canvas = CGSize(width: image.width, height: image.height)
        let target = frame(
            logo: CGSize(width: logo.width, height: logo.height),
            in: canvas,
            settings: settings
        )
        guard target.width >= 1, target.height >= 1 else { return image }

        guard let ctx = context(for: image) else {
            // Nothing is worth losing the capture over, but a watermark the
            // user configured and does not get has to leave a trace.
            Log.error("Watermark skipped: no drawing context for this capture")
            return image
        }

        ctx.draw(image, in: CGRect(origin: .zero, size: canvas))
        ctx.setAlpha(CGFloat(settings.opacityPercent) / 100)
        ctx.draw(logo, in: target)
        guard let marked = ctx.makeImage() else {
            Log.error("Watermark skipped: the composite produced no image")
            return image
        }
        return marked
    }

    /// An 8-bit premultiplied context matching the capture. Not every colour
    /// space can back one — a grayscale or wide-gamut float capture cannot — so
    /// sRGB is the fallback rather than giving up on the watermark.
    private static func context(for image: CGImage) -> CGContext? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let spaces = [
            image.colorSpace,
            CGColorSpace(name: CGColorSpace.sRGB),
            CGColorSpaceCreateDeviceRGB()
        ]
        for space in spaces.compactMap({ $0 }) {
            if let ctx = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: bitmapInfo
            ) {
                return ctx
            }
        }
        return nil
    }

    private static func loadLogo(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Log.error("Watermark image could not be read: \(path)")
            return nil
        }
        return image
    }
}
