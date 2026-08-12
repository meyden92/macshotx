import Foundation

enum UploadError: LocalizedError {
    case invalidConfiguration(String)
    case requestFailed(String)
    case badResponse(status: Int, body: String)
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "Destination misconfigured: \(reason)"
        case .requestFailed(let reason):
            return "Upload failed: \(reason)"
        case .badResponse(let status, let body):
            let preview = body.prefix(200)
            return "Upload failed with HTTP \(status): \(preview)"
        case .missingSecret(let what):
            return "Missing secret in Keychain: \(what)"
        }
    }
}

struct UploadResult: Sendable {
    var url: String?
    var thumbnailURL: String?
    var deletionURL: String?

    init(url: String?, thumbnailURL: String? = nil, deletionURL: String? = nil) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.deletionURL = deletionURL
    }
}

enum UploadService {
    /// Upload encoded image bytes to a configured destination.
    static func upload(
        data: Data,
        filename: String,
        destination: Destination
    ) async throws -> UploadResult {
        let contentType = contentType(for: filename)
        switch destination.kind {
        case .s3:
            return try await S3Uploader.upload(
                data: data, filename: filename,
                destination: destination, contentType: contentType
            )
        case .sftp:
            return try await ServerUploaders.uploadSFTP(
                data: data, filename: filename, destination: destination
            )
        case .ftp:
            return try await ServerUploaders.uploadFTP(
                data: data, filename: filename, destination: destination
            )
        case .webdav:
            return try await ServerUploaders.uploadWebDAV(
                data: data, filename: filename, destination: destination
            )
        case .customHTTP:
            return try await CustomUploader.upload(
                data: data, filename: filename,
                destination: destination, contentType: contentType
            )
        }
    }

    static func contentType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}
