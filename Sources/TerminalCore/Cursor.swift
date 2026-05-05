import Foundation

/// Defines the dimensions of a terminal screen.
public struct TerminalSize: Codable, Equatable, Sendable {
    /// Number of rows (vertical dimension).
    public var rows: Int

    /// Number of columns (horizontal dimension).
    public var cols: Int

    /// The default terminal size: 24 rows by 80 columns.
    nonisolated(unsafe) public static let defaultSize = TerminalSize(rows: 24, cols: 80)

    /// Creates a terminal size.
    ///
    /// - Parameters:
    ///   - rows: The number of rows.
    ///   - cols: The number of columns.
    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }
}

/// The visual shape of the terminal cursor.
public enum CursorShape: Codable, Equatable, Sendable {
    /// A solid block that covers the entire character cell.
    case block
    /// An underscore shape at the bottom of the character cell.
    case underline
    /// A vertical bar shape on the left side of the character cell.
    case bar
}

/// Represents the current state and position of the terminal cursor.
public struct CursorState: Codable, Equatable {
    /// The row position (0-based).
    public var row: Int

    /// The column position (0-based).
    public var col: Int

    /// Whether the cursor is visible.
    public var visible: Bool

    /// The visual shape of the cursor.
    public var shape: CursorShape

    /// Creates a new cursor state.
    ///
    /// - Parameters:
    ///   - row: The initial row (0-based). Defaults to `0`.
    ///   - col: The initial column (0-based). Defaults to `0`.
    ///   - visible: Whether the cursor is visible. Defaults to `true`.
    ///   - shape: The cursor shape. Defaults to `.block`.
    public init(
        row: Int = 0,
        col: Int = 0,
        visible: Bool = true,
        shape: CursorShape = .block
    ) {
        self.row = row
        self.col = col
        self.visible = visible
        self.shape = shape
    }
}
