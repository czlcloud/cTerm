import AppKit
import CVTerm
import Foundation

// MARK: - CellAttributes

/// Represents the text attributes (SGR) extracted from a terminal cell.
public struct CellAttributes: Equatable {
    /// Whether the text is bold.
    public var bold: Bool = false
    /// Whether the text is italic.
    public var italic: Bool = false
    /// Whether the text is underlined.
    public var underline: Bool = false
    /// Whether the text blinks.
    public var blink: Bool = false
    /// Whether foreground and background colors are reversed.
    public var inverse: Bool = false
    /// Whether the text has strikethrough.
    public var strikethrough: Bool = false

    /// Creates a `CellAttributes` value from a raw libvterm attribute bitmask.
    /// - Parameter attrs: The `attrs` field value from `VTermScreenCell`.
    public init(attrs: UInt32) {
        self.bold = (attrs & UInt32(VTERM_ATTR_BOLD)) != 0
        self.italic = (attrs & UInt32(VTERM_ATTR_ITALIC)) != 0
        self.underline = (attrs & UInt32(VTERM_ATTR_UNDERLINE)) != 0
        self.blink = (attrs & UInt32(VTERM_ATTR_BLINK)) != 0
        self.inverse = (attrs & UInt32(VTERM_ATTR_REVERSE)) != 0
        self.strikethrough = (attrs & UInt32(VTERM_ATTR_STRIKETHROUGH)) != 0
    }

    /// Creates an empty attributes value (all flags `false`).
    public init() {}
}

// MARK: - VTermBridge

/// A Swift wrapper around the libvterm C library.
///
/// `VTermBridge` manages a `VTerm` instance and its associated `VTermScreen`,
/// providing a safe Swift interface for terminal input/output, screen cell access,
/// and terminal resizing. Damage and output events are delivered via optional
/// Swift closures.
public final class VTermBridge {
    // MARK: - Callbacks

    /// Invoked when libvterm reports a damaged (changed) region of the screen.
    /// Parameters are: (startRow, startCol, endRow, endCol).
    public var onDamage: ((Int32, Int32, Int32, Int32) -> Void)?

    /// Invoked when libvterm produces output (e.g., in response to a device query).
    public var onOutput: ((String) -> Void)?

    // MARK: - Private Properties

    /// The underlying libvterm terminal instance.
    private let vt: OpaquePointer

    /// The screen associated with the terminal.
    private let screen: OpaquePointer

    /// The state associated with the terminal.
    private let state: OpaquePointer

    // MARK: - Initialization

    /// Creates a new VTerm bridge with the specified dimensions.
    ///
    /// - Parameters:
    ///   - rows: The number of rows in the terminal.
    ///   - cols: The number of columns in the terminal.
    public init(rows: Int32, cols: Int32) {
        guard let vt = vterm_new(rows, cols) else {
            fatalError("VTermBridge: vterm_new returned nil — libvterm failed to allocate.")
        }
        self.vt = vt

        guard let screen = vterm_obtain_screen(vt) else {
            vterm_free(vt)
            fatalError("VTermBridge: vterm_obtain_screen returned nil.")
        }
        self.screen = screen

        guard let state = vterm_obtain_state(vt) else {
            vterm_free(vt)
            fatalError("VTermBridge: vterm_obtain_state returned nil.")
        }
        self.state = state

        // Register callbacks with self as unmanaged context.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        vterm_wrapper_set_damage_callback(screen, Self._damageCallback, selfPtr)
        vterm_wrapper_set_output_callback(vt, Self._outputCallback, selfPtr)

        // Flush initial damage (the entire screen).
        vterm_screen_flush_damage(screen)
    }

    deinit {
        // Null out callbacks before freeing to prevent dangling pointer callbacks.
        let nullPtr: UnsafeMutableRawPointer? = nil
        vterm_wrapper_set_damage_callback(screen, nil, nullPtr)
        vterm_wrapper_set_output_callback(vt, nil, nullPtr)
        vterm_free(vt)
    }

    // MARK: - Input / Output

    /// Writes a string of terminal input to libvterm for processing.
    ///
    /// - Parameter input: The raw input string (UTF-8 encoded).
    public func write(_ input: String) {
        let utf8Bytes = Array(input.utf8)
        vterm_input_write(vt, utf8Bytes, utf8Bytes.count)
        vterm_screen_flush_damage(screen)
    }

