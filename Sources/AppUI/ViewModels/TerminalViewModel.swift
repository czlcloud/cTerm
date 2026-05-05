import SwiftUI
import SessionManager
import Combine

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var inputBuffer = ""
    @Published var selectedText = ""
    @Published var isContextMenuVisible = false

    weak var sessionManager: SessionManager?

    func sendKey(_ key: String, to sessionId: UUID) {
        guard let data = key.data(using: .utf8) else { return }
        sessionManager?.writeToSession(sessionId, data: data)
    }

    func sendCommand(_ command: String, to sessionId: UUID) {
        sessionManager?.writeToSession(sessionId, data: (command + "\r").data(using: .utf8) ?? Data())
    }

    func pasteSelection(to sessionId: UUID) {
        guard let pasteboard = NSPasteboard.general.string(forType: .string) else { return }
        sessionManager?.writeToSession(sessionId, data: pasteboard.data(using: .utf8) ?? Data())
    }

    func copySelection(from sessionId: UUID) {
        // Copy selected terminal text to pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    func toggleSplit(context: SplitContext) {
        // Trigger split in session manager
    }

    struct SplitContext {
        let sessionId: UUID
        let direction: SplitDirection
    }

    enum SplitDirection {
        case horizontal, vertical
    }
}
