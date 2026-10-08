import Foundation
import Testing
@testable import MacshotCore

@Test
func emptyJSONDecodesToDefaults() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
    #expect(config == AppConfig())
    #expect(config.pipelines.map(\.name) == ["Default"])
    #expect(config.pipelines.map(\.actions) == [[.copyImage, .saveToDisk]])
    #expect(config.capture.saveDirectory == "~/Pictures/macshot")
    #expect(config.filenames.template == "Screenshot_%y-%mo-%d_%h-%mi-%s.png")
}

@Test
func configRoundTripsThroughJSON() throws {
    var config = AppConfig()
    config.general.notificationsEnabled = false
    config.capture.format = .jpeg
    config.capture.quality = 75
    config.filenames.template = "%app/%y%mo%d_%counter"
    config.pipelines[0].actions = [
        .openInEditor,
        .copyImage,
        .saveToDisk,
        .upload(destination: "my-r2"),
        .copyURL,
        .runShell(command: "echo $MACSHOT_PATH"),
        .openInApp(bundleID: "com.apple.Preview"),
        .extractText
    ]
    var clipboardOnly = Pipeline()
    clipboardOnly.name = "Clipboard only"
    clipboardOnly.actions = [.copyImage]
    config.pipelines.append(clipboardOnly)
    var destination = Destination()
    destination.name = "my-r2"
    destination.kind = .s3
    destination.s3.bucket = "shots"
    config.destinations = [destination]
    var clipboardHotkey = CaptureHotkey()
    clipboardHotkey.name = "Clipboard"
    clipboardHotkey.pipelineID = clipboardOnly.id
    config.hotkeys.captures.append(clipboardHotkey) // unbound
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
    #expect(config.pipelines.map(\.actions) == [[.copyImage]])
    #expect(config.recents.isEmpty)
}

@Test
func aConfigWithPerModeOverridesLoadsWithTheOnePipelineInEffect() throws {
    // The overrides are simply not read any more (ADR 0012); the action list
    // they sat beside still is.
    let json = """
    {
      "pipeline": {
        "global": [ { "type": "copyImage" } ],
        "region": { "mode": "replace", "actions": [ { "type": "extractText" } ] },
        "window": { "mode": "replace", "actions": [ { "type": "saveToDisk" } ] },
        "fullscreen": { "mode": "useGlobal" }
      }
    }
    """
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.pipelines.map(\.actions) == [[.copyImage]])
}

@Test
func aV110ConfigLoadsItsPipelineAsDefault() throws {
    // v1.0.0–v1.1.0 stored the one pipeline under `pipeline.global`.
    let json = """
    {
      "pipeline": {
        "global": [ { "type": "saveToDisk" }, { "type": "upload", "destination": "r2" } ]
      }
    }
    """
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.pipelines.count == 1)
    #expect(config.pipelines[0].name == "Default")
    #expect(config.pipelines[0].actions == [.saveToDisk, .upload(destination: "r2")])
}

@Test
func namedPipelinesWinOverTheLegacyKey() throws {
    let json = """
    {
      "pipeline": { "global": [ { "type": "extractText" } ] },
      "pipelines": [
        { "id": "6F1D0C52-3E3A-4B1E-9F45-2B0D7C1E8A11", "name": "Copy",
          "actions": [ { "type": "copyImage" } ] }
      ]
    }
    """
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.pipelines.map(\.name) == ["Copy"])
    #expect(config.pipelines[0].id.uuidString == "6F1D0C52-3E3A-4B1E-9F45-2B0D7C1E8A11")
}

@Test
func anEmptyPipelineListFallsBackToDefault() throws {
    // There is always at least one pipeline to run.
    let config = try JSONDecoder().decode(
        AppConfig.self, from: Data(#"{ "pipelines": [] }"#.utf8)
    )
    #expect(config.pipelines == AppConfig().pipelines)
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

// MARK: - Capture hotkeys

@Test
func aV110ConfigLoadsItsCaptureHotkeyAsCaptureArea() throws {
    // v1.0.0–v1.1.0 had one binding at `hotkeys.capture` and one pipeline.
    let json = """
    {
      "pipeline": { "global": [ { "type": "copyImage" } ] },
      "hotkeys": { "capture": { "keyCode": 18, "carbonModifiers": 256 } }
    }
    """
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.hotkeys.captures.count == 1)
    let entry = try #require(config.hotkeys.captures.first)
    #expect(entry.name == "Capture")
    #expect(entry.binding == HotkeyBinding(keyCode: 18, carbonModifiers: 256))
    #expect(entry.pipelineID == config.pipelines[0].id)
    #expect(config.pipelines[0].name == "Default")
}

@Test
func aFreshConfigHasOneCaptureEntryOnControlShift4() throws {
    let entry = try #require(AppConfig().hotkeys.captures.first)
    #expect(AppConfig().hotkeys.captures.count == 1)
    #expect(entry.name == "Capture")
    #expect(entry.binding == HotkeyBinding(keyCode: 21, carbonModifiers: 0x1200))
    #expect(entry.pipelineID == Pipeline.defaultID)
}

@Test
func anEmptyCaptureHotkeyListStaysEmpty() throws {
    // Unlike pipelines, having no capture hotkeys is a valid choice.
    let config = try JSONDecoder().decode(
        AppConfig.self, from: Data(#"{ "hotkeys": { "captures": [] } }"#.utf8)
    )
    #expect(config.hotkeys.captures.isEmpty)
}

@Test
func anEntryRunsItsOwnPipeline() {
    var config = AppConfig()
    var clipboardOnly = Pipeline()
    clipboardOnly.name = "Clipboard only"
    config.pipelines.append(clipboardOnly)
    var entry = CaptureHotkey()
    entry.pipelineID = clipboardOnly.id
    #expect(config.pipeline(for: entry).name == "Clipboard only")
    #expect(config.pipeline(for: config.hotkeys.captures[0]).name == "Default")
}

@Test
func anEntryWhosePipelineWasDeletedRunsTheFirstAndKeepsItsReference() throws {
    var config = AppConfig()
    var gone = Pipeline()
    gone.name = "Gone"
    config.pipelines.append(gone)
    config.hotkeys.captures[0].pipelineID = gone.id
    config.pipelines.removeAll { $0.id == gone.id }

    // Survives a save and reload untouched, so Settings can flag it.
    let reloaded = try JSONDecoder().decode(
        AppConfig.self, from: JSONEncoder().encode(config)
    )
    #expect(reloaded.hotkeys.captures[0].pipelineID == gone.id)
    #expect(reloaded.pipeline(for: reloaded.hotkeys.captures[0]).name == "Default")
}
