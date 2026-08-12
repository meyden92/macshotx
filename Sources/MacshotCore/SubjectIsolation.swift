import CoreGraphics
import CoreImage
import Vision

/// Lifts the photographic subject out of an image, returning a mask where white
/// is subject and black is background, or nil when there is no subject to find.
///
/// The overlay takes this as an injected, defaulted dependency: it is the only
/// new injection point in the phase, and it exists so the "subject found" and
/// "no subject" branches are testable without depending on how a model behaves
/// against a synthetic bitmap.
typealias SubjectIsolator = @Sendable (CGImage) async -> CGImage?

enum SubjectIsolation {
    /// Longest edge the mask is computed at. Vision does not need the full
    /// capture to find a subject, and the mask scales up smoothly.
    static let workingSize: CGFloat = 1024

    static let live: SubjectIsolator = { image in
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else {
                return nil
            }
            let buffer = try result.generateScaledMaskForImage(
                forInstances: result.allInstances, from: handler
            )
            let ciImage = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(ciImage, from: ciImage.extent)
        } catch {
            Log.error("Subject isolation failed: \(error)")
            return nil
        }
    }

    /// `image` with everything outside the mask made transparent. The mask is
    /// scaled to the image with smooth interpolation, so a mask computed at a
    /// bounded working size still cuts cleanly at full resolution.
    static func applying(mask: CGImage, to image: CGImage) -> CGImage? {
        guard let scaled = scale(mask, to: CGSize(width: image.width, height: image.height)),
              let masked = image.masking(scaled)
        else { return nil }
        // Bake the mask into real alpha rather than leaving a masked image,
        // which several downstream paths (encoding, further compositing) treat
        // as opaque.
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(masked, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// A greyscale copy of `mask` at `size`, which is the form `masking` wants.
    private static func scale(_ mask: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width >= 1, height >= 1,
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