    // MARK: - Resize

    /// Resizes the terminal screen to new dimensions.
    ///
    /// - Parameters:
    ///   - rows: The new number of rows.
    ///   - cols: The new number of columns.
    public func resize(rows: Int32, cols: Int32) {
        vterm_wrapper_resize(vt, screen, rows, cols)
        vterm_screen_flush_damage(screen)
    }

    // MARK: - Cell Access

    /// Returns the contents of a cell at the specified position.
    ///
    /// - Parameters:
    ///   - row: The row index (0-based).
    ///   - col: The column index (0-based).
    /// - Returns: A tuple containing the character string, foreground color, background color,
    ///   and text attributes of the cell.
    public func getCell(row: Int32, col: Int32) -> (char: String, fg: NSColor, bg: NSColor, attrs: CellAttributes) {
        var rawCell = VTermScreenCell()
        vterm_screen_get_cell(screen, row, col, &rawCell)

        // Decode the UTF-8 character bytes.
        let charStr = decodeChars(chars: rawCell.chars, widths: rawCell.widths)

        // Convert libvterm colors (0-255 range) to NSColor (0.0-1.0 range).
        let fg = NSColor(
            red: CGFloat(rawCell.fg.red) / 255.0,
            green: CGFloat(rawCell.fg.green) / 255.0,
            blue: CGFloat(rawCell.fg.blue) / 255.0,
            alpha: 1.0
        )
        let bg = NSColor(
            red: CGFloat(rawCell.bg.red) / 255.0,
            green: CGFloat(rawCell.bg.green) / 255.0,
            blue: CGFloat(rawCell.bg.blue) / 255.0,
            alpha: 1.0
        )

        let attrs = CellAttributes(attrs: rawCell.attrs)

        return (charStr, fg, bg, attrs)
    }

    // MARK: - Screen Dimensions

    /// The number of rows in the terminal screen.
    public var rowCount: Int32 {
        vterm_wrapper_get_rows(screen)
    }

    /// The number of columns in the terminal screen.
    public var colCount: Int32 {
        vterm_wrapper_get_cols(screen)
    }

    // MARK: - Private Helpers

    /// Decodes a UTF-8 character sequence from the cell's `chars` and `widths` arrays.
    ///
    /// libvterm stores up to 6 UTF-8 bytes per cell. The `widths` array indicates the
    /// column width contribution of each character; a `widths[i]` value of `0` means
    /// no further characters exist in the cell.
    ///
    /// - Parameters:
    ///   - chars: The raw UTF-8 byte buffer from `VTermScreenCell.chars`.
    ///   - widths: The character width array from `VTermScreenCell.widths`.
    /// - Returns: The decoded string, or an empty string if decoding fails.
    private func decodeChars(chars: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8), widths: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> String {
        let bytes: [UInt8] = [chars.0, chars.1, chars.2, chars.3, chars.4, chars.5]
        let ws: [UInt8] = [widths.0, widths.1, widths.2, widths.3, widths.4, widths.5]

        var validBytes: [UInt8] = []
        for i in 0..<6 {
            guard ws[i] != 0 else { break }
            validBytes.append(bytes[i])
        }

        return String(decoding: validBytes, as: UTF8.self)
    }

    // MARK: - C Callbacks

    /// C-callable damage callback. Receives the damaged region and forwards it to the Swift `onDamage` closure.
    private static let _damageCallback: @convention(c) (VTermRect, UnsafeMutableRawPointer?) -> Void = { rect, user in
        guard let user else { return }
        let bridge = Unmanaged<VTermBridge>.fromOpaque(user).takeUnretainedValue()
        bridge.onDamage?(rect.start_row, rect.start_col, rect.end_row, rect.end_col)
    }

    /// C-callable output callback. Receives output bytes from libvterm and forwards them as a String.
    private static let _outputCallback: vterm_output_callback = { bytes, len, user in
        guard let user, let bytes else { return }
        let bridge = Unmanaged<VTermBridge>.fromOpaque(user).takeUnretainedValue()
        guard len > 0 else { return }
        let data = Data(bytes: bytes, count: len)
        if let str = String(data: data, encoding: .utf8) {
            bridge.onOutput?(str)
        }
    }
}
