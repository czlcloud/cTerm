import SwiftUI
import SSHClient
import SessionManager

struct PortForwardPanel: View {
    @EnvironmentObject var sessionManager: SessionManager

    @State private var forwards: [ActiveForward] = []
    @State private var showAddSheet = false
    @State private var forwarders: [UUID: PortForwarder] = [:]

    struct ActiveForward: Identifiable {
        let id: UUID = UUID()
        var forward: PortForward
        var sessionLabel: String
        var sessionId: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            if forwards.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Port Forwards")
                        .font(.title3)
                    Text("Set up SSH tunnels to forward ports between local and remote hosts.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Add Port Forward") { showAddSheet = true }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                List {
                    ForEach(forwards) { af in
                        HStack {
                            Image(systemName: af.forward.type == .local ? "arrow.right"
                                    : (af.forward.type == .remote ? "arrow.left" : "arrow.triangle.swap"))
                                .foregroundColor(af.forward.status == .active ? .green : .red)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(af.forward.label).font(.body).fontWeight(.medium)
                                Text("via \(af.sessionLabel)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Circle().fill(af.forward.status == .active ? Color.green : Color.red).frame(width: 8, height: 8)
                            Button(action: { stopForward(af) }) {
                                Image(systemName: "stop.circle").foregroundColor(.red)
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 4)
                    }
                }.listStyle(.inset)

                HStack {
                    Button(action: { showAddSheet = true }) {
                        Label("Add", systemImage: "plus")
                    }.buttonStyle(.bordered)
                    Spacer()
                }.padding(.horizontal).padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddPortForwardSheet(sessionManager: sessionManager) { forward, sessionId, label in
                startForward(forward, sessionId: sessionId, label: label)
                showAddSheet = false
            }
        }
    }

    private func startForward(_ fw: PortForward, sessionId: UUID, label: String) {
        guard let conn = sessionManager.activeConnections[sessionId],
              conn.status == .authenticated else { return }

        let fwder = PortForwarder(connection: conn)
        var localPort = fw.localPort

        do {
            switch fw.type {
            case .local:
                let result = try fwder.startLocalForward(listenPort: &localPort, targetHost: fw.remoteHost, targetPort: fw.remotePort)
                let af = ActiveForward(forward: result, sessionLabel: label, sessionId: sessionId)
                forwards.append(af)
                forwarders[af.id] = fwder
            case .remote:
                let result = try fwder.startRemoteForward(listenPort: &localPort, targetHost: fw.remoteHost, targetPort: fw.remotePort)
                let af = ActiveForward(forward: result, sessionLabel: label, sessionId: sessionId)
                forwards.append(af)
                forwarders[af.id] = fwder
            case .dynamic:
                let result = try fwder.startDynamicForward(listenPort: &localPort)
                let af = ActiveForward(forward: result, sessionLabel: label, sessionId: sessionId)
                forwards.append(af)
                forwarders[af.id] = fwder
            }
        } catch {
            // Add as error state
            var errFw = fw
            errFw = PortForward(id: errFw.id, type: errFw.type, localPort: errFw.localPort,
                                remoteHost: errFw.remoteHost, remotePort: errFw.remotePort,
                                status: .error)
            let af = ActiveForward(forward: errFw, sessionLabel: label, sessionId: sessionId)
            forwards.append(af)
        }
    }

    private func stopForward(_ af: ActiveForward) {
        if let fwder = forwarders[af.id] {
            fwder.stopForward(af.forward.id)
            forwarders.removeValue(forKey: af.id)
        }
        forwards.removeAll { $0.id == af.id }
    }
}

// MARK: - Add Port Forward Sheet

struct AddPortForwardSheet: View {
    let sessionManager: SessionManager
    let onAdd: (PortForward, UUID, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var type: PortForwardType = .local
    @State private var localPort = ""
    @State private var remoteHost = "localhost"
    @State private var remotePort = ""
    @State private var selectedSessionId: UUID?

    private var availableSessions: [(UUID, String)] {
        sessionManager.activeConnections
            .filter { $0.value.status == .authenticated }
            .map { ($0.key, $0.value.hostname ?? "Session \($0.key.uuidString.prefix(8))") }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Port Forward").font(.title2).fontWeight(.bold)

            Picker("Type", selection: $type) {
                Text("Local (-L)").tag(PortForwardType.local)
                Text("Remote (-R)").tag(PortForwardType.remote)
                Text("Dynamic (-D)").tag(PortForwardType.dynamic)
            }.pickerStyle(.segmented)

            Picker("SSH Session:", selection: $selectedSessionId) {
                Text("Select session...").tag(nil as UUID?)
                ForEach(availableSessions, id: \.0) { id, label in
                    Text(label).tag(id as UUID?)
                }
            }

            if type != .dynamic {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Local Port").font(.caption).foregroundColor(.secondary)
                        TextField("8080", text: $localPort).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading) {
                        Text("Remote Host").font(.caption).foregroundColor(.secondary)
                        TextField("localhost", text: $remoteHost).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading) {
                        Text("Remote Port").font(.caption).foregroundColor(.secondary)
                        TextField("80", text: $remotePort).textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                HStack {
                    VStack(alignment: .leading) {
                        Text("SOCKS Port").font(.caption).foregroundColor(.secondary)
                        TextField("1080", text: $localPort).textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    guard let sid = selectedSessionId else { return }
                    let label = availableSessions.first(where: { $0.0 == sid })?.1 ?? "unknown"
                    let fw = PortForward(id: UUID(), type: type,
                                          localPort: Int(localPort) ?? 0,
                                          remoteHost: remoteHost,
                                          remotePort: Int(remotePort) ?? 0,
                                          status: .active)
                    onAdd(fw, sid, label)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(localPort.isEmpty || selectedSessionId == nil
                    || (type != .dynamic && (remoteHost.isEmpty || remotePort.isEmpty)))
            }
        }.padding().frame(width: 440)
    }
}
