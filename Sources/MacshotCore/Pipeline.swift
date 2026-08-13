import AppKit
import Foundation

/// The canonical artifact a capture produces, fed into the pipeline. Nothing
/// on it records how the Selection was seeded: there are no capture modes for
/// it to record (ADR 0012).
struct CaptureArtifact {
    let image: CGImage
    /// Frontmost app / window title at trigger time, for %app / %window tokens.
    let appName: String?
    let windowTitle: String?
}

enum PipelineError: LocalizedError {
    case destinationNotFound(String)
    case noURLAvailable
    case shellFailed(exitCode: Int32, output: String)
    case appNotFound(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationNotFound(let name):
            return "Upload destination \"\(name)\" is not configured."
        case .noURLAvailable:
            return "No URL to copy — add an Upload action before Copy URL."
        case .shellFailed(let exitCode, let output):
            let preview = output.suffix(200)
            return "Shell command exited with code \(exitCode). \(preview)"
        case .appNotFound(let bundleID):
            return "No application found for \"\(bundleID)\"."
        case .saveFailed(let reason):
            return "Save failed: \(reason)"
        }
    }
}

/// Everything a finished pipeline produced. Also serves as mutable state
/// while actions execute in order.
struct PipelineOutcome {
    var image: CGImage
    var savedURL: URL?
    /// Latest file on disk (saved or temporary) — what shell/open/upload steps see.
    var latestFileURL: URL?
    var uploadedURL: String?
    var ocrText: String?
    /// Filename (relative, may contain subfolders) expanded once per run.
    var expandedName: String?
}

/// Holds the artifact of a failed pipeline for ~60 seconds so the failure
/// notification's Retry can rerun the remaining actions (PRD §11.5).
@MainActor
final class RetryStore {
    static let shared = RetryStore()

    struct Pending {
        let artifact: CaptureArtifact
        let actions: [PipelineAction]
        let outcome: PipelineOutcome
        var created = Date()
    }

    private(set) var pending: Pending?

    func store(_ newPending: Pending) {
        pending = newPending
        let stamp = newPending.created
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.pending?.created == stamp else { return }
            self.pending = nil
        }
    }

    func take() -> Pending? {
        defer { pending = nil }
        guard let pending, Date().timeIntervalSince(pending.created) <= 60 else {
            return nil
        }
        return pending
    }
}

/// Executes the configured action list, in order, halting on the first
/// failure (PRD §6.6.3).
@MainActor
struct PipelineRunner {
    let store: ConfigStore

    init(store: ConfigStore = .shared) {
        self.store = store
    }

    /// Run the pipeline and surface success/failure notifications.
    func run(_ artifact: CaptureArtifact) async {
        await run(
            actions: store.config.pipeline.actions,
            artifact: artifact,
            outcome: PipelineOutcome(image: artifact.image)
        )
    }

    /// Rerun the actions that were left when a pipeline last failed
    /// (notification "Retry", PRD §11.5).
    func retryPending() async {
        guard let pending = RetryStore.shared.take() else {
            Log.info("Retry requested but no pending pipeline (expired?)")
            return
        }
        await run(actions: pending.actions, artifact: pending.artifact, outcome: pending.outcome)
    }

    private func run(
        actions: [PipelineAction],
        artifact: CaptureArtifact,
        outcome initial: PipelineOutcome
    ) async {
        let notificationsEnabled = store.config.general.notificationsEnabled
        var outcome = initial
        var index = 0
        do {
            while index < actions.count {
                try await perform(actions[index], artifact: artifact, outcome: &outcome)
                index += 1
            }
            await Notifier.success(
                savedURL: outcome.savedURL,
                uploadedURL: outcome.uploadedURL,
                ocrText: outcome.ocrText,
                thumbnail: outcome.image,
                enabled: notificationsEnabled
            )
        } catch is CancellationError {
            // The user cancelled in the editor — not a failure.
            Log.info("Pipeline cancelled")
        } catch {
            Log.error("Pipeline failed: \(error)")
            RetryStore.shared.store(RetryStore.Pending(
                artifact: artifact,
                actions: Array(actions[index...]),
                outcome: outcome
            ))
            await Notifier.failure(
                title: "Pipeline failed",
                error: error,
                enabled: notificationsEnabled,
                canRetry: true
            )
        }
    }

    /// Core execution, separated from notifications for testability.
    func execute(_ artifact: CaptureArtifact) async throws -> PipelineOutcome {
        var outcome = PipelineOutcome(image: artifact.image)

        for action in store.config.pipeline.actions {
            try await perform(action, artifact: artifact, outcome: &outcome)
        }
        return outcome
    }

