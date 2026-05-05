import Foundation
import CoreGraphics
import TerminalCore

// MARK: - SplitNode

public indirect enum SplitNode: Codable, Equatable {
    case leaf(LeafSession)
    case horizontal([SplitNode])
    case vertical([SplitNode])

    // MARK: Computed Properties

    /// Returns all leaf sessions in the tree, in depth-first order.
  public var allLeaves: [LeafSession] {
        switch self {
        case .leaf(let leaf):
            return [leaf]
        case .horizontal(let children), .vertical(let children):
            return children.flatMap { $0.allLeaves }
        }
    }

    /// Returns the total number of leaf nodes in the tree.
  public var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .horizontal(let children), .vertical(let children):
            return children.reduce(0) { $0 + $1.leafCount }
        }
    }

    // MARK: Mutating Methods

    /// Replaces a leaf identified by its `id` with a new leaf.  If no matching
    /// leaf is found, the tree is unchanged.
  public mutating func replaceLeaf(_ leaf: LeafSession) {
        var copy = self
        replaceLeafById(leaf.id, with: leaf, at: &copy)
        self = copy
    }

    /// Returns the flattened index (into `allLeaves`) of the leaf with the given
    /// `id`, or `nil` if not found.
  public func findLeafIndex(by id: UUID) -> Int? {
        allLeaves.firstIndex(where: { $0.id == id })
    }

    /// Replaces the leaf at the given flattened index (see `allLeaves`) with a
    /// new leaf.  If the index is out of range, the tree is unchanged.
  public mutating func replaceLeafAtIndex(_ index: Int, with leaf: LeafSession) {
        let leaves = allLeaves
        guard index >= 0, index < leaves.count else { return }
        let targetId = leaves[index].id
        var copy = self
        replaceLeafById(targetId, with: leaf, at: &copy)
        self = copy
    }

    /// Removes the leaf identified by `id` from the tree.  If the leaf is the
    /// sole leaf in the entire tree the operation is a no-op.  When a split
    /// container is left with a single child after removal, that child replaces
    /// the container (the split is collapsed automatically).
  public mutating func removeLeaf(by id: UUID) {
        var copy = self
        _removeLeaf(by: id, at: &copy)
        self = copy
    }

    // MARK: Private Helpers

    private mutating func replaceLeafById(
        _ id: UUID,
        with leaf: LeafSession,
        at node: inout SplitNode
    ) {
        switch node {
        case .leaf(let existing):
            if existing.id == id {
                node = .leaf(leaf)
            }
        case .horizontal(var children):
            for index in children.indices {
                replaceLeafById(id, with: leaf, at: &children[index])
            }
            node = .horizontal(children)
        case .vertical(var children):
            for index in children.indices {
                replaceLeafById(id, with: leaf, at: &children[index])
            }
            node = .vertical(children)
        }
    }

    private mutating func _removeLeaf(
        by id: UUID,
        at node: inout SplitNode
    ) {
        switch node {
        case .leaf:
            // Cannot remove the only leaf in the tree.
            break

        case .horizontal(let children):
            var newChildren = [SplitNode]()
            for child in children {
                if case .leaf(let leaf) = child, leaf.id == id {
                    continue // Skip (remove) this leaf
                } else {
                    var mutableChild = child
                    _removeLeaf(by: id, at: &mutableChild)
                    newChildren.append(mutableChild)
                }
            }
            guard !newChildren.isEmpty else { break }
            node = newChildren.count == 1
                ? newChildren[0]
                : .horizontal(newChildren)

        case .vertical(let children):
            var newChildren = [SplitNode]()
            for child in children {
                if case .leaf(let leaf) = child, leaf.id == id {
                    continue
                } else {
                    var mutableChild = child
                    _removeLeaf(by: id, at: &mutableChild)
                    newChildren.append(mutableChild)
                }
            }
            guard !newChildren.isEmpty else { break }
            node = newChildren.count == 1
                ? newChildren[0]
                : .vertical(newChildren)
        }
    }
}

// MARK: - LeafSession

public struct LeafSession: Codable, Identifiable, Equatable {
    public let id: UUID
  public var hostId: UUID
  public var tabs: [TabState]
  public var activeTabIndex: Int
  public var proportion: CGFloat

    /// The currently active tab, or `nil` if the tab index is out of range.
  public var activeTab: TabState? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

public init(
        id: UUID = UUID(),
        hostId: UUID,
        tabs: [TabState] = [],
        activeTabIndex: Int = 0,
        proportion: CGFloat = 1.0
    ) {
        self.id = id
        self.hostId = hostId
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.proportion = proportion
    }
}

// MARK: - TabState

public struct TabState: Codable, Identifiable, Equatable {
    public let id: UUID
  public var title: String
  public var scrollbackBuffer: Data
  public var cursorPosition: CursorState
  public var terminalSize: TerminalSize

public init(
        id: UUID = UUID(),
        title: String,
        scrollbackBuffer: Data = Data(),
        cursorPosition: CursorState,
        terminalSize: TerminalSize
    ) {
        self.id = id
        self.title = title
        self.scrollbackBuffer = scrollbackBuffer
        self.cursorPosition = cursorPosition
        self.terminalSize = terminalSize
    }
}

// MARK: - WorkspaceState

public struct WorkspaceState: Codable {
  public var windows: [WindowState]
  public var activeWindowId: UUID
  public var updatedAt: Date

public init(
        windows: [WindowState] = [],
        activeWindowId: UUID = UUID(),
        updatedAt: Date = Date()
    ) {
        self.windows = windows
        self.activeWindowId = activeWindowId
        self.updatedAt = updatedAt
    }
}

// MARK: - WindowState

public struct WindowState: Codable, Identifiable {
    public let id: UUID
  public var rootNode: SplitNode
  public var frame: CGRect

public init(
        id: UUID = UUID(),
        rootNode: SplitNode,
        frame: CGRect = .zero
    ) {
        self.id = id
        self.rootNode = rootNode
        self.frame = frame
    }
}
