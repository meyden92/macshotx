import AppKit
import ImageIO
import Testing
@testable import MacshotCore

private func makeImage(width: Int = 40, height: Int = 30) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 4 * width,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.orange.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@MainActor
private func makeStore() -> (ConfigStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macshot-pipe-\(UUID().uuidString)", isDirectory: true)
    let store = ConfigStore(directory: dir)
    let saveDir = dir.appendingPathComponent("saves", isDirectory: true)
    store.update {
        $0.capture.saveDirectory = saveDir.path
        $0.filenames.template = "shot_%app"
    }
    return (store, dir)
}

private func artifact() -> CaptureArtifact {
    CaptureArtifact(
        image: makeImage(),
        appName: "TestApp",
        windowTitle: "Test Window"
    )
}

// MARK: - Encoder

@Test
func encoderProducesAllFormats() throws {
    let image = makeImage()
    for format in ImageFormat.allCases {
        let data = try ImageEncoder.encode(image, format: format, quality: 80)
        #expect(!data.isEmpty)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        #expect(source != nil, "\(format) did not produce decodable data")
        let decoded = CGImageSourceCreateImageAtIndex(source!, 0, nil)
        #expect(decoded?.width == image.width)
        #expect(decoded?.height == image.height)
    }
}

// MARK: - Save

@MainActor
@Test
func saveActionWritesFileAndRecordsRecent() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.pipeline.actions = [.saveToDisk] }

    let runner = PipelineRunner(store: store)
    let outcome = try await runner.execute(artifact())

    let saved = try #require(outcome.savedURL)
    #expect(saved.lastPathComponent == "shot_TestApp.png")
    #expect(FileManager.default.fileExists(atPath: saved.path))
    #expect(store.config.recents.first == saved.path)
}

@MainActor
@Test
func saveAvoidsCollisionsWithSuffix() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.pipeline.actions = [.saveToDisk] }

    let runner = PipelineRunner(store: store)
    let first = try await runner.execute(artifact())
    let second = try await runner.execute(artifact())
    let third = try await runner.execute(artifact())

    #expect(first.savedURL?.lastPathComponent == "shot_TestApp.png")
    #expect(second.savedURL?.lastPathComponent == "shot_TestApp_2.png")
    #expect(third.savedURL?.lastPathComponent == "shot_TestApp_3.png")
}

@MainActor
@Test
func formatOverrideReplacesLiteralTemplateExtension() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update {
        $0.pipeline.actions = [.saveToDisk]
        $0.filenames.template = "shot.png"
        $0.capture.format = .jpeg
    }

    let runner = PipelineRunner(store: store)
    let outcome = try await runner.execute(artifact())
    #expect(outcome.savedURL?.lastPathComponent == "shot.jpg")
}

@MainActor
@Test
func templateSubfoldersAreCreated() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update {
        $0.pipeline.actions = [.saveToDisk]
        $0.filenames.template = "%app/%window_shot"
    }

    let runner = PipelineRunner(store: store)
    let outcome = try await runner.execute(artifact())
    let saved = try #require(outcome.savedURL)
    #expect(saved.lastPathComponent == "Test_Window_shot.png")
    #expect(saved.deletingLastPathComponent().lastPathComponent == "TestApp")
}

// MARK: - Clipboard

@MainActor
@Test
func copyImagePutsBitmapOnPasteboard() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.pipeline.actions = [.copyImage] }

    NSPasteboard.general.clearContents()
    let runner = PipelineRunner(store: store)
    _ = try await runner.execute(artifact())
    #expect(NSPasteboard.general.canReadObject(forClasses: [NSImage.self]))
}

@MainActor
@Test
func copyURLWithoutUploadHalts() async {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.pipeline.actions = [.copyURL] }

    let runner = PipelineRunner(store: store)
    await #expect(throws: PipelineError.self) {
        _ = try await runner.execute(artifact())
    }
}

// MARK: - Shell

@MainActor
@Test
func shellReceivesPathAsArgAndEnv() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appendingPathComponent("marker.txt").path
    store.update {
        $0.pipeline.actions = [
            .saveToDisk,
            .runShell(command: "test -f \"$1\" && test \"$1\" = \"$MACSHOT_PATH\" && echo \"$1\" > \(marker)")
        ]
    }

    let runner = PipelineRunner(store: store)
    let outcome = try await runner.execute(artifact())

    let written = try String(contentsOfFile: marker, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(written == outcome.savedURL?.path)
}

@MainActor
@Test
func shellWithoutPriorSaveGetsTempFile() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appendingPathComponent("marker.txt").path
    store.update {
        $0.pipeline.actions = [.runShell(command: "echo \"$MACSHOT_PATH\" > \(marker)")]
    }

    let runner = PipelineRunner(store: store)
    let outcome = try await runner.execute(artifact())

    #expect(outcome.savedURL == nil)
    let tempPath = try String(contentsOfFile: marker, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(FileManager.default.fileExists(atPath: tempPath))
    try? FileManager.default.removeItem(atPath: tempPath)
}

@MainActor
@Test
func failingShellHaltsPipeline() async {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update {
        $0.pipeline.actions = [
            .runShell(command: "exit 3"),
            .saveToDisk
        ]
    }

    let runner = PipelineRunner(store: store)
    await #expect(throws: PipelineError.self) {
        _ = try await runner.execute(artifact())
    }
    // The halted pipeline must not have reached saveToDisk.
    let saves = try? FileManager.default.contentsOfDirectory(
        atPath: store.config.capture.saveDirectory
    )
    #expect(saves == nil || saves!.isEmpty)
}

// MARK: - Upload (stub until destinations land)

@MainActor
@Test
func uploadToUnknownDestinationHalts() async {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.pipeline.actions = [.upload(destination: "nope")] }

    let runner = PipelineRunner(store: store)
    await #expect(throws: PipelineError.self) {
        _ = try await runner.execute(artifact())
    }
}

// MARK: - Counter integration

@MainActor
@Test
func counterAdvancesPerSave() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update {
        $0.pipeline.actions = [.saveToDisk]
        $0.filenames.template = "c%counter"
        $0.filenames.counterPadding = 3
    }

    let runner = PipelineRunner(store: store)
    let first = try await runner.execute(artifact())
    let second = try await runner.execute(artifact())
    #expect(first.savedURL?.lastPathComponent == "c001.png")
    #expect(second.savedURL?.lastPathComponent == "c002.png")
}
