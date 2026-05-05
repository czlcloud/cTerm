import SwiftUI
import HostStoreModule
import SessionManager

// MARK: - Workspace Picker (Launch / Switch)

struct WorkspacePickerView: View {
    @State private var workspaces: [WorkspaceDefinition] = []
    @State private var showCreateSheet = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("TerminalApp")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Choose a workspace to start working")
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 300)

            if workspaces.isEmpty {
                VStack(spacing: 16) {
                    Text("No workspaces yet")
                        .foregroundColor(.secondary)
                    Button("Create First Workspace") {
                        showCreateSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(workspaces) { workspace in
                    WorkspaceRow(workspace: workspace)
                }
                .listStyle(.plain)
                .frame(maxHeight: 300)

                HStack {
                    Button(action: { showCreateSheet = true }) {
                        Label("New Workspace", systemImage: "plus")
                    }
                }
            }
        }
        .padding(40)
        .frame(width: 500, height: 450)
        .sheet(isPresented: $showCreateSheet) {
            CreateWorkspaceSheet { new in
                workspaces.append(new)
                showCreateSheet = false
            }
        }
    }
}

struct WorkspaceRow: View {
    let workspace: WorkspaceDefinition

    var body: some View {
        HStack {
            Image(systemName: workspace.icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.body)
                    .fontWeight(.medium)
                if let desc = workspace.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("\(workspace.projects.count) projects")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct CreateWorkspaceSheet: View {
    let onCreate: (WorkspaceDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var icon = "folder"

    let icons = ["folder", "server.rack", "shield", "cloud", "laptopcomputer", "network"]

    var body: some View {
        VStack(spacing: 16) {
            Text("New Workspace").font(.title2).fontWeight(.bold)

            VStack(alignment: .leading) {
                Text("Icon").font(.caption).foregroundColor(.secondary)
                HStack {
                    ForEach(icons, id: \.self) { iconName in
                        Image(systemName: iconName)
                            .font(.title3)
                            .padding(8)
                            .background(icon == iconName ? Color.accentColor.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { icon = iconName }
                    }
                }
            }

            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $description).textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") {
                    let workspace = WorkspaceDefinition(
                        name: name,
                        icon: icon,
                        description: description.isEmpty ? nil : description,
                        rootPath: FileManager.default.urls(
                            for: .documentDirectory, in: .userDomainMask
                        )[0].appendingPathComponent("TerminalApp/\(name)")
                    )
                    onCreate(workspace)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Workspace Definition (App-level model)

struct WorkspaceDefinition: Identifiable, Codable {
    let id: UUID
    var name: String
    var icon: String
    var description: String?
    var rootPath: URL
    var projects: [ProjectDefinition]
    var defaultAIProvider: UUID?
    var defaultAIModel: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, icon: String = "folder",
         description: String? = nil, rootPath: URL,
         projects: [ProjectDefinition] = [],
         defaultAIProvider: UUID? = nil, defaultAIModel: UUID? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.rootPath = rootPath
        self.projects = projects
        self.defaultAIProvider = defaultAIProvider
        self.defaultAIModel = defaultAIModel
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

struct ProjectDefinition: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String?
    var hosts: [UUID]
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, description: String? = nil,
         hosts: [UUID] = [], tags: [String] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.hosts = hosts
        self.tags = tags
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
