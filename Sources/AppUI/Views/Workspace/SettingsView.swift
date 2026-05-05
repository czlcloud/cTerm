import SwiftUI
import AppKit
import TerminalCore

private let monospaceFonts = [
    "Menlo", "Monaco", "SF Mono",
    "JetBrains Mono", "Fira Code", "Cascadia Code", "Source Code Pro",
    "Iosevka", "IBM Plex Mono", "Hack", "Inconsolata", "Victor Mono",
    "DejaVu Sans Mono",
    "Consolas", "Andale Mono"
]

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.title).fontWeight(.bold)

                // Font & Shell
                GroupBox(label: Label("Terminal", systemImage: "terminal")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Font Size:").frame(width: 80, alignment: .trailing)
                            Slider(value: $settingsStore.settings.fontSize, in: 8...32, step: 1)
                            Text("\(Int(settingsStore.settings.fontSize))pt").frame(width: 50, alignment: .trailing)
                        }

                        HStack {
                            Text("Font:").frame(width: 80, alignment: .trailing)
                            Picker("", selection: $settingsStore.settings.fontName) {
                                ForEach(monospaceFonts, id: \.self) { font in
                                    Text(font).tag(font)
                                }
                            }
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Shell:").frame(width: 80, alignment: .trailing)
                            TextField("/bin/zsh", text: $settingsStore.settings.shellPath).textFieldStyle(.roundedBorder)
                            Button("Reset") { settingsStore.settings.shellPath = "/bin/zsh" }
                        }

                        Toggle("SSH Keep-Alive (global)", isOn: $settingsStore.settings.globalKeepAlive)
                            .help("Send heartbeat packets to prevent SSH disconnection")
                        HStack {
                            Text("Interval:").frame(width: 80, alignment: .trailing)
                            Slider(value: Binding(
                                get: { Double(settingsStore.settings.keepAliveInterval) },
                                set: { settingsStore.settings.keepAliveInterval = Int($0) }
                            ), in: 5...300, step: 5)
                            Text("\(settingsStore.settings.keepAliveInterval)s").frame(width: 40, alignment: .trailing)
                        }
                    }.padding(.vertical, 8)
                }

                // Foreground / Background / Cursor
                GroupBox(label: Label("Colors", systemImage: "paintpalette")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Scheme:").frame(width: 100, alignment: .trailing)
                            Picker("", selection: Binding(
                                get: { ColorSchemePreset(rawValue: settingsStore.settings.selectedScheme) ?? .systemDefault },
                                set: { scheme in
                                    scheme.apply(to: &settingsStore.settings)
                                    settingsStore.settings.selectedScheme = scheme.rawValue
                                }
                            )) {
                                ForEach(ColorSchemePreset.allCases, id: \.self) { scheme in
                                    Text(scheme.rawValue).tag(scheme)
                                }
                            }
                            .frame(width: 180)
                        }
                        Divider()
                        ColorRow("Foreground:", color: $settingsStore.settings.foregroundColor)
                        ColorRow("Background:", color: $settingsStore.settings.backgroundColor)
                        ColorRow("Cursor:", color: $settingsStore.settings.cursorColor)
                        HStack {
                            Text("Opacity:").frame(width: 100, alignment: .trailing)
                            Slider(value: $settingsStore.settings.backgroundOpacity, in: 0.3...1.0, step: 0.05)
                            Text("\(Int(settingsStore.settings.backgroundOpacity * 100))%").frame(width: 40, alignment: .trailing)
                        }
                    }.padding(.vertical, 8)
                }

                // Preview
                GroupBox(label: Label("Preview", systemImage: "eye")) {
                    Text("echo \"Hello World\"")
                        .font(.system(size: settingsStore.settings.fontSize, design: .monospaced))
                        .foregroundColor(Color(nsColor: settingsStore.settings.foregroundColor.nsColor))
                        .padding(12)
                        .background(Color(nsColor: settingsStore.settings.backgroundColor.nsColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity)
                }

                GroupBox(label: Label("Workspace Defaults", systemImage: "square.split.2x2")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Base Directory:").frame(width: 100, alignment: .trailing)
                            TextField("", text: $settingsStore.workspaceBaseDir).textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true; panel.canChooseFiles = false
                                panel.canCreateDirectories = true; panel.directoryURL = URL(fileURLWithPath: settingsStore.workspaceBaseDir)
                                if panel.runModal() == .OK, let url = panel.url {
                                    settingsStore.workspaceBaseDir = url.path
                                }
                            }
                        }
                        Text("New workspaces default to: {base}/{workspaceId}")
                            .font(.caption).foregroundColor(.secondary).padding(.leading, 100)
                    }.padding(.vertical, 8)
                }

                GroupBox(label: Label("AI Configuration", systemImage: "brain")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Model:").frame(width: 80, alignment: .trailing)
                            Picker("", selection: $settingsStore.claudeModel) {
                                Text("Sonnet").tag("sonnet")
                                Text("Opus").tag("opus")
                                Text("Haiku").tag("haiku")
                            }.frame(width: 140)
                        }
                        HStack {
                            Text("Permission:").frame(width: 80, alignment: .trailing)
                            Picker("", selection: $settingsStore.claudePermissionMode) {
                                Text("Default").tag("default")
                                Text("Accept Edits").tag("acceptEdits")
                                Text("Auto").tag("auto")
                                Text("Plan").tag("plan")
                            }.frame(width: 160)
                        }
                    }.padding(.vertical, 8)
                }

                GroupBox(label: Label("Credential Storage", systemImage: "key")) {
                    Picker("Store passwords in:", selection: $settingsStore.credentialPreference) {
                        ForEach(CredentialStorePreference.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }.pickerStyle(.radioGroup)
                    .padding(.vertical, 4)
                }

                Spacer()
            }.padding()
        }.frame(minWidth: 400)
    }
}

