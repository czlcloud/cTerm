import SwiftUI
import HostStoreModule
import SessionManager

struct LayoutPresetPickerView: View {
    @State private var presets: [LayoutPreset] = []
    @State private var showSaveSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Layout Presets")
                    .font(.headline)
                Spacer()
                Button(action: { showSaveSheet = true }) {
                    Label("Save Current", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if presets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No saved layouts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Arrange your terminal splits and tabs, then save as a preset for quick access.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
            } else {
                List {
                    ForEach(presets) { preset in
                        PresetRow(preset: preset, onApply: { applyPreset(preset) }) {
                            presets.removeAll { $0.id == preset.id }
                            savePresets()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .sheet(isPresented: $showSaveSheet) {
            SavePresetSheet { name, quickKey in
                saveCurrentLayout(name: name, quickKey: quickKey)
                showSaveSheet = false
            }
        }
        .alert("Layout Preset", isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
    }

    private func applyPreset(_ preset: LayoutPreset) {
        alertMessage = "Layout '\(preset.name)' applied"
        showAlert = true
    }

    private func saveCurrentLayout(name: String, quickKey: String?) {
        let preset = LayoutPreset(
            id: UUID(),
            name: name,
            windowLayout: .leaf(LeafSession(hostId: UUID())),
            bindings: [],
            quickKey: quickKey
        )
        presets.append(preset)
        savePresets()
    }

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        let url = presetsURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private var presetsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalApp/layout_presets.json")
    }
}

struct PresetRow: View {
    let preset: LayoutPreset
    let onApply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "rectangle.split.2x1")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.body).fontWeight(.medium)
                if let key = preset.quickKey {
                    Text("Shortcut: \(key)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("\(preset.bindings.count) hosts")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onApply) {
                Text("Apply")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .contextMenu {
            Button("Apply") { onApply() }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

struct SavePresetSheet: View {
    let onSave: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var quickKey = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Layout Preset").font(.title2).fontWeight(.bold)

            VStack(alignment: .leading) {
                Text("Name").font(.caption).foregroundColor(.secondary)
                TextField("e.g. Monitoring View", text: $name).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading) {
                Text("Keyboard Shortcut (optional)").font(.caption).foregroundColor(.secondary)
                TextField("e.g. cmd+1", text: $quickKey).textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    onSave(name, quickKey.isEmpty ? nil : quickKey)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }
}

// MARK: - Layout Preset model (compatible with SessionManager SplitNode)

struct LayoutPreset: Identifiable, Codable {
    let id: UUID
    var name: String
    var windowLayout: SplitNode
    var bindings: [LayoutBinding]
    var quickKey: String?

    init(id: UUID = UUID(), name: String, windowLayout: SplitNode,
         bindings: [LayoutBinding] = [], quickKey: String? = nil) {
        self.id = id
        self.name = name
        self.windowLayout = windowLayout
        self.bindings = bindings
        self.quickKey = quickKey
    }
}

struct LayoutBinding: Codable, Identifiable {
    let id: UUID
    var hostId: UUID
    var initialCommand: String?
    var workingDirectory: String?

    init(id: UUID = UUID(), hostId: UUID, initialCommand: String? = nil, workingDirectory: String? = nil) {
        self.id = id
        self.hostId = hostId
        self.initialCommand = initialCommand
        self.workingDirectory = workingDirectory
    }
}
