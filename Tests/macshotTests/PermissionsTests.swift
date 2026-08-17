import Testing
import UserNotifications
@testable import MacshotCore

// The panel is only useful if every permission it lists can be acted on: a
// status the user understands, and a route to fix it when it is missing.

@Test
func everyPermissionNamesItselfAndPointsAtItsSystemSettingsPane() {
    for permission in SystemPermission.allCases {
        #expect(!permission.title.isEmpty)
        #expect(!permission.purpose.isEmpty)
        #expect(permission.settingsURL.scheme == "x-apple.systempreferences")
    }
    // Capture is the whole app; banners are a nicety.
    #expect(SystemPermission.screenRecording.isRequired)
    #expect(!SystemPermission.notifications.isRequired)
}

@Test
func notificationAuthorizationMapsOntoTheThreeStatusesTheRowsShow() {
    #expect(PermissionStatus(.authorized) == .granted)
    #expect(PermissionStatus(.notDetermined) == .notDetermined)
    #expect(PermissionStatus(.denied) == .notGranted)
    // Provisional delivers quietly — no banners, so not what the row promises.
    #expect(PermissionStatus(.provisional) == .notGranted)
}

@Test
func requestIsOfferedOnlyWhenAPromptCouldStillDoSomething() {
    // Notifications prompt exactly once; after a refusal only System Settings helps.
    #expect(SystemPermission.notifications.canRequest(.notDetermined))
    #expect(!SystemPermission.notifications.canRequest(.notGranted))
    #expect(!SystemPermission.notifications.canRequest(.granted))

    // Screen Recording's preflight cannot tell "never asked" from "refused",
    // so the request stays available until it is granted.
    #expect(SystemPermission.screenRecording.canRequest(.notGranted))
    #expect(SystemPermission.screenRecording.canRequest(.notDetermined))
    #expect(!SystemPermission.screenRecording.canRequest(.granted))
}

@MainActor
@Test
func anUncheckedPermissionReadsAsUnknownRatherThanGranted() {
    // Rows must never claim a grant the app has not actually observed.
    let model = PermissionsModel()
    #expect(model.status(.screenRecording) == nil)
    #expect(model.status(.notifications) == nil)
}

// A capture that starts without Screen Recording used to lock the machine out
// of its own screen: the overlay went up while ScreenCaptureKit was still
// waiting for the user to answer a prompt the overlay itself covered.

@MainActor
@Test
func aCaptureWithoutScreenRecordingAsksBeforeAnythingIsOnScreen() {
    var prompts = 0
    let allowed = CaptureService.screenRecordingAllowed(
        preflight: { false }, request: { prompts += 1 }
    )
    #expect(!allowed, "the overlay must not go up while the prompt is unanswered")
    #expect(prompts == 1)
}

@MainActor
@Test
func aGrantedCaptureIsNotAskedAboutAgain() {
    var prompts = 0
    let allowed = CaptureService.screenRecordingAllowed(
        preflight: { true }, request: { prompts += 1 }
    )
    #expect(allowed)
    #expect(prompts == 0)
}

@Test
func theDeniedCaptureNamesThePaneThatFixesIt() {
    let message = CaptureError.screenRecordingDenied.errorDescription ?? ""
    #expect(message.contains("Screen Recording"))
    #expect(message.contains("System Settings"))
}
