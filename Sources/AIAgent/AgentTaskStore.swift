import Foundation

// MARK: - AgentTaskStore

/// Persists agent tasks to a local JSON file at
/// `~/Library/Application Support/TerminalApp/agent_tasks.json`.
///
/// All operations are thread-safe only when used from `@MainActor` context
/// (the same constraint as ``AgentService``). Load and save use synchronous
/// file I/O suitable for the small data volumes of task metadata.
public final class AgentTaskStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: Init

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    // MARK: - Storage URL

    /// The full file URL of the tasks JSON file.
    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TerminalApp", isDirectory: true)
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("agent_tasks.json")
    }

    // MARK: - Public API

    /// Loads all persisted agent tasks from disk.
    ///
    /// - Returns: An array of tasks, or an empty array if the file does not
    ///   exist or is corrupt.
    public func load() -> [AgentTask] {
        let url = storageURL
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([AgentTask].self, from: data)
        } catch {
            NSLog("AgentTaskStore: Failed to load tasks – \(error.localizedDescription). Starting fresh.")
            return []
        }
    }

    /// Persists the full array of tasks to disk, overwriting any existing file.
    ///
    /// - Parameter tasks: The complete tasks array to store.
    public func save(_ tasks: [AgentTask]) {
        let url = storageURL

        do {
            let directory = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let data = try encoder.encode(tasks)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("AgentTaskStore: Failed to save tasks – \(error.localizedDescription)")
        }
    }

    /// Updates a single task in the persisted store.
    ///
    /// If the task already exists (matched by ``AgentTask/id``) it is replaced;
    /// otherwise it is appended. This is a convenience wrapper around
    /// ``load()`` + ``save(_:)``.
    ///
    /// - Parameter task: The task to persist.
    public func update(_ task: AgentTask) {
        var tasks = load()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        save(tasks)
    }
}
