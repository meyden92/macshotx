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
        $0.filenames.template = "shot_%mode"
    }
    return (store, dir)
}

private func artifact(mode: CaptureMode = .fullscreen) -> CaptureArtifact {
    CaptureArtifact(
        image: makeImage(),
        mode: mode,
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
    store.update { $0.pipeline.global = [.saveToDisk] }

    let runner = PipelineRunner(store: store)
    let outcome = try await runner.execute(artifact())

    let saved = try #require(outcome.savedURL)
    #expect(saved.lastPathComponent == "shot_fullscreen.png")
    #expect(FileManager.default.fileExists(atPath: saved.path))
    #expect(store.config.recents.first == saved.path)
}

@MainActor
@Test
func saveAvoidsCollisionsWithSuffix() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.pipeline.global = [.saveToDisk] }

    let runner = PipelineRunner(store: store)
    let first = try await runner.execute(artifact())
    let second = try await runner.execute(artifact())
    let third = try await runner.execute(artifact())

    #expect(first.savedURL?.lastPathComponent == "shot_fullscreen.png")
    #expect(second.savedURL?.lastPathComponent == "shot_fullscreen_2.png")
    #expect(third.savedURL?.lastPathComponent == "shot_fullscreen_3.png")
}

@MainActor
@Test
func formatOverrideReplacesLiteralTemplateExtension() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update {
        $0.pipeline.global = [.saveToDisk]
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
        $0.pipeline.global = [.saveToDisk]
        $0.filenames.template = "%mode/%app_shot"
    }

    let runner = PipelineRunner(store: store)
    let outcome = try await runner.execute(artifact(mode: .window))
    let saved = try #require(outcome.savedURL)
    #expect(saved.lastPathComponent == "TestApp_shot.png")
    #expect(saved.deletingLastPathComponent().lastPathComponent == "window")
}

// MARK: - Clipboard

@MainActor
@Test
func copyImagePutsBitmapOnPasteboard() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.pipeline.global = [.copyImage] }

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
    store.update { $0.pipeline.global = [.copyURL] }

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
        $0.pipeline.global = [
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
        $0.pipeline.global = [.runShell(command: "echo \"$MACSHOT_PATH\" > \(marker)")]
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
        $0.pipeline.global = [
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
    store.update { $0.pipeline.global = [.upload(destination: "nope")] }

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
        $0.pipeline.global = [.saveToDisk]
        $0.filenames.template = "c%counter"
        $0.filenames.counterPadding = 3
    }

    let runner = PipelineRunner(store: store)
    let first = try await runner.execute(artifact())
    let second = try await runner.execute(artifact())
    #expect(first.savedURL?.lastPathComponent == "c001.png")
    #expect(second.savedURL?.lastPathComponent == "c002.png")
}

// MARK: - Alpha-safe output format

@Test
func theEffectiveFormatOnlyMovesWhenTheConfiguredOneCannotStoreAlpha() {
    // configured × may-contain-transparency → expected format and extension.
    let expected: [(ImageFormat, Bool, ImageFormat, String)] = [
        (.png, false, .png, "png"), (.png, true, .png, "png"),
        (.jpeg, false, .jpeg, "jpg"), (.jpeg, true, .png, "png"),
        // HEIC round-trips alpha through the system encoder — verified, not assumed.
        (.heic, false, .heic, "heic"), (.heic, true, .heic, "heic")
    ]
    for (configured, alpha, format, ext) in expected {
        let effective = configured.effective(mayContainTransparency: alpha)
        #expect(effective == format, "\(configured) with alpha=\(alpha)")
        #expect(effective.fileExtension == ext)
    }
}

@Test
func heicActuallyPreservesTransparency() throws {
    let ctx = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 32))

    let data = try ImageEncoder.encode(ctx.makeImage()!, format: .heic, quality: 90)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let bytes = CFDataGetBytePtr(decoded.dataProvider!.data!)!
    #expect(bytes[16 * decoded.bytesPerRow + 24 * 4 + 3] == 0,
            "If this ever fails, HEIC must downgrade to PNG alongside JPEG")
}

@MainActor
@Test
func anAlphaBearingCaptureIsSavedAsPngEvenWhenJpegIsConfigured() async throws {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    store.update { $0.capture.format = .jpeg }

    store.update { $0.pipeline.global = [.saveToDisk] }

    var alphaArtifact = artifact()
    alphaArtifact.mayContainTransparency = true
    let outcome = try await PipelineRunner(store: store).execute(alphaArtifact)

    let saved = try #require(outcome.savedURL)
    #expect(saved.lastPathComponent.hasSuffix(".png"),
            "A .jpg holding PNG bytes is the bug this prevents")
    let data = try Data(contentsOf: saved)
    #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "and it really is PNG")
}
