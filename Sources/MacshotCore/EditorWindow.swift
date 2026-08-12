import AppKit

/// Post-capture editor for window/fullscreen modes (PRD §6.5.2). Hosts the
/// same annotation surface as the region overlay in a normal window; the
/// select tool acts as a crop. Done resumes the pipeline with the edited
/// bitmap, Cancel (or closing the window) halts it.
@MainActor
enum EditorPresenter {
    private static var sessions: [EditorSession] = []

    static func edit(image: CGImage) async -> CGImage? {
        let session = EditorSession()
        sessions.append(session)
        defer { sessions.removeAll { $0 === session } }
        return await session.run(image: image)
    }
}

@MainActor
final class EditorSession: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var hasResumed = false

    func run(image: CGImage) async -> CGImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(image: image)
        }
    }

    private func present(image: CGImage) {
        let screen = NSScreen.main
        let backingScale = screen?.backingScaleFactor ?? 2

        // Natural size in points, fitted into 85% of the visible screen.
        var viewSize = NSSize(
            width: CGFloat(image.width) / backingScale,
            height: CGFloat(image.height) / backingScale
        )
        let available = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let fit = min(
            1,
            available.width * 0.85 / viewSize.width,
            available.height * 0.85 / viewSize.height
        )
        viewSize = NSSize(
            width: max(1, floor(viewSize.width * fit)),
            height: max(1, floor(viewSize.height * fit))
        )

        let view = RegionPickerView(
            frame: NSRect(origin: .zero, size: viewSize),
            image: image,
            scale: CGFloat(image.width) / viewSize.width,
            styles: ConfigStore.shared.config.editorStyles,
            onStylesChanged: { styles in
                ConfigStore.shared.update { $0.editorStyles = styles }
            },
            requiresSelection: false,
            selectionPrefs: ConfigStore.shared.config.selection,
            onSelectionPrefsChanged: { prefs in
                ConfigStore.shared.update { $0.selection = prefs }
            },
            beautifyDefaults: ConfigStore.shared.config.beautify,
            onBeautifyDefaultsChanged: { defaults in
                ConfigStore.shared.update { $0.beautify = defaults }
            }
        )
        view.onCommit = { [weak self] edited in self?.finish(with: edited) }
        view.onCancel = { [weak self] in self?.finish(with: nil) }

        // Container centers the picker view; the toolbar needs a minimum width.
        let contentSize = NSSize(
            width: max(viewSize.width, 900),
            height: max(viewSize.height, 320)
        )
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.setFrameOrigin(NSPoint(
            x: floor((contentSize.width - viewSize.width) / 2),
            y: floor((contentSize.height - viewSize.height) / 2)
        ))
        container.addSubview(view)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Capture — macshot"
        window.delegate = self
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }

    private func finish(with image: CGImage?) {
        guard !hasResumed else { return }
        hasResumed = true
        if let window {
            window.delegate = nil
            window.orderOut(nil)
        }
        window = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: image)
    }
}
