import Foundation
import Testing
@testable import MacshotCore

// The permissions step tells the user to relaunch. These cover what has to
// survive that relaunch for setup to be resumable.

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("macshot-test-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
@Test
func aFreshInstallOpensTheWizardAtItsFirstPage() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ConfigStore(directory: dir)
    #expect(store.isFirstRun)
    #expect(store.config.general.setupPage == 0)
    #expect(!store.config.general.setupCompleted)
}

@MainActor
@Test
func wizardProgressSurvivesTheRelaunchThePermissionsStepAsksFor() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ConfigStore(directory: dir)
    store.update { $0.general.setupPage = 2 } // walked past the permissions page

    let relaunched = ConfigStore(directory: dir)
    #expect(!relaunched.isFirstRun)
    #expect(relaunched.config.general.setupPage == 2)
    #expect(!relaunched.config.general.setupCompleted)
}

@MainActor
@Test
func finishingTheWizardKeepsItClosedOnEveryLaterLaunch() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ConfigStore(directory: dir)
    store.update { $0.general.setupPage = 3 }
    store.update { $0.general.setupPage = nil } // Skip or Try It Now

    let relaunched = ConfigStore(directory: dir)
    #expect(relaunched.config.general.setupCompleted)
    #expect(relaunched.config.general.setupPage == nil)
}

@MainActor
@Test
func aConfigWrittenBeforeTheWizardTrackedItsProgressIsLeftAlone() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))

    // An existing config means the app has been used before: no key, no wizard.
    let store = ConfigStore(directory: dir)
    #expect(!store.isFirstRun)
    #expect(store.config.general.setupCompleted)
}

@Test
func setupProgressRoundTripsAndRejectsNonsensePages() throws {
    var config = AppConfig()
    config.general.setupPage = 2
    let decoded = try JSONDecoder().decode(
        AppConfig.self, from: JSONEncoder().encode(config)
    )
    #expect(decoded.general.setupPage == 2)

    // Finished setup encodes as an absent key, not a page number.
    config.general.setupPage = nil
    let encoded = try JSONEncoder().encode(config)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("setupPage"))

    let negative = try JSONDecoder().decode(
        AppConfig.self, from: Data(#"{"general":{"setupPage":-4}}"#.utf8)
    )
    #expect(negative.general.setupPage == 0)
}
