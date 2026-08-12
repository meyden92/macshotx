import Foundation

/// Owns the on-disk config at ~/Library/Application Support/macshot/config.json.
/// All mutation goes through `update`, which persists immediately (atomic write).
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var config: AppConfig

    let configURL: URL
    /// True when no config file existed at launch (drives onboarding).
    let isFirstRun: Bool

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macshot", isDirectory: true)
        self.configURL = dir.appendingPathComponent("config.json")
        self.isFirstRun = !FileManager.default.fileExists(atPath: configURL.path)
        self.config = Self.load(from: configURL)
    }

    func update(_ mutate: (inout AppConfig) -> Void) {
        var copy = config
        mutate(&copy)
        guard copy != config else { return }
        config = copy
        save()
    }

    /// Replace the entire config (import flow).
    func replace(with newConfig: AppConfig) {
        config = newConfig
        save()
    }

    /// Next %counter value for a save folder; increments and persists.
    func nextCounter(forFolder folder: String) -> Int {
        let next = (config.counters[folder] ?? 0) + 1
        update { $0.counters[folder] = next }
        return next
    }

    func addRecent(_ path: String) {
        update {
            $0.recents.removeAll { $0 == path }
            $0.recents.insert(path, at: 0)
            if $0.recents.count > 10 {
                $0.recents.removeLast($0.recents.count - 10)
            }
        }
    }

    // MARK: - Disk

    private static func load(from url: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            Log.error("Failed to parse config.json, using defaults: \(error)")
            return AppConfig()
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: configURL, options: .atomic)
        } catch {
            Log.error("Failed to save config.json: \(error)")
        }
    }
}
