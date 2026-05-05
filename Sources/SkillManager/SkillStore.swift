import Foundation

// MARK: - SkillStoreError

public enum SkillStoreError: LocalizedError, Sendable {
    case skillNotFound(id: UUID)
    case storageUnavailable
    case encodingFailed(Error)
    case decodingFailed(Error)
    case importDuplicate(id: UUID)

    public var errorDescription: String? {
        switch self {
        case .skillNotFound(let id):
            return "Skill with id \(id) not found."
        case .storageUnavailable:
            return "Could not access storage directory."
        case .encodingFailed(let error):
            return "Failed to encode skills data: \(error.localizedDescription)"
        case .decodingFailed(let error):
            return "Failed to decode skills data: \(error.localizedDescription)"
        case .importDuplicate(let id):
            return "A skill with id \(id) already exists."
        }
    }
}

// MARK: - SkillStore

/// Thread-safe, main-actor-bound store that manages the skill library.
/// Skills are persisted to `~/Library/Application Support/TerminalApp/skills.json`.
@MainActor
public final class SkillStore: ObservableObject {
    @Published public var skills: [Skill] = []

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: Initialization

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        loadFromDisk()
    }

    // MARK: Storage URL

    private var storageURL: URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("TerminalApp", isDirectory: true)
            .appendingPathComponent("skills.json")
    }

    // MARK: - CRUD

    /// Adds a new skill and persists the store.
    /// - Parameter skill: The skill to add.
    public func addSkill(_ skill: Skill) throws {
        skills.append(skill)
        try saveToDisk()
    }

    /// Replaces an existing skill identified by its id.
    /// - Parameter skill: The updated skill.
    public func updateSkill(_ skill: Skill) throws {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else {
            throw SkillStoreError.skillNotFound(id: skill.id)
        }
        skills[index] = skill
        try saveToDisk()
    }

    /// Removes a skill by id.
    /// - Parameter id: The UUID of the skill to remove.
    public func deleteSkill(id: UUID) throws {
        guard let index = skills.firstIndex(where: { $0.id == id }) else {
            throw SkillStoreError.skillNotFound(id: id)
        }
        skills.remove(at: index)
        try saveToDisk()
    }

    /// Returns all skills belonging to a given category.
    /// - Parameter category: The category to filter by.
    /// - Returns: An array of matching skills.
    public func skills(in category: SkillCategory) -> [Skill] {
        skills.filter { $0.category == category }
    }

    /// Toggles the `enabled` flag on a skill and persists.
    /// - Parameter id: The UUID of the skill.
    public func toggleSkill(id: UUID) throws {
        guard let index = skills.firstIndex(where: { $0.id == id }) else {
            throw SkillStoreError.skillNotFound(id: id)
        }
        skills[index].enabled.toggle()
        try saveToDisk()
    }

    // MARK: - Import / Export

    /// Exports a single skill as JSON data.
    /// - Parameter skill: The skill to export.
    /// - Returns: Encoded JSON data.
    public func exportSkill(_ skill: Skill) throws -> Data {
        do {
            return try encoder.encode(skill)
        } catch {
            throw SkillStoreError.encodingFailed(error)
        }
    }

    /// Imports a skill from JSON data.
    /// If a skill with the same id does not already exist it is added to the store.
    /// - Parameter data: JSON data representing a `Skill`.
    /// - Returns: The decoded skill.
    @discardableResult
    public func importSkill(from data: Data) throws -> Skill {
        let skill: Skill
        do {
            skill = try decoder.decode(Skill.self, from: data)
        } catch {
            throw SkillStoreError.decodingFailed(error)
        }
        if skills.contains(where: { $0.id == skill.id }) {
            throw SkillStoreError.importDuplicate(id: skill.id)
        }
        skills.append(skill)
        try saveToDisk()
        return skill
    }

    /// Imports an array of skills from JSON data.
    /// Skills whose id already exists in the store are silently skipped.
    /// - Parameter data: JSON data representing `[Skill]`.
    /// - Returns: The array of newly imported skills.
    @discardableResult
    public func importSkills(from data: Data) throws -> [Skill] {
        let imported: [Skill]
        do {
            imported = try decoder.decode([Skill].self, from: data)
        } catch {
            throw SkillStoreError.decodingFailed(error)
        }
        var added: [Skill] = []
        for skill in imported {
            if !skills.contains(where: { $0.id == skill.id }) {
                skills.append(skill)
                added.append(skill)
            }
        }
        if !added.isEmpty {
            try saveToDisk()
        }
        return added
    }

    /// Exports every skill in the store as a JSON array.
    /// - Returns: Encoded JSON data.
    public func exportAllSkills() throws -> Data {
        do {
            return try encoder.encode(skills)
        } catch {
            throw SkillStoreError.encodingFailed(error)
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let url = storageURL else { return }
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            skills = try decoder.decode([Skill].self, from: data)
        } catch {
            NSLog("SkillStore: Failed to load skills – \(error.localizedDescription). Starting with empty store.")
            skills = []
        }
    }

    private func saveToDisk() throws {
        guard let url = storageURL else {
            throw SkillStoreError.storageUnavailable
        }
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let data = try encoder.encode(skills)
        try data.write(to: url, options: [.atomic])
    }
}
