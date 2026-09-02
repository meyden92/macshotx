import CoreGraphics
import Foundation
import Testing
@testable import MacshotCore

// MARK: - Session model: selection ownership

@Test
func startingSelectionClearsTheOtherDisplaysSelection() {
    var model = CaptureSessionModel(displayCount: 3, snapArmed: false)
    #expect(model.startSelection(on: 0) == [])
    #expect(model.selectionOwner == 0)
    #expect(model.startSelection(on: 2) == [0])
    #expect(model.selectionOwner == 2)
    // Re-selecting on the owning display clears nothing.
    #expect(model.startSelection(on: 2) == [])
}

@Test
func clearingSelectionOnlyAffectsTheOwner() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    _ = model.startSelection(on: 1)
    model.clearSelection(on: 0)
    #expect(model.selectionOwner == 1)
    model.clearSelection(on: 1)
    #expect(model.selectionOwner == nil)
}

// MARK: - Session model: snap toggling

@Test
func tabTogglesSnapOnlyWhileNoSelectionExists() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    var changed = model.toggleSnap()
    #expect(changed)
    #expect(model.snapArmed)
    changed = model.toggleSnap()
    #expect(changed)
    #expect(!model.snapArmed)

    _ = model.startSelection(on: 0)
    changed = model.toggleSnap()
    #expect(!changed)
    #expect(!model.snapArmed)

    // Selection cleared: Tab works again.
    model.clearSelection(on: 0)
    changed = model.toggleSnap()
    #expect(changed)
    #expect(model.snapArmed)
}

// MARK: - Session model: pending images, held commits

/// A confirmed Selection; which rectangle it is never changes a transition.
private let unitRect = CGRect(x: 0, y: 0, width: 10, height: 10)

@Test
func commitBeforeImageArrivesIsHeldThenPerformed() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    let rect = CGRect(x: 5, y: 5, width: 50, height: 40)
    #expect(model.requestCommit(on: 1, rect: rect) == .held)
    #expect(model.resolution == .pending)

    // Another display's image landing does not release the held commit.
    #expect(model.imageArrived(on: 0) == nil)
    #expect(model.resolution == .pending)

    let held = model.imageArrived(on: 1)
    #expect(held == CaptureSessionModel.HeldCommit(display: 1, rect: rect))
    #expect(model.resolution == .committed)
}

@Test
func commitAfterImageArrivedPerformsImmediately() {
    var model = CaptureSessionModel(displayCount: 1, snapArmed: false)
    _ = model.imageArrived(on: 0)
    #expect(model.requestCommit(on: 0, rect: unitRect) == .perform)
    #expect(model.resolution == .committed)
}

@Test
func cancelIsNeverHeld() {
    var model = CaptureSessionModel(displayCount: 2, snapArmed: false)
    #expect(model.cancel() == true)
    #expect(model.resolution == .cancelled)
    // No transition escapes a resolved session — a screenshot failure
    // routes through the same cancel.
    #expect(model.imageArrived(on: 0) == nil)
    #expect(model.requestCommit(on: 0, rect: unitRect) == .ignored)
    let cancelledAgain = model.cancel()
    #expect(!cancelledAgain)
}

@Test
func cancelWinsOverAHeldCommit() {
    var model = CaptureSessionModel(displayCount: 1, snapArmed: false)
    #expect(model.requestCommit(on: 0, rect: unitRect) == .held)
    let cancelled = model.cancel()
    #expect(cancelled)
    // The image landing later must not resurrect the held commit.
    #expect(model.imageArrived(on: 0) == nil)
    #expect(model.resolution == .cancelled)
}

@Test
func sessionResolvesExactlyOnce() {
    var model = CaptureSessionModel(displayCount: 1, snapArmed: false)
    _ = model.imageArrived(on: 0)
    #expect(model.requestCommit(on: 0, rect: unitRect) == .perform)
    #expect(model.requestCommit(on: 0, rect: unitRect) == .ignored)
    let cancelAfterCommit = model.cancel()
    #expect(!cancelAfterCommit)
    #expect(model.resolution == .committed)
}

