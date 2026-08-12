import CoreGraphics
import Vision

enum OCRError: LocalizedError {
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .noTextFound:
            return "No text was recognized in the capture."
        }
    }
}

/// On-device text recognition via Apple Vision (PRD §6.4.1). No network calls.
enum OCRService {
    static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw OCRError.noTextFound }
        return lines.joined(separator: "\n")
    }
}
