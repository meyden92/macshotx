import Foundation

/// Local-only rotating file log at ~/Library/Logs/macshot/macshot.log
/// (PRD §7.2: 5 MB × 5 files; logs are never transmitted anywhere).
final class Log: @unchecked Sendable {
    static let shared = Log()

    private let lock = NSLock()
    private let directory: URL
    private let maxFileSize = 5 * 1024 * 1024
    private let maxFiles = 5

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/macshot", isDirectory: true)
    }

    static func info(_ message: String) {
        shared.write(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        shared.write(level: "ERROR", message: message)
    }

    var logFileURL: URL {
        directory.appendingPathComponent("macshot.log")
    }

    private func write(level: String, message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let line = "\(timestamp) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL)
            }
        } catch {
            // Logging must never take the app down; drop the line.
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard
            let size = (try? fm.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int,
            size >= maxFileSize
        else { return }
        // macshot.log → macshot.1.log → … → macshot.4.log; oldest falls off.
        let archive = { (index: Int) in
            self.directory.appendingPathComponent("macshot.\(index).log")
        }
        try? fm.removeItem(at: archive(maxFiles - 1))
        for index in stride(from: maxFiles - 2, through: 1, by: -1) {
            _ = try? fm.moveItem(at: archive(index), to: archive(index + 1))
        }
        _ = try? fm.moveItem(at: logFileURL, to: archive(1))
    }
}
