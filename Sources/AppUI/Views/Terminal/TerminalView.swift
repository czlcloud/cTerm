import SwiftUI
import TerminalCore
import SessionManager
import SwiftTerm

struct TerminalView: View {
    let sessionId: UUID
    var profile: TerminalSettings? = nil
    var claudeConfig: ClaudeSessionConfig? = nil
    var tokenMonitor: TokenMonitor? = nil
    var isActive: Bool = true
    @ObservedObject var sessionManager: SessionManager
    @EnvironmentObject var settingsStore: SettingsStore

    private var activeSettings: TerminalSettings { profile ?? settingsStore.settings }

    @State private var searchVisible = false
    @State private var searchQuery = ""
    @State private var searchResults: [(row: Int, start: Int, end: Int)] = []
    @State private var currentMatch = 0
    @State private var connectFailed = false
    @State private var connectError: String?

    private var isDisconnected: Bool {
        sessionManager.disconnectedSessions.contains(sessionId)
    }

    private var isConnected: Bool {
        sessionManager.activeChannels[sessionId] != nil ||
        sessionManager.activeLocalShells[sessionId] != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let config = claudeConfig {
                ClaudeStatusBar(config: config, tokenUsage: tokenMonitor?.tokenUsage)
                Divider()
            }

            if let emulator = sessionManager.activeSessions[sessionId] {
                ZStack {
                    SwiftTermRepresentable(emulator: emulator, sessionId: sessionId, settings: activeSettings, sessionManager: sessionManager, isActive: isActive)

                    if searchVisible {
                        VStack {
                            SearchBar(query: $searchQuery, current: currentMatch, total: searchResults.count,
                                      onQueryChange: { performSearch(emulator: emulator) },
                                      onNext: { currentMatch = min(currentMatch + 1, searchResults.count) },
                                      onPrev: { currentMatch = max(currentMatch - 1, 1) },
                                      onClose: { searchVisible = false; searchResults = []; currentMatch = 0 })
                            Spacer()
                        }
                    }

                    if isDisconnected {
                        VStack { Spacer()
                            HStack { Spacer()
                                VStack(spacing: 16) {
                                    Image(systemName: "link.slash").font(.largeTitle).foregroundColor(.orange)
                                    Text("Connection Lost").font(.title3).foregroundColor(.secondary)
                                }.padding(32).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                                Spacer()
                            }; Spacer()
                        }
                    }

                    if !isConnected && !isDisconnected {
                        VStack { Spacer()
                            HStack { Spacer()
                                VStack(spacing: 16) {
                                    if !connectFailed { ProgressView().scaleEffect(1.2) }
                                    Text(connectFailed ? (connectError ?? "Connection Failed") : "Connecting...")
                                        .font(.title3).foregroundColor(connectFailed ? .red : .secondary)
                                }.padding(32).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                                Spacer()
                            }; Spacer()
                        }
                        .onAppear {
                            connectFailed = false; connectError = nil
                            if let err = sessionManager.sessionErrors[sessionId] { connectFailed = true; connectError = err }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                                if !isConnected, let err = sessionManager.sessionErrors[sessionId] { connectFailed = true; connectError = err }
                                else if !isConnected { connectFailed = true; connectError = "Connection timed out" }
                            }
                        }
                    }
                }
            } else {
                VStack { ProgressView(); Text("Initializing...").font(.caption).foregroundColor(.secondary) }
            }
        }
    }

    private func showSearch() { searchVisible = true; searchQuery = ""; searchResults = []; currentMatch = 0 }

    private func performSearch(emulator: TerminalEmulator) {
        guard !searchQuery.isEmpty else { searchResults = []; currentMatch = 0; return }
        let buf = emulator.screenBuffer
        var matches: [(row: Int, start: Int, end: Int)] = []
        for row in 0..<buf.size.rows {
            var line = ""
            for col in 0..<buf.size.cols { line.append(buf.cell(at: row, col: col).character) }
            var searchStart = line.startIndex
            while let range = line[searchStart...].range(of: searchQuery, options: .caseInsensitive) {
                let s = line.distance(from: line.startIndex, to: range.lowerBound)
                let e = line.distance(from: line.startIndex, to: range.upperBound)
                matches.append((row, s, e)); searchStart = range.upperBound
            }
        }
        searchResults = matches; currentMatch = matches.isEmpty ? 0 : 1
    }
}

