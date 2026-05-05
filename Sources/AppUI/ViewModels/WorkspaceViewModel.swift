import SwiftUI
import Foundation

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var workspaces: [WorkspaceDefinition] = []
    @Published var selectedWorkspace: WorkspaceDefinition?
    @Published var selectedProject: ProjectDefinition?
    @Published var isCreatingWorkspace = false
    @Published var isCreatingProject = false
    @Published var isEditingContext = false
    @Published var contextFileContent = ""

    private let storageURL: URL

    init() {
        storageURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("TerminalApp/workspaces.json")
    }

    func loadWorkspaces() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([WorkspaceDefinition].self, from: data) else {
            workspaces = []
            return
        }
        workspaces = decoded
    }

    func saveWorkspaces() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: storageURL)
    }

    func createWorkspace(name: String, icon: String, description: String?) -> WorkspaceDefinition {
        let rootPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalApp/Workspaces/\(name)")
        let workspace = WorkspaceDefinition(name: name, icon: icon, description: description, rootPath: rootPath)
        workspaces.append(workspace)

        // Create directory structure
        try? FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rootPath.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rootPath.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rootPath.appendingPathComponent("layouts"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rootPath.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rootPath.appendingPathComponent("logs"), withIntermediateDirectories: true)

        // Create default CONTEXT.md and RULES.md
        let contextContent = "# \(name)\n\nDescribe this workspace's purpose and environment here.\n"
        try? contextContent.write(to: rootPath.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
        let rulesContent = "# Rules for \(name)\n\nDefine AI behavior rules for this workspace here.\n"
        try? rulesContent.write(to: rootPath.appendingPathComponent("RULES.md"), atomically: true, encoding: .utf8)

        saveWorkspaces()
        return workspace
    }

    func deleteWorkspace(_ workspace: WorkspaceDefinition) {
        workspaces.removeAll { $0.id == workspace.id }
        saveWorkspaces()
    }

    func addProject(to workspaceId: UUID, name: String, description: String?) -> ProjectDefinition {
        let project = ProjectDefinition(name: name, description: description)
        if let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            workspaces[idx].projects.append(project)

            // Create project directory
            let projectPath = workspaces[idx].rootPath
                .appendingPathComponent("projects/\(name)")
            try? FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
            let projectContext = "# \(name)\n\nDescribe this project here.\n"
            try? projectContext.write(to: projectPath.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
            let projectRules = "# Rules for \(name)\n\nDefine project-specific rules here.\n"
            try? projectRules.write(to: projectPath.appendingPathComponent("RULES.md"), atomically: true, encoding: .utf8)
        }
        saveWorkspaces()
        return project
    }

    func addHostToProject(hostId: UUID, projectId: UUID, workspaceId: UUID) {
        if let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }),
           let projIdx = workspaces[wsIdx].projects.firstIndex(where: { $0.id == projectId }) {
            if !workspaces[wsIdx].projects[projIdx].hosts.contains(hostId) {
                workspaces[wsIdx].projects[projIdx].hosts.append(hostId)
            }
        }
        saveWorkspaces()
    }

    func loadContext(for workspaceId: UUID, projectId: UUID?) -> String {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return "" }
        let contextURL = projectId
            .flatMap { pid in workspace.projects.first { $0.id == pid } }
            .map { workspace.rootPath.appendingPathComponent("projects/\($0.name)/CONTEXT.md") }
            ?? workspace.rootPath.appendingPathComponent("CONTEXT.md")
        return (try? String(contentsOf: contextURL, encoding: .utf8)) ?? ""
    }

    func updateContext(for workspaceId: UUID, projectId: UUID?, content: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        let contextURL = projectId
            .flatMap { pid in workspace.projects.first { $0.id == pid } }
            .map { workspace.rootPath.appendingPathComponent("projects/\($0.name)/CONTEXT.md") }
            ?? workspace.rootPath.appendingPathComponent("CONTEXT.md")
        try? content.write(to: contextURL, atomically: true, encoding: .utf8)
    }
}