// MARK: - Hotkey actions

@Test
func thereIsOneCaptureHotkeyAndTwoUtilityHotkeys() {
    // No entry point can pre-arm snap or pick what gets captured: the only
    // capture action there is opens the overlay (ADR 0010).
    #expect(HotkeyAction.allCases == [.capture, .colorPicker, .magnifier])
}

@Test
func aConfigFromBeforeTheHotkeysCollapsedLoadsWithTheDefaultCaptureHotkey() throws {
    let legacy = """
    {
      "hotkeys": {
        "region": { "keyCode": 30, "carbonModifiers": 256 },
        "window": { "keyCode": 31, "carbonModifiers": 256 },
        "fullscreen": { "keyCode": 32, "carbonModifiers": 256 }
      }
    }
    """
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
    #expect(config.hotkeys == HotkeySettings())
}

// MARK: - Helper card content

@Test
func helperCardWordingFollowsTheSnapState() throws {
    let on = try #require(HelperCard.content(snapArmed: true, suppressed: false))
    let off = try #require(HelperCard.content(snapArmed: false, suppressed: false))
    #expect(on.instruction != off.instruction)
    #expect(on.instruction.contains("window"))
    #expect(on.instruction.contains("F for fullscreen"))
    #expect(off.instruction.contains("F for fullscreen"))
    #expect(on.status == "Window snap: ON (Tab)")
    #expect(off.status == "Window snap: OFF (Tab)")
}

@Test
func helperCardNamesEveryRouteAndPromisesNoCapture() throws {
    // Every route seeds the Selection now, so a card claiming that a click
    // captures would be a lie (ADR 0011).
    for armed in [true, false] {
        let card = try #require(HelperCard.content(snapArmed: armed, suppressed: false))
        let text = card.instruction + " " + card.status
        #expect(text.contains("drag") || text.contains("Drag"))
        #expect(text.contains("F for fullscreen"))
        #expect(text.lowercased().contains("window"))
        #expect(!card.instruction.lowercased().contains("captur"))
    }
}

@Test
func suppressedHelperCardProducesNothing() {
    #expect(HelperCard.content(snapArmed: true, suppressed: true) == nil)
    #expect(HelperCard.content(snapArmed: false, suppressed: true) == nil)
}

// MARK: - Settings round-trip for the suppression flag

@Test
func configWithoutOverlayHintsFlagDecodesToDefault() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
    #expect(config.capture.showOverlayHints)
}

@Test
func overlayHintsFlagRoundTrips() throws {
    var config = AppConfig()
    config.capture.showOverlayHints = false
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(!decoded.capture.showOverlayHints)
}

// MARK: - Window snap resolver

private func candidate(
    id: UInt32,
    _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
    bundle: String? = "com.example.app",
    layer: Int = 0,
    onScreen: Bool = true
) -> WindowCandidate {
    WindowCandidate(
        id: id,
        frame: CGRect(x: x, y: y, width: w, height: h),
        bundleIdentifier: bundle,
        layer: layer,
        isOnScreen: onScreen
    )
}

@Test
func topmostContainingWindowWins() {
    let front = candidate(id: 1, 100, 100, 400, 300)
    let back = candidate(id: 2, 0, 0, 900, 900)
    let hit = WindowSnapResolver.resolve(
        [front, back], at: CGPoint(x: 200, y: 200), ownBundleID: nil
    )
    #expect(hit?.id == 1)
    // Outside the front window, the one behind wins.
    let behind = WindowSnapResolver.resolve(
        [front, back], at: CGPoint(x: 700, y: 700), ownBundleID: nil
    )
    #expect(behind?.id == 2)
}

