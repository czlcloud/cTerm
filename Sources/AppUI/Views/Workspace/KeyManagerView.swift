import SwiftUI

struct KeyManagerView: View {
    @StateObject private var keyManager = KeyManager.shared
    @State private var newKeyPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SSH Keys").font(.title).fontWeight(.bold)

            Text("Add private key paths. The app will try them when connecting with SSH Agent.")
                .font(.caption).foregroundColor(.secondary)

            // Add key
            HStack {
                TextField("~/.ssh/id_ed25519", text: $newKeyPath).textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.showsHiddenFiles = true
                    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            newKeyPath = url.path
                        }
                    }
                }
                Button("Add") {
                    let expanded = (newKeyPath as NSString).expandingTildeInPath
                    keyManager.addKey(expanded)
                    newKeyPath = ""
                }.disabled(newKeyPath.isEmpty)
            }

            Divider()

            // Key list
            if keyManager.keyPaths.isEmpty {
                Text("No keys added yet").foregroundColor(.secondary).padding()
            } else {
                List {
                    ForEach(keyManager.keyPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "key.fill").foregroundColor(.accentColor)
                            Text(path).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(action: { keyManager.removeKey(path) }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }.buttonStyle(.plain)
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .padding()
        .frame(minWidth: 400)
    }
}
