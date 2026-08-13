import AppKit
@testable import MacshotCore

extension RegionPickerView {
    /// Draws the overlay into `rep` with the chrome hidden.
    ///
    /// The chrome is a dark HUD floating over the overlay, and on the 200×200
    /// canvas these tests host it covers most of the frame — the toolbar strip
    /// alone is wider than the whole view. Pixel assertions about what the
    /// overlay itself paints (the Selection dim, a live pixelate preview) have
    /// to sample underneath it, or they measure the chrome and move every time
    /// the chrome's layout or material changes.
    @MainActor
    func cacheDisplayWithoutChrome(to rep: NSBitmapImageRep) {
        let chrome = subviews.filter { !$0.isHidden }
        chrome.forEach { $0.isHidden = true }
        defer { chrome.forEach { $0.isHidden = false } }
        cacheDisplay(in: bounds, to: rep)
    }
}