// MARK: - SwiftTerm NSViewRepresentable

struct SwiftTermRepresentable: NSViewRepresentable {
    let emulator: TerminalEmulator
    let sessionId: UUID
    let settings: TerminalSettings
    let sessionManager: SessionManager
    var isActive: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        context.coordinator.sessionManager = sessionManager
        context.coordinator.sessionId = sessionId
        emulator.onRawWrite = { [weak tv = view] text in tv?.feed(text: text) }
        applyStyle(to: view)
        if isActive { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isActive, let tv = context.coordinator.terminalView {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    private func applyStyle(to view: SwiftTerm.TerminalView) {
        let font = NSFont(name: settings.fontName, size: settings.fontSize) ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        view.font = font
        view.nativeForegroundColor = settings.foregroundColor.nsColor
        view.nativeBackgroundColor = settings.backgroundColor.nsColor
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        var terminalView: SwiftTerm.TerminalView?
        weak var sessionManager: SessionManager?
        var sessionId: UUID = UUID()

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let d = Data(data); let sid = sessionId; let sm = sessionManager
            DispatchQueue.main.async { sm?.writeToSession(sid, data: d) }
        }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            sessionManager?.resizeLocalSessionNonIsolated(sessionId, rows: Int32(newRows), cols: Int32(newCols))
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

// MARK: - Search Bar

struct SearchBar: View {
    @Binding var query: String
    let current: Int; let total: Int
    let onQueryChange: () -> Void; let onNext: () -> Void
    let onPrev: () -> Void; let onClose: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Find...", text: $query).textFieldStyle(.plain).frame(width: 200)
                .focused($focused).onChange(of: query) { onQueryChange() }.onSubmit { onNext() }
            if total > 0 { Text("\(current)/\(total)").font(.caption).foregroundColor(.secondary).frame(minWidth: 40) }
            Button(action: onPrev) { Image(systemName: "chevron.up") }.buttonStyle(.plain)
            Button(action: onNext) { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
        }.padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 8)).padding(8)
            .onAppear { focused = true }
    }
}

// MARK: - Claude Status Bar

struct ClaudeStatusBar: View {
    let config: ClaudeSessionConfig
    var tokenUsage: TokenUsage?
    private var modelLabel: String {
        switch config.model { case "opus": "Opus"; case "haiku": "Haiku"; default: "Sonnet" }
    }
    private var permissionLabel: String {
        switch config.permissionMode { case "acceptEdits": "Accept Edits"; case "auto": "Auto"; case "plan": "Plan"; default: "Default" }
    }
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(.accentColor)
                Text(config.sessionName ?? "Claude Code").font(.system(size: 11, weight: .medium))
                Text(modelLabel).font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15)).clipShape(Capsule())
                Text(permissionLabel).font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(permissionColor.opacity(0.12)).clipShape(Capsule())
            }
            Spacer()
            if let usage = tokenUsage {
                HStack(spacing: 8) {
                    Text(usage.formattedTokens).font(.system(size: 10, design: .monospaced))
                        .foregroundColor(usage.isEstimated ? .secondary : .primary)
                    Text(usage.formattedCost).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    Text(usage.formattedElapsed).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
            } else { ProgressView().scaleEffect(0.5).frame(height: 12) }
        }.padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))
    }
    private var permissionColor: SwiftUI.Color {
        switch config.permissionMode { case "auto": .orange; case "acceptEdits": .yellow; case "plan": .blue; default: .gray }
    }
}