struct ColorRow: View {
    let label: String
    @Binding var color: CodableColor

    init(_ label: String, color: Binding<CodableColor>) {
        self.label = label
        _color = color
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 100, alignment: .trailing)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: color.nsColor) },
                set: { if let cg = $0.cgColor, let ns = NSColor(cgColor: cg) { color = CodableColor(ns) } }
            )).labelsHidden()
            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 16, height: 16)
        }
    }
}

struct ColorSchemePreset: CaseIterable, Hashable {
    let rawValue: String

    static var allCases: [ColorSchemePreset] {
        [.systemDefault, .matrix, .hackerGreen, .amberMono, .cyberBlue, .solarizedLight, .solarizedDark, .dracula, .gruvboxDark, .nord]
    }
    static let systemDefault = ColorSchemePreset(rawValue: "System Default")
    static let matrix = ColorSchemePreset(rawValue: "Matrix")
    static let hackerGreen = ColorSchemePreset(rawValue: "Hacker Green")
    static let amberMono = ColorSchemePreset(rawValue: "Amber Mono")
    static let cyberBlue = ColorSchemePreset(rawValue: "Cyber Blue")
    static let solarizedLight = ColorSchemePreset(rawValue: "Solarized Light")
    static let solarizedDark = ColorSchemePreset(rawValue: "Solarized Dark")
    static let dracula = ColorSchemePreset(rawValue: "Dracula")
    static let gruvboxDark = ColorSchemePreset(rawValue: "Gruvbox Dark")
    static let nord = ColorSchemePreset(rawValue: "Nord")

    func apply(to s: inout TerminalSettings) {
        switch self.rawValue {
        case "Matrix": s.foregroundColor = CodableColor(NSColor(hex: 0x00FF41)); s.backgroundColor = CodableColor(NSColor(hex: 0x0D0208))
        case "Hacker Green": s.foregroundColor = CodableColor(NSColor(hex: 0x33FF33)); s.backgroundColor = CodableColor(NSColor(hex: 0x0A0A0A))
        case "Amber Mono": s.foregroundColor = CodableColor(NSColor(hex: 0xFFB000)); s.backgroundColor = CodableColor(NSColor(hex: 0x1A1A1A))
        case "Cyber Blue": s.foregroundColor = CodableColor(NSColor(hex: 0x00D4FF)); s.backgroundColor = CodableColor(NSColor(hex: 0x0B0F1A))
        case "Solarized Light": s.foregroundColor = CodableColor(NSColor(hex: 0x657B83)); s.backgroundColor = CodableColor(NSColor(hex: 0xFDF6E3))
        case "Solarized Dark": s.foregroundColor = CodableColor(NSColor(hex: 0x839496)); s.backgroundColor = CodableColor(NSColor(hex: 0x002B36))
        case "Dracula": s.foregroundColor = CodableColor(NSColor(hex: 0xF8F8F2)); s.backgroundColor = CodableColor(NSColor(hex: 0x282A36))
        case "Gruvbox Dark": s.foregroundColor = CodableColor(NSColor(hex: 0xEBDBB2)); s.backgroundColor = CodableColor(NSColor(hex: 0x282828))
        case "Nord": s.foregroundColor = CodableColor(NSColor(hex: 0xD8DEE9)); s.backgroundColor = CodableColor(NSColor(hex: 0x2E3440))
        default: break
        }
    }
}

extension CodableColor {
    init(_ ns: NSColor) { self = .init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0, green: CGFloat((hex >> 8) & 0xFF) / 255.0, blue: CGFloat(hex & 0xFF) / 255.0, alpha: 1.0)
    }
}
