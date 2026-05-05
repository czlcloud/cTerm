import AppKit
import Foundation

/// Represents a single character cell on the terminal screen with its visual attributes.
public struct Cell: Equatable, Sendable {
    /// The displayed character. Defaults to `" "` (space) for empty cells.
    public var character: Character

    /// The foreground (text) color.
    public var foregroundColor: NSColor

    /// The background color.
    public var backgroundColor: NSColor

    /// Whether the text is bold.
    public var bold: Bool

    /// Whether the text is italic.
    public var italic: Bool

    /// Whether the text is underlined.
    public var underline: Bool

    /// Whether the text blinks.
    public var blink: Bool

    /// Whether foreground and background colors are reversed.
    public var inverse: Bool

    /// Whether the text has strikethrough.
    public var strikethrough: Bool

    /// A cell with default values: space character, white-on-black colors, no attributes.
    nonisolated(unsafe) public static let empty = Cell()

    /// Creates a new terminal cell.
    public init(
        character: Character = " ",
        foregroundColor: NSColor = .white,
        backgroundColor: NSColor = .black,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        blink: Bool = false,
        inverse: Bool = false,
        strikethrough: Bool = false
    ) {
        self.character = character
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.blink = blink
        self.inverse = inverse
        self.strikethrough = strikethrough
    }
}
