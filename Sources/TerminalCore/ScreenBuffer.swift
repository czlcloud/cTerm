import Foundation

/// A screen buffer that manages a 2D grid of terminal cells with cursor tracking.
///
/// `ScreenBuffer` provides the fundamental data storage for a terminal emulator's
/// visible screen, supporting operations like scrolling, cursor movement, character
/// writing with autowrap, and resize.
public final class ScreenBuffer {
    /// The 2D grid of cells, indexed as `buffer[row][col]`.
    private var buffer: [[Cell]]

    /// The current dimensions of the buffer.
    public private(set) var size: TerminalSize

    /// The current cursor position and visibility state.
    public var cursor: CursorState

    /// Tracks the range of rows dirtied since last `dirtyRangeConsumed`.
    /// `nil` means full buffer needs redraw (resize, clear).
    public private(set) var dirtyRowMin: Int?
    public private(set) var dirtyRowMax: Int?

    /// Creates a screen buffer with the specified dimensions.
    ///
    /// - Parameter size: The initial size of the buffer. Defaults to `TerminalSize.defaultSize` (24x80).
    public init(size: TerminalSize = .defaultSize) {
        self.size = size
        self.cursor = CursorState()
        self.buffer = []
        for _ in 0..<size.rows {
            buffer.append(Array(repeating: Cell.empty, count: size.cols))
        }
    }

    // MARK: - Cell Access

    /// Returns the cell at the specified position.
    ///
    /// If the coordinates are out of bounds, returns `Cell.empty` without crashing.
    ///
    /// - Parameters:
    ///   - row: The row index (0-based).
    ///   - col: The column index (0-based).
    /// - Returns: The cell at the position, or `Cell.empty` if out of bounds.
    public func cell(at row: Int, col: Int) -> Cell {
        guard row >= 0, row < size.rows, col >= 0, col < size.cols else {
            return .empty
        }
        return buffer[row][col]
    }

    /// Sets the cell at the specified position.
    ///
    /// Out-of-bounds coordinates are silently ignored.
    ///
    /// - Parameters:
    ///   - cell: The cell to place.
    ///   - row: The row index (0-based).
    ///   - col: The column index (0-based).
    public func setCell(_ cell: Cell, at row: Int, col: Int) {
        guard row >= 0, row < size.rows, col >= 0, col < size.cols else {
            return
        }
        buffer[row][col] = cell
        markDirty(row: row)
    }

    /// Call at the start of an update cycle to reset dirty tracking.
    public func resetDirtyRange() {
        dirtyRowMin = nil; dirtyRowMax = nil
    }

    /// Marks a row as modified (also marks cursor row to ensure cursor redraws).
    func markDirty(row: Int) {
        guard row >= 0, row < size.rows else { return }
        dirtyRowMin = dirtyRowMin.map { min($0, row) } ?? row
        dirtyRowMax = dirtyRowMax.map { max($0, row) } ?? row
    }

    /// Marks all rows as dirty (for full-buffer operations like scroll/resize).
    private func markAllDirty() {
        dirtyRowMin = 0; dirtyRowMax = size.rows - 1
    }

    // MARK: - Buffer Operations

    /// Clears the entire buffer to empty cells and resets the cursor to the home position (0, 0).
    public func clear() {
        for row in 0..<size.rows {
            for col in 0..<size.cols {
                buffer[row][col] = Cell.empty
            }
        }
        cursor.row = 0
        cursor.col = 0
        markAllDirty()
    }

    /// Scrolls the buffer content up by the specified number of lines.
    ///
    /// New empty lines are added at the bottom. If `lines` is greater than or equal to
    /// the buffer height, the buffer is fully cleared.
    ///
    /// - Parameter lines: The number of lines to scroll up. Defaults to `1`.
    public func scrollUp(lines: Int = 1) {
        guard lines > 0 else { return }
        if lines >= size.rows {
            clear()
            return
        }
        buffer.removeFirst(lines)
        for _ in 0..<lines {
            buffer.append(Array(repeating: Cell.empty, count: size.cols))
        }
        markAllDirty()
    }