    private func perform(
        _ action: PipelineAction,
        artifact: CaptureArtifact,
        outcome: inout PipelineOutcome
    ) async throws {
        switch action {
        case .openInEditor:
            // Every capture already passed through the overlay's annotator, so
            // this is a deliberate second pass: it opens whenever it is in the
            // pipeline rather than for the modes that used to skip the overlay.
            guard let edited = await EditorPresenter.edit(image: outcome.image) else {
                throw CancellationError()
            }
            outcome.image = edited

        case .copyImage:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([NSImage(
                cgImage: outcome.image,
                size: NSSize(width: outcome.image.width, height: outcome.image.height)
            )])

        case .saveToDisk:
            let directory = URL(
                fileURLWithPath: (store.config.capture.saveDirectory as NSString)
                    .expandingTildeInPath,
                isDirectory: true
            )
            let url = try write(outcome.image, artifact: artifact, into: directory, outcome: &outcome)
            outcome.savedURL = url
            outcome.latestFileURL = url
            store.addRecent(url.path)

        case .upload(let destinationName):
            guard let destination = store.config.destinations.first(
                where: { $0.name == destinationName }
            ) else {
                throw PipelineError.destinationNotFound(destinationName)
            }
            let config = store.config.capture
            let data = try ImageEncoder.encode(
                outcome.image,
                format: config.format,
                quality: config.quality
            )
            let filename = try resolveName(artifact: artifact, outcome: &outcome)
            let result = try await UploadService.upload(
                data: data,
                filename: (filename as NSString).lastPathComponent,
                destination: destination
            )
            outcome.uploadedURL = result.url
            Log.info("Uploaded to \(destinationName): \(result.url ?? "(no public URL)")")

        case .copyURL:
            guard let url = outcome.uploadedURL else {
                throw PipelineError.noURLAvailable
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url, forType: .string)

        case .runShell(let command):
            let fileURL = try ensureFileOnDisk(artifact: artifact, outcome: &outcome)
            let (status, output) = try await Self.runShellCommand(
                command,
                path: fileURL.path,
                url: outcome.uploadedURL ?? ""
            )
            if !output.isEmpty {
                Log.info("Shell output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            guard status == 0 else {
                throw PipelineError.shellFailed(exitCode: status, output: output)
            }

        case .openInApp(let bundleID):
            let fileURL = try ensureFileOnDisk(artifact: artifact, outcome: &outcome)
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID
            ) else {
                throw PipelineError.appNotFound(bundleID)
            }
            let openConfig = NSWorkspace.OpenConfiguration()
            try await NSWorkspace.shared.open(
                [fileURL], withApplicationAt: appURL, configuration: openConfig
            )

        case .extractText:
            let text = try await OCRService.recognizeText(in: outcome.image)
            outcome.ocrText = text
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    // MARK: - Filenames and files

    /// Expand the filename template once per pipeline run (subsequent actions
    /// reuse the same name, so save + upload agree).
    private func resolveName(
        artifact: CaptureArtifact,
        outcome: inout PipelineOutcome
    ) throws -> String {
        if let name = outcome.expandedName { return name }

        let filenames = store.config.filenames
        let directory = (store.config.capture.saveDirectory as NSString).expandingTildeInPath

        var context = FilenameTemplate.Context()
        context.windowTitle = artifact.windowTitle
        context.appName = artifact.appName
        context.counterPadding = filenames.counterPadding
        if filenames.template.contains("%counter") {
            context.counter = store.nextCounter(forFolder: directory)
        }

        var expanded = FilenameTemplate.expand(filenames.template, context: context)
        // The template may carry a literal extension (default does: .png) —
        // replace it with the configured format's so JPEG output never lands
        // in a file named .png.
        let literalExtension = FilenameTemplate.extensionSuffix(of: expanded)
        if !literalExtension.isEmpty {
            expanded = String(expanded.dropLast(literalExtension.count))
        }
        expanded += ".\(store.config.capture.format.fileExtension)"

        outcome.expandedName = expanded
        return expanded
    }

    /// Encode and write the image under `directory` using the expanded
    /// template name, avoiding collisions with a numeric suffix.
    private func write(
        _ image: CGImage,
        artifact: CaptureArtifact,
        into directory: URL,
        outcome: inout PipelineOutcome
    ) throws -> URL {
        let config = store.config.capture
        let data = try ImageEncoder.encode(
            image, format: store.config.capture.format, quality: config.quality
        )
        let name = try resolveName(artifact: artifact, outcome: &outcome)

        var url = directory.appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: url.path) {
            let ext = url.pathExtension
            let base = url.deletingPathExtension()
            var attempt = 2
            repeat {
                url = base.deletingLastPathComponent().appendingPathComponent(
                    "\(base.lastPathComponent)_\(attempt).\(ext)"
                )
                attempt += 1
            } while fm.fileExists(atPath: url.path)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PipelineError.saveFailed(error.localizedDescription)
        }
        return url
    }

    /// Shell / open-in-app / upload steps need a real file. If no save action
    /// ran yet, materialize the image into a temporary folder.
    private func ensureFileOnDisk(
        artifact: CaptureArtifact,
        outcome: inout PipelineOutcome
    ) throws -> URL {
        if let url = outcome.latestFileURL { return url }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot", isDirectory: true)
        let url = try write(
            outcome.image, artifact: artifact, into: tempDirectory, outcome: &outcome
        )
        outcome.latestFileURL = url
        return url
    }

    // MARK: - Shell

    /// Runs `command` through zsh with the file path as $1 / $MACSHOT_PATH and
    /// the upload URL (if any) as $2 / $MACSHOT_URL (PRD §6.6.3).
    nonisolated static func runShellCommand(
        _ command: String,
        path: String,
        url: String
    ) async throws -> (Int32, String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command, "macshot", path, url]
            var environment = ProcessInfo.processInfo.environment
            environment["MACSHOT_PATH"] = path
            environment["MACSHOT_URL"] = url
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            // Drain while the process runs so a chatty command can't deadlock
            // on a full pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }.value
    }
}

