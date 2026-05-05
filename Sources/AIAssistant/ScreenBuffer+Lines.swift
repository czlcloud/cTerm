import Foundation
import TerminalCore

public extension ScreenBuffer {
    /// Returns the visible content as an array of strings, one per row.
    /// Trailing whitespace is trimmed from each line to match typical
    /// terminal rendering behaviour.
  public var visibleLines: [String] {
        (0 ..< size.rows).map { row in
            (0 ..< size.cols)
                .map { col in cell(at: row, col: col).character }
                .reduce(into: "") { $0.append($1) }
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Returns all visible lines joined by a newline separator.
  public var visibleText: String {
        visibleLines.joined(separator: "\n")
    }
}