@Test
func fullyCoveredWindowIsNeverOffered() {
    let front = candidate(id: 1, 0, 0, 800, 600)
    let covered = candidate(id: 2, 100, 100, 200, 200)
    let back = candidate(id: 3, 0, 0, 2000, 2000)
    // Even a point only inside the covered window resolves to what covers it.
    let hit = WindowSnapResolver.resolve(
        [front, covered, back], at: CGPoint(x: 150, y: 150), ownBundleID: nil
    )
    #expect(hit?.id == 1)
}

@Test
func exactlyOverlappingFramesResolveToTheFrontOne() {
    let front = candidate(id: 1, 50, 50, 300, 300)
    let twin = candidate(id: 2, 50, 50, 300, 300)
    let hit = WindowSnapResolver.resolve(
        [front, twin], at: CGPoint(x: 60, y: 60), ownBundleID: nil
    )
    #expect(hit?.id == 1)
}

@Test
func resolverExcludesIneligibleWindows() {
    let own = candidate(id: 1, 0, 0, 500, 500, bundle: "com.example.macshot")
    let offScreen = candidate(id: 2, 0, 0, 500, 500, onScreen: false)
    let zeroArea = candidate(id: 3, 0, 0, 0, 0)
    let desktop = candidate(id: 4, 0, 0, 500, 500, layer: -2147483623)
    let statusBar = candidate(id: 5, 0, 0, 500, 500, layer: 25)
    let normal = candidate(id: 6, 0, 0, 500, 500)
    let hit = WindowSnapResolver.resolve(
        [own, offScreen, zeroArea, desktop, statusBar, normal],
        at: CGPoint(x: 10, y: 10),
        ownBundleID: "com.example.macshot"
    )
    #expect(hit?.id == 6)
}

@Test
func pointOverNothingResolvesToNothing() {
    let window = candidate(id: 1, 100, 100, 100, 100)
    let hit = WindowSnapResolver.resolve(
        [window], at: CGPoint(x: 900, y: 900), ownBundleID: nil
    )
    #expect(hit == nil)
}

@Test
func coveredWindowDoesNotShadowWhatIsBehindTheCoveringWindow() {
    // 2 is fully inside 1 (dropped); a point outside 1 but inside 3 must
    // still reach 3.
    let front = candidate(id: 1, 0, 0, 400, 400)
    let covered = candidate(id: 2, 10, 10, 100, 100)
    let back = candidate(id: 3, 0, 0, 1000, 1000)
    let hit = WindowSnapResolver.resolve(
        [front, covered, back], at: CGPoint(x: 600, y: 600), ownBundleID: nil
    )
    #expect(hit?.id == 3)
}

// MARK: - Snap hit-testing per display (#52)

@Test
func hoverOnANonPrimaryDisplayMapsThroughThatDisplaysQuartzOrigin() {
    // External display to the right of a 1512-wide primary.
    let display = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let window = candidate(id: 7, 2000, 100, 400, 300)
    let hit = WindowSnapResolver.target(
        in: [window], displayFrame: display, localPoint: CGPoint(x: 600, y: 200)
    )
    #expect(hit?.candidate.id == 7)
    // The highlight rect comes back in the display's own view space.
    #expect(hit?.rect == CGRect(x: 488, y: 100, width: 400, height: 300))
    // The same local point on a display that has no window there: nothing.
    let miss = WindowSnapResolver.target(
        in: [window], displayFrame: display, localPoint: CGPoint(x: 100, y: 100)
    )
    #expect(miss == nil)
}

@Test
func hoverOnADisplayLeftOfAndAboveThePrimaryUsesNegativeOrigins() {
    let display = CGRect(x: -2560, y: -458, width: 2560, height: 1440)
    let window = candidate(id: 3, -2000, -300, 500, 500)
    let hit = WindowSnapResolver.target(
        in: [window], displayFrame: display, localPoint: CGPoint(x: 700, y: 300)
    )
    #expect(hit?.candidate.id == 3)
    #expect(hit?.rect == CGRect(x: 560, y: 158, width: 500, height: 500))
}
