import Foundation
import Compression

// MARK: - PersistenceEngine

/// Responsible for persisting workspace state and scrollback data to disk.
///
/// Workspace state is serialized as gzipped JSON using Foundation zlib compression.
/// A 500 ms debounce is applied to save operations to avoid excessive writes.
///
/// Scrollback data for each session is stored in separate flat files named by
/// session UUID and can be appended to incrementally.
public final class PersistenceEngine: @unchecked Sendable {

    // MARK: Properties

    private let baseURL: URL
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()
    private let decoder = JSONDecoder()

    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: Duration = .milliseconds(500)

    // MARK: Initialization

    /// Creates a persistence engine rooted at the given directory.
    ///
    /// - Parameter baseURL: The directory under which all state files are stored.
    ///   If `nil`, defaults to `ApplicationSupport/com.terminalapp.sessionmanager/`.
public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let paths = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )
            self.baseURL = paths[0]
                .appendingPathComponent("com.terminalapp.sessionmanager", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.baseURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: File URLs

    private var stateFileURL: URL {
        baseURL.appendingPathComponent("workspace_state.json.gz")
    }

    private func scrollbackFileURL(for sessionId: UUID) -> URL {
        baseURL.appendingPathComponent("scrollback_\(sessionId.uuidString).dat")
    }

    // MARK: - Workspace State Persistence

    /// Saves the workspace state after a 500 ms debounce period.
    ///
    /// Each call cancels any pending save and schedules a new one. The state is
    /// encoded as JSON and compressed with zlib before writing.
  public func saveWorkspaceState(_ state: WorkspaceState) {
        debounceWorkItem?.cancel()
        let capturedState = state
        let interval = debounceInterval
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistWorkspaceState(capturedState)
        }
        debounceWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }

    /// Synchronously writes the workspace state to disk.
    private func persistWorkspaceState(_ state: WorkspaceState) {
        do {
            let data = try encoder.encode(state)
            guard let compressed = try (data as NSData).compressed(using: .zlib) as Data? else {
                print("[PersistenceEngine] Failed to compress workspace state")
                return
            }
            try compressed.write(to: stateFileURL, options: .atomic)
        } catch {
            print("[PersistenceEngine] Failed to save workspace state: \(error)")
        }
    }

    /// Loads and returns the previously saved workspace state.
    ///
    /// - Returns: The decoded `WorkspaceState`, or `nil` if no saved state exists
    ///   or decoding fails.
  public func loadWorkspaceState() -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            return nil
        }
        do {
            let compressed = try Data(contentsOf: stateFileURL)
            guard let decompressed = try (compressed as NSData).decompressed(using: .zlib) as Data? else {
                print("[PersistenceEngine] Failed to decompress workspace state")
                return nil
            }
            return try decoder.decode(WorkspaceState.self, from: decompressed)
        } catch {
            print("[PersistenceEngine] Failed to load workspace state: \(error)")
            return nil
        }
    }

    // MARK: - Scrollback Persistence

    /// Appends raw data to the scrollback file for the given session.
    ///
    /// If the file does not yet exist it is created.  This is intended for
    /// terminal output that exceeds the in-memory buffer and should survive
    /// application restarts.
    ///
    /// - Parameters:
    ///   - sessionId: The UUID of the session whose scrollback should be extended.
    ///   - data: The raw bytes to append.
  public func appendScrollback(sessionId: UUID, data: Data) {
        let url = scrollbackFileURL(for: sessionId)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let fileHandle = try FileHandle(forWritingTo: url)
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
                try fileHandle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("[PersistenceEngine] Failed to append scrollback: \(error)")
        }
    }

    /// Loads the full scrollback data for the given session.
    ///
    /// - Parameter sessionId: The UUID of the session.
    /// - Returns: The scrollback data, or an empty `Data` value if no scrollback
    ///   file exists.
  public func loadScrollback(sessionId: UUID) -> Data {
        let url = scrollbackFileURL(for: sessionId)
        return (try? Data(contentsOf: url)) ?? Data()
    }
}
