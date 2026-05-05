import SwiftUI
import AppKit
import HostStoreModule
import SessionManager
import AIProvider
import SkillManager

@main
struct TerminalApp: App {
    @StateObject private var hostStore = HostStore()
    @StateObject private var sessionManager: SessionManager
    @StateObject private var aiRegistry = AIProviderRegistry()
    @StateObject private var skillStore = SkillStore()
    @StateObject private var settingsStore = SettingsStore()

    init() {
        _sessionManager = StateObject(wrappedValue: SessionManager())
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hostStore)
                .environmentObject(sessionManager)
                .environmentObject(aiRegistry)
                .environmentObject(skillStore)
                .environmentObject(settingsStore)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    activateApp()
                    hostStore.loadAll()
                    sessionManager.restoreSession()
                }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    // Trigger new host connection
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Claude") {
                Button("Approve Tool") {
                    NotificationCenter.default.post(name: .claudeApproval, object: nil, userInfo: ["key": "y"])
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])

                Button("Reject Tool") {
                    NotificationCenter.default.post(name: .claudeApproval, object: nil, userInfo: ["key": "n"])
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Approve All") {
                    NotificationCenter.default.post(name: .claudeApproval, object: nil, userInfo: ["key": "a"])
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("New Claude Code Session") {
                    NotificationCenter.default.post(name: .launchClaudeCode, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
