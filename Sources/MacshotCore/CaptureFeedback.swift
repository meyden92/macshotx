import AppKit

@MainActor
enum CaptureFeedback {
    static func play() {
        NSSound(named: NSSound.Name("Tink"))?.play()
        flash()
    }

    private static func flash() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSPointInRect(mouseLocation, $0.frame) }) else {
            return
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let flashView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        flashView.wantsLayer = true
        flashView.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = flashView

        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            // Animation completions arrive on the main thread.
            MainActor.assumeIsolated {
                window.orderOut(nil)
            }
        })
    }
}