    /// Scrolls the buffer content down by the specified number of lines.
    ///
    /// New empty lines are added at the top. If `lines` is greater than or equal to
    /// the buffer height, the buffer is fully cleared.
    ///
    /// - Parameter lines: The number of lines to scroll down. Defaults to `1`.
    public func scrollDown(lines: Int = 1) {
        guard lines > 0 else { return }
        if lines >= size.rows {
            clear()
            return
        }
        buffer.removeLast(lines)
        for _ in 0..<lines {
            buffer.insert(Array(repeating: Cell.empty, count: size.cols), at: 0)
        }
        markAllDirty()
    }

    /// Marks the cursor row as dirty (call when cursor moves without writing).
    public func markCursorDirty() {
        markDirty(row: cursor.row)
    }

    // MARK: - Resize

    /// Resizes the buffer to new dimensions, preserving as much content as possible.
    ///
    /// Content that fits within the new dimensions is retained; content outside is discarded.
    /// The cursor is clamped to the new bounds.
    ///
    /// - Parameter newSize: The desired new size.
    public func resize(to newSize: TerminalSize) {
        guard newSize != size else { return }

        var newBuffer: [[Cell]] = []

        for row in 0..<newSize.rows {
            var newRow: [Cell] = []
            for col in 0..<newSize.cols {
                if row < buffer.count, col < buffer[row].count {
                    newRow.append(buffer[row][col])
                } else {
                    newRow.append(Cell.empty)
                }
            }
            newBuffer.append(newRow)
        }

        buffer = newBuffer
        size = newSize
        clampCursor()
        markAllDirty()
    }

    // MARK: - Cursor Movement

    /// Moves the cursor one column to the right, clamped to the rightmost column.
    public func cursorRight() {
        cursor.col = min(cursor.col + 1, size.cols - 1)
    }

    /// Moves the cursor one column to the left, clamped to the leftmost column (0).
    public func cursorLeft() {
        cursor.col = max(cursor.col - 1, 0)
    }

    /// Moves the cursor one row up, clamped to the top row (0).
    public func cursorUp() {
        cursor.row = max(cursor.row - 1, 0)
    }

    /// Moves the cursor one row down, clamped to the bottom row.
    public func cursorDown() {
        cursor.row = min(cursor.row + 1, size.rows - 1)
    }

    /// Moves the cursor to the first column of the current line (carriage return).
    public func carriageReturn() {
        cursor.col = 0
    }

    /// Advances the cursor to the next line (line feed).
    ///
    /// If the cursor is on the last line, the buffer scrolls up instead.
    public func lineFeed() {
        if cursor.row + 1 >= size.rows {
            scrollUp(lines: 1)
        } else {
            cursor.row += 1
        }
    }

    // MARK: - Character Writing

    /// Writes a character at the current cursor position and advances the cursor.
    ///
    /// When the cursor reaches the end of a line, it automatically wraps to the beginning
    /// of the next line. If already on the last line, the buffer scrolls up.
    ///
    /// This method sets only the `character` property of the cell at the cursor position.
    /// Use `setCell(_:at:col:)` if you need to set visual attributes as well.
    ///
    /// - Parameter char: The character to write.
    public func write(_ char: Character) {
        guard cursor.row >= 0, cursor.row < size.rows,
              cursor.col >= 0, cursor.col < size.cols else {
            return
        }

        // Place the character at the current cursor position.
        markDirty(row: cursor.row)
        buffer[cursor.row][cursor.col].character = char

        // Advance cursor with autowrap.
        if cursor.col + 1 >= size.cols {
            cursor.col = 0
            if cursor.row + 1 >= size.rows {
                scrollUp(lines: 1)
            } else {
                cursor.row += 1
            }
        } else {
            cursor.col += 1
        }
    }

    // MARK: - Private Helpers

    /// Clamps the cursor row and column to valid ranges for the current buffer size.
    private func clampCursor() {
        cursor.row = min(max(cursor.row, 0), size.rows - 1)
        cursor.col = min(max(cursor.col, 0), size.cols - 1)
    }
}
