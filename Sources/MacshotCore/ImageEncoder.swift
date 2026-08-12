import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageEncodeError: LocalizedError {
    case encoderUnavailable(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .encoderUnavailable(let format):
            return "No encoder available for \(format)."
        case .encodeFailed(let format):
            return "Failed to encode image as \(format)."
        }
    }
}

enum ImageEncoder {
    /// Encode a bitmap in the configured output format. `quality` is 1–100
    /// and only applies to lossy formats.
    static func encode(_ image: CGImage, format: ImageFormat, quality: Int) throws -> Data {
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else {
            throw ImageEncodeError.encoderUnavailable(format.rawValue)
        }
        var properties: [CFString: Any] = [:]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] =
                Double(min(100, max(1, quality))) / 100.0
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodeError.encodeFailed(format.rawValue)
        }
        return data as Data
    }
}
