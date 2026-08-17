import AppKit
import SwiftUI

/// The watermark as it will land on a capture: a placeholder canvas in the main
/// display's aspect ratio with the configured logo drawn into it. Position, size
/// and margin come from the same `Watermark.frame` the real composite uses, so
/// the preview cannot drift from the output.
///
/// The backdrop is deliberately a neutral placeholder rather than a real
/// screenshot — it needs no permissions and is always there, and the settings it
/// visualises are relative to the capture's width anyway.
struct WatermarkPreview: View {
    let settings: WatermarkSettings

    /// Width of the drawn canvas, in points. Its height follows the display.
    private static let width: CGFloat = 320

    @State private var logo: LogoState = .missing

    private enum LogoState {
        /// No logo configured yet.
        case missing
        /// Configured, but the file could not be read.
        case unreadable
        case loaded(NSImage)
    }

    var body: some View {
        let canvas = CGSize(width: Self.width, height: Self.width / Self.displayAspect)

        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                backdrop
                if case .loaded(let image) = logo {
                    let target = Watermark.frame(
                        logo: image.size, in: canvas, settings: settings
                    )
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: target.width, height: target.height)
                        .opacity(Double(settings.opacityPercent) / 100)
                        // Watermark.frame works in CoreGraphics space (y up),
                        // SwiftUI lays out from the top.
                        .offset(x: target.minX, y: canvas.height - target.maxY)
                }
                if let hint = emptyStateHint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: canvas.width, height: canvas.height)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator)
            )

            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: settings.imagePath) { logo = Self.load(settings.imagePath) }
    }

    /// A plain gradient: something for the logo to sit on that never competes
    /// with it for attention.
    private var backdrop: some View {
        LinearGradient(
            colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var emptyStateHint: String? {
        switch logo {
        case .missing: return "Choose a logo to preview it here"
        case .unreadable: return "This image could not be read"
        case .loaded: return nil
        }
    }

    private static func load(_ path: String) -> LogoState {
        guard !path.isEmpty else { return .missing }
        let expanded = (path as NSString).expandingTildeInPath
        guard let image = NSImage(contentsOfFile: expanded), image.size.width > 0 else {
            return .unreadable
        }
        return .loaded(image)
    }

    /// The main display's aspect ratio, so the preview is shaped like the
    /// fullscreen captures the settings are most often judged against.
    private static var displayAspect: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 16.0 / 10 }
        return frame.width / frame.height
    }
}
