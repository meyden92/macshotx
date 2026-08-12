import AppKit
import Foundation
import UserNotifications

enum NotificationCategory {
    static let success = "MACSHOT_SUCCESS"
    static let failure = "MACSHOT_FAILURE"
}

enum NotificationActionID {
    static let reveal = "REVEAL"
    static let copyURL = "COPY_URL"
    static let showDetails = "SHOW_DETAILS"
    static let retry = "RETRY"
}

/// Success / failure notifications for capture pipelines (PRD §9.4):
/// success carries a thumbnail plus Reveal/Copy URL actions; failure offers
/// Show Details (log) and Retry (PRD §11.5).
@MainActor
enum Notifier {
    static func registerCategories() {
        let success = UNNotificationCategory(
            identifier: NotificationCategory.success,
            actions: [
                UNNotificationAction(
                    identifier: NotificationActionID.reveal,
                    title: "Reveal in Finder"
                ),
                UNNotificationAction(
                    identifier: NotificationActionID.copyURL,
                    title: "Copy URL"
                )
            ],
            intentIdentifiers: []
        )
        let failure = UNNotificationCategory(
            identifier: NotificationCategory.failure,
            actions: [
                UNNotificationAction(
                    identifier: NotificationActionID.retry,
                    title: "Retry"
                ),
                UNNotificationAction(
                    identifier: NotificationActionID.showDetails,
                    title: "Show Details"
                )
            ],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([success, failure])
    }

    static func success(
        savedURL: URL?,
        uploadedURL: String?,
        ocrText: String?,
        thumbnail: CGImage?,
        enabled: Bool
    ) async {
        guard enabled else { return }
        await ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = savedURL != nil ? "Screenshot saved" : "Capture complete"
        content.categoryIdentifier = NotificationCategory.success
        var lines: [String] = []
        if let savedURL { lines.append(savedURL.lastPathComponent) }
        if let uploadedURL { lines.append(uploadedURL) }
        if let ocrText {
            let preview = ocrText.prefix(80)
            lines.append("Text: \(preview)\(ocrText.count > 80 ? "…" : "")")
        }
        content.body = lines.joined(separator: "\n")
        if let savedURL {
            content.userInfo["filePath"] = savedURL.path
        }
        if let uploadedURL {
            content.userInfo["url"] = uploadedURL
        }
        if let thumbnail,
           let url = try? writeThumbnail(thumbnail),
           let attachment = try? UNNotificationAttachment(identifier: "thumbnail", url: url) {
            content.attachments = [attachment]
        }
        await post(content)
    }

    static func failure(
        title: String,
        error: Error,
        enabled: Bool,
        canRetry: Bool = false
    ) async {
        guard enabled else { return }
        await ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        content.categoryIdentifier = NotificationCategory.failure
        content.userInfo["canRetry"] = canRetry
        await post(content)
    }

    /// Downscaled PNG written to a temp file; the notification store consumes
    /// (moves) the attachment file, so never attach the original capture.
    private static func writeThumbnail(_ image: CGImage) throws -> URL {
        let maxDimension: CGFloat = 480
        let scale = min(
            1, maxDimension / CGFloat(image.width), maxDimension / CGFloat(image.height)
        )
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))

        var thumbnail = image
        if scale < 1, let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4 * width,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            thumbnail = ctx.makeImage() ?? image
        }

        let data = try ImageEncoder.encode(thumbnail, format: .png, quality: 100)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    private static func ensureAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    private static func post(_ content: UNNotificationContent) async {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
