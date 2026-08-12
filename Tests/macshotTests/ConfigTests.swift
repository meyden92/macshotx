import Foundation
import Testing
@testable import MacshotCore

@Test
func emptyJSONDecodesToDefaults() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
    #expect(config == AppConfig())
    #expect(config.pipeline.global == [.copyImage, .saveToDisk])
    #expect(config.capture.saveDirectory == "~/Pictures/macshot")
    #expect(config.filenames.template == "Screenshot_%y-%mo-%d_%h-%mi-%s.png")
}

@Test
func configRoundTripsThroughJSON() throws {
    var config = AppConfig()
    config.general.notificationsEnabled = false
    config.capture.format = .jpeg
    config.capture.quality = 75
    config.filenames.template = "%mode/%y%mo%d_%counter"
    config.pipeline.global = [
        .openInEditor,
        .copyImage,
        .saveToDisk,
        .upload(destination: "my-r2"),
        .copyURL,
        .runShell(command: "echo $MACSHOT_PATH"),
        .openInApp(bundleID: "com.apple.Preview"),
        .extractText
    ]
    config.pipeline.window = .replace([.saveToDisk])
    var destination = Destination()
    destination.name = "my-r2"
    destination.kind = .s3
    destination.s3.bucket = "shots"
    config.destinations = [destination]
    config.hotkeys.region = HotkeyBinding(keyCode: 21, carbonModifiers: 0x1200)
    config.counters = ["/tmp/shots": 12]
    config.recents = ["/tmp/shots/a.png"]

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded == config)
}

@Test
func malformedFieldsFallBackToDefaults() throws {
    let json = """
    {
      "capture": { "format": "bmp", "quality": 9000 },
      "pipeline": { "global": [ { "type": "copyImage" } ], "window": { "mode": "nonsense" } },
      "recents": "not-an-array"
    }
    """
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.capture.format == .png)
    #expect(config.capture.quality == 100) // out-of-range clamps
    #expect(config.pipeline.global == [.copyImage])
    #expect(config.pipeline.window == .useGlobal)
    #expect(config.recents.isEmpty)
}

@Test
func pipelineActionsPerModeRespectOverrides() {
    var pipeline = PipelineSettings()
    pipeline.global = [.copyImage, .saveToDisk]
    pipeline.window = .replace([.openInEditor, .saveToDisk])

    #expect(pipeline.actions(for: .region) == [.copyImage, .saveToDisk])
    #expect(pipeline.actions(for: .window) == [.openInEditor, .saveToDisk])
    #expect(pipeline.actions(for: .fullscreen) == [.copyImage, .saveToDisk])
}

@MainActor
@Test
func configStorePersistsAndReloads() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macshot-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ConfigStore(directory: dir)
    store.update { $0.capture.format = .heic }
    store.addRecent("/tmp/a.png")
    store.addRecent("/tmp/b.png")
    store.addRecent("/tmp/a.png") // dedupes, moves to front
    #expect(store.nextCounter(forFolder: "/tmp") == 1)
    #expect(store.nextCounter(forFolder: "/tmp") == 2)

    let reloaded = ConfigStore(directory: dir)
    #expect(reloaded.config.capture.format == .heic)
    #expect(reloaded.config.recents == ["/tmp/a.png", "/tmp/b.png"])
    #expect(reloaded.config.counters["/tmp"] == 2)
}

@MainActor
@Test
func recentsAreCappedAtTen() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macshot-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ConfigStore(directory: dir)
    for index in 0..<15 {
        store.addRecent("/tmp/shot-\(index).png")
    }
    #expect(store.config.recents.count == 10)
    #expect(store.config.recents.first == "/tmp/shot-14.png")
}
