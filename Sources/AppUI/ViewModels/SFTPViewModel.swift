import SwiftUI
import SSHClient

@MainActor
final class SFTPViewModel: ObservableObject {
    @Published var entries: [SFTPEntry] = []
    @Published var currentPath: String = "~"
    @Published var isLoading = false
    @Published var selectedEntries: Set<UUID> = []
    @Published var uploadProgress: Double = 0
    @Published var downloadProgress: Double = 0
    @Published var isTransferring = false
    @Published var errorMessage: String?

    func loadDirectory(_ path: String) {
        isLoading = true
        currentPath = path
        // SFTP list directory call here
    }

    func navigateUp() {
        let parts = currentPath.split(separator: "/")
        guard parts.count > 1 else { return }
        let parent = "/" + parts.dropLast().joined(separator: "/")
        loadDirectory(parent)
    }

    func navigateInto(_ entry: SFTPEntry) {
        guard entry.isDirectory else { return }
        let newPath = currentPath.hasSuffix("/") ? currentPath + entry.name : currentPath + "/" + entry.name
        loadDirectory(newPath)
    }

    func uploadFiles(_ urls: [URL]) {
        isTransferring = true
        uploadProgress = 0
        // Upload logic
    }

    func downloadEntries(_ entries: [SFTPEntry], to localURL: URL) {
        isTransferring = true
        downloadProgress = 0
        // Download logic
    }

    func deleteEntries(_ entries: [SFTPEntry]) {
        // Delete logic
    }

    func refresh() {
        loadDirectory(currentPath)
    }
}
