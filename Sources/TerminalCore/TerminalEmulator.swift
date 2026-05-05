import AppKit
import Foundation

// MARK: - TerminalEmulator

/// The central coordinator of the terminal emulation engine.
///
/// `TerminalEmulator` owns a `ScreenBuffer`, `VTParser`, and `VTermBridge`. It
/// implements the `VTParserDelegate` protocol to translate parsed escape sequences
/// into `ScreenBuffer` operations, and optionally feeds the same input to the
/// `VTermBridge` for libvterm-based rendering.
///
/// Usage:
/// ```swift
/// let emulator = TerminalEmulator()
/// emulator.onBufferUpdate = { /* refresh UI from emulator.screenBuffer */ }
/// emulator.write("Hello\r\n\u{1B}[31mRed text\u{1B}[0m")
/// ```
public final class TerminalEmulator: VTParserDelegate, @unchecked Sendable {
    // MARK: - Public Properties

    /// The primary screen buffer that holds the current terminal state.
    public let screenBuffer: ScreenBuffer

    /// An optional VTermBridge wrapping libvterm. The same input is fed to both
    /// the parser (for ScreenBuffer updates) and the bridge (for libvterm state).
    public let vtermBridge: VTermBridge?

    /// Called after every `write(_:)` with the range of dirty rows (first, last) or nil for full redraw.
    /// UI layers should connect to this to trigger precise redraws.
    public var onBufferUpdate: (((first: Int, last: Int)?) -> Void)?

    /// Called with raw input for secondary terminal engines (SwiftTerm, xterm.js).
    public var onRawWrite: ((String) -> Void)?

    /// Called when the emulator needs to send data back to the shell (e.g., DSR response).
    public var onSend: ((String) -> Void)?

    /// Optional working directory path, reported by the shell via OSC sequences.
    public var currentWorkingDirectory: String?

    // MARK: - Parser

    /// The escape sequence parser.
    private let parser: VTParser

    // MARK: - SGR State

    /// Current text attributes applied to newly written characters.
    private var currentAttrs = CellAttributes()

    /// Current foreground color for newly written characters.
    private var currentForeground: NSColor

    /// Current background color for newly written characters.
    private var currentBackground: NSColor

    /// Default colors to reset to on SGR 0
    private let defaultForeground: NSColor
    private let defaultBackground: NSColor

    // MARK: - Saved Cursor (DECSC / DECRC)

    private var savedRow: Int = 0
    private var savedCol: Int = 0

    // MARK: - Initialization

    public init(size: TerminalSize = .defaultSize, enableVTermBridge: Bool = false,
                foregroundColor: NSColor = .white, backgroundColor: NSColor = .black) {
        self.defaultForeground = foregroundColor
        self.defaultBackground = backgroundColor
        self.currentForeground = foregroundColor
        self.currentBackground = backgroundColor
        self.screenBuffer = ScreenBuffer(size: size)
        self.parser = VTParser()

        if enableVTermBridge {
            self.vtermBridge = VTermBridge(rows: Int32(size.rows), cols: Int32(size.cols))
        } else {
            self.vtermBridge = nil
        }

        self.parser.delegate = self
    }

    // MARK: - Input

    /// Feeds a string of terminal input to the emulator.
    ///
    /// The input is sent through both the escape sequence parser (which updates the
    /// `ScreenBuffer` via delegate callbacks) and the `VTermBridge`. After processing,
    /// `onBufferUpdate` is invoked.
    ///
    /// - Parameter input: The raw terminal input string.
    public func write(_ input: String) {
        onRawWrite?(input)
        screenBuffer.resetDirtyRange()
        for scalar in input.unicodeScalars {
            parser.feed(String(scalar))
        }
        screenBuffer.markCursorDirty()
        let cursorRow = screenBuffer.cursor.row
        if cursorRow > 0 {
            screenBuffer.markDirty(row: cursorRow - 1)
        }
        let range: (Int, Int)? = {
            if let min = screenBuffer.dirtyRowMin, let max = screenBuffer.dirtyRowMax {
                return (min, max)
            }
            return nil
        }()
        onBufferUpdate?(range)
    }

    /// Resizes the terminal to new dimensions.
    ///
    /// Both the `ScreenBuffer` and the `VTermBridge` (if active) are resized.
    ///
    /// - Parameter size: The new terminal size.
    public func resize(to size: TerminalSize) {
        screenBuffer.resize(to: size)
        vtermBridge?.resize(rows: Int32(size.rows), cols: Int32(size.cols))
    }

    /// Resets the terminal to its initial state (equivalent to the RIS escape sequence).
    public func reset() {
        screenBuffer.clear()
        currentAttrs = CellAttributes()
        currentForeground = defaultForeground
        currentBackground = defaultBackground
        savedRow = 0
        savedCol = 0
    }

    /// Returns display width: 2 for CJK/wide chars, 1 otherwise
    private static func width(of char: Character) -> Int {
        guard let scalar = char.unicodeScalars.first else { return 1 }
        let v = scalar.value
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) ||
           (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v) ||
           (0xFE10...0xFE1F).contains(v) || (0xFE30...0xFE6F).contains(v) ||
           (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) ||
           (0x1F300...0x1F5FF).contains(v) || (0x1F900...0x1F9FF).contains(v) ||
           (0x20000...0x2FFFF).contains(v) || (0x30000...0x3FFFF).contains(v) {
            return 2
        }
        return 1
    }

    // MARK: - VTParserDelegate

    public func writeCharacter(_ char: Character) {
        let row = screenBuffer.cursor.row
        let col = screenBuffer.cursor.col
        guard row >= 0, row < screenBuffer.size.rows,
              col >= 0, col < screenBuffer.size.cols else { return }

        var cell = Cell.empty
        cell.character = char
        cell.foregroundColor = currentForeground
        cell.backgroundColor = currentBackground
        cell.bold = currentAttrs.bold
        cell.italic = currentAttrs.italic
        cell.underline = currentAttrs.underline
        cell.blink = currentAttrs.blink
        cell.inverse = currentAttrs.inverse
        cell.strikethrough = currentAttrs.strikethrough

        screenBuffer.setCell(cell, at: row, col: col)

        // Advance cursor
        if autoWrap && col + 1 >= screenBuffer.size.cols {
            // Auto-wrap: move to next line
            screenBuffer.cursor.col = 0
            if row + 1 >= screenBuffer.size.rows {
                screenBuffer.scrollUp(lines: 1)
            } else {
                screenBuffer.cursor.row += 1
            }
        } else if !autoWrap && col + 1 >= screenBuffer.size.cols {
            // No wrap: stay at last column, overwrite last char
            screenBuffer.cursor.col = screenBuffer.size.cols - 1
        } else {
            let w = Self.width(of: char); screenBuffer.cursor.col += w
        }
    }

    public func cursorUp(_ count: Int) {
        let amount = max(count, 1)
        screenBuffer.cursor.row = max(screenBuffer.cursor.row - amount, 0)
    }

    public func cursorDown(_ count: Int) {
        let amount = max(count, 1)
        screenBuffer.cursor.row = min(screenBuffer.cursor.row + amount, screenBuffer.size.rows - 1)
    }

    public func cursorForward(_ count: Int) {
        let amount = max(count, 1)
        screenBuffer.cursor.col = min(screenBuffer.cursor.col + amount, screenBuffer.size.cols - 1)
    }

    public func cursorBack(_ count: Int) {
        let amount = max(count, 1)
        screenBuffer.cursor.col = max(screenBuffer.cursor.col - amount, 0)
    }

    public func cursorPosition(row: Int, col: Int) {
        // CSI row;col H / f uses 1-based values on the wire; convert to 0-based.
        let targetRow = max(0, row - 1)
        let targetCol = max(0, col - 1)
        screenBuffer.cursor.row = min(targetRow, screenBuffer.size.rows - 1)
        screenBuffer.cursor.col = min(targetCol, screenBuffer.size.cols - 1)
    }

    public func eraseDisplay(_ mode: Int) {
        let r = screenBuffer.cursor.row
        let c = screenBuffer.cursor.col

        switch mode {
        case 0:
            // Erase from cursor to end of display.
            for col in c..<screenBuffer.size.cols {
                screenBuffer.setCell(.empty, at: r, col: col)
            }
            for row in (r + 1)..<screenBuffer.size.rows {
                for col in 0..<screenBuffer.size.cols {
                    screenBuffer.setCell(.empty, at: row, col: col)
                }
            }

        case 1:
            // Erase from beginning of display to cursor.
            for col in 0...c {
                screenBuffer.setCell(.empty, at: r, col: col)
            }
            for row in 0..<r {
                for col in 0..<screenBuffer.size.cols {
                    screenBuffer.setCell(.empty, at: row, col: col)
                }
            }

        case 2, 3:
            // Erase entire display (and scrollback buffer for 3, treated identically).
            for row in 0..<screenBuffer.size.rows {
                for col in 0..<screenBuffer.size.cols {
                    screenBuffer.setCell(.empty, at: row, col: col)
                }
            }

        default:
            break
        }
    }

    public func eraseLine(_ mode: Int) {
        let r = screenBuffer.cursor.row
        let c = screenBuffer.cursor.col

        switch mode {
        case 0:
            // Erase from cursor to end of line.
            for col in c..<screenBuffer.size.cols {
                screenBuffer.setCell(.empty, at: r, col: col)
            }

        case 1:
            // Erase from beginning of line to cursor.
            for col in 0...c {
                screenBuffer.setCell(.empty, at: r, col: col)
            }

        case 2:
            // Erase entire line.
            for col in 0..<screenBuffer.size.cols {
                screenBuffer.setCell(.empty, at: r, col: col)
            }

        default:
            break
        }
    }

    public func sgr(_ params: [Int]) {
        let p = params.isEmpty ? [0] : params
        var index = 0

        while index < p.count {
            let param = p[index]
            switch param {
            case 0:
                // Reset all attributes.
                currentAttrs = CellAttributes()
                currentForeground = defaultForeground
                currentBackground = defaultBackground

            case 1:
                currentAttrs.bold = true
            case 3:
                currentAttrs.italic = true
            case 4:
                currentAttrs.underline = true
            case 5, 6:
                currentAttrs.blink = true
            case 7:
                currentAttrs.inverse = true
            case 9:
                currentAttrs.strikethrough = true

            case 22:
                currentAttrs.bold = false
            case 23:
                currentAttrs.italic = false
            case 24:
                currentAttrs.underline = false
            case 25:
                currentAttrs.blink = false
            case 27:
                currentAttrs.inverse = false
            case 29:
                currentAttrs.strikethrough = false

            // Foreground colors (standard 30-37).
            case 30...37:
                currentForeground = Self.ansiColor(param - 30)

            // Extended foreground color: 38;5;N or 38;2;R;G;B
            case 38:
                index += 1
                guard index < p.count else { break }
                let extType = p[index]
                if extType == 5, index + 1 < p.count {
                    // 256-color mode.
                    index += 1
                    currentForeground = Self.ansi256Color(p[index])
                } else if extType == 2, index + 3 < p.count {
                    // True color mode.
                    let r = p[index + 1]
                    let g = p[index + 2]
                    let b = p[index + 3]
                    currentForeground = Self.trueColor(r: r, g: g, b: b)
                    index += 3
                }

            case 39:
                currentForeground = defaultForeground

            // Background colors (standard 40-47).
            case 40...47:
                currentBackground = Self.ansiColor(param - 40)

            // Extended background color: 48;5;N or 48;2;R;G;B
            case 48:
                index += 1
                guard index < p.count else { break }
                let extType = p[index]
                if extType == 5, index + 1 < p.count {
                    index += 1
                    currentBackground = Self.ansi256Color(p[index])
                } else if extType == 2, index + 3 < p.count {
                    let r = p[index + 1]
                    let g = p[index + 2]
                    let b = p[index + 3]
                    currentBackground = Self.trueColor(r: r, g: g, b: b)
                    index += 3
                }

            case 49:
                currentBackground = defaultBackground

            // Bright foreground colors (90-97).
            case 90...97:
                currentForeground = Self.brightAnsiColor(param - 90)

            // Bright background colors (100-107).
            case 100...107:
                currentBackground = Self.brightAnsiColor(param - 100)

            default:
                break
            }
            index += 1
        }
    }

    public func lineFeed() {
        screenBuffer.lineFeed()
        screenBuffer.cursor.col = 0  // Auto CR on LF
    }

    public func carriageReturn() {
        screenBuffer.cursor.col = 0
    }

    public func backspace() {
        screenBuffer.cursor.col = max(screenBuffer.cursor.col - 1, 0)
    }

    public func reverseIndex() {
        if screenBuffer.cursor.row > 0 {
            screenBuffer.cursor.row -= 1
        } else {
            screenBuffer.scrollDown(lines: 1)
        }
    }

    public func saveCursor() {
        savedRow = screenBuffer.cursor.row
        savedCol = screenBuffer.cursor.col
    }

    public func restoreCursor() {
        screenBuffer.cursor.row = min(savedRow, screenBuffer.size.rows - 1)
        screenBuffer.cursor.col = min(savedCol, screenBuffer.size.cols - 1)
    }

    // MARK: - DEC Private Modes

    private var autoWrap = true       // DECAWM (mode 7)
    public var showCursor = true      // DECTCEM (mode 25)

    // Mouse tracking modes
    public enum MouseMode: Int {
        case none = 0
        case normal = 1000    // Button press/release
        case buttonEvent = 1002 // Motion while button held
        case anyEvent = 1003   // All motion
    }
    public var mouseMode: MouseMode = .none
    public var sgrMouseMode = false      // Mode 1006 — extended coordinates
    public var bracketedPaste = false     // Mode 2004 — bracket pasted text

    public func decSet(_ params: [Int]) {
        for p in params {
            switch p {
            case 7:    autoWrap = true
            case 25:   showCursor = true
            case 1000: mouseMode = .normal
            case 1002: mouseMode = .buttonEvent
            case 1003: mouseMode = .anyEvent
            case 1006: sgrMouseMode = true
            case 2004: bracketedPaste = true
            default: break
            }
        }
    }

    public func decReset(_ params: [Int]) {
        for p in params {
            switch p {
            case 7:    autoWrap = false
            case 25:   showCursor = false
            case 1000, 1002, 1003: mouseMode = .none
            case 1006: sgrMouseMode = false
            case 2004: bracketedPaste = false
            default: break
            }
        }
    }

    public func modeSet(_ params: [Int]) {
        // ANSI modes — rarely used, ignored for now
    }

    public func modeReset(_ params: [Int]) {
        // ANSI modes — rarely used, ignored for now
    }

    public func dsrCursorPosition() {
        let row = screenBuffer.cursor.row + 1
        let col = screenBuffer.cursor.col + 1
        onSend?("\u{1B}[\(row);\(col)R")
    }

    public func dsrStatusReport() {
        // Respond "OK" (no malfunction)
        onSend?("\u{1B}[0n")
    }

    public func daPrimary() {
        // Respond as VT102 with advanced video option
        onSend?("\u{1B}[?6c")
    }

    public func daSecondary() {
        onSend?("\u{1B}[>1;0;0c")
    }

    public func oscCwd(_ path: String) {
        currentWorkingDirectory = path
    }

    public func decQuery(_ mode: Int) {
        let value: Int = {
            switch mode {
            case 1: return 0         // DECCKM — cursor keys: normal
            case 6: return 0         // DECOM — origin mode: absolute
            case 7: return autoWrap ? 1 : 2  // DECAWM
            case 25: return showCursor ? 1 : 2 // DECTCEM
            case 1000: return mouseMode == .normal ? 1 : 2
            case 1002: return mouseMode == .buttonEvent ? 1 : (mouseMode == .normal ? 1 : 2)
            case 1003: return mouseMode == .anyEvent ? 1 : 2
            case 1006: return sgrMouseMode ? 1 : 2
            case 2004: return bracketedPaste ? 1 : 2
            default: return 0  // Unknown mode — report as not recognized
            }
        }()
        onSend?("\u{1B}[?\(mode);\(value)$y")
    }

    // MARK: - Mouse Reporting

    /// Build SGR mouse event sequence: ESC [ < Cb ; Cx ; Cy M/m
    public func mouseEvent(button: Int, row: Int, col: Int, pressed: Bool, motion: Bool = false) -> String? {
        guard mouseMode != .none else { return nil }
        if motion && mouseMode == .normal { return nil }

        var cb = button
        if motion { cb |= 32 }

        if sgrMouseMode {
            return "\u{1B}[<\(cb);\(col + 1);\(row + 1)\(pressed ? "M" : "m")"
        } else {
            // Fallback: X10 format (limited to 223 cols/rows)
            let cx = UInt8(min(col + 33, 255))
            let cy = UInt8(min(row + 33, 255))
            return "\u{1B}[M\(String(UnicodeScalar(cx)))\(String(UnicodeScalar(cy)))"
        }
    }

    public func putTab() {
        // Advance to the next 8-column tab stop.
        let nextTab = ((screenBuffer.cursor.col / 8) + 1) * 8
        screenBuffer.cursor.col = min(nextTab, screenBuffer.size.cols - 1)
    }

    // MARK: - Color Utilities

    /// Standard 8-color ANSI palette.
    private static let ansiPalette: [NSColor] = [
        NSColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1.0),
        NSColor(red: 0.80, green: 0.00, blue: 0.00, alpha: 1.0),
        NSColor(red: 0.00, green: 0.80, blue: 0.00, alpha: 1.0),
        NSColor(red: 0.80, green: 0.80, blue: 0.00, alpha: 1.0),
        NSColor(red: 0.00, green: 0.00, blue: 0.80, alpha: 1.0),
        NSColor(red: 0.80, green: 0.00, blue: 0.80, alpha: 1.0),
        NSColor(red: 0.00, green: 0.80, blue: 0.80, alpha: 1.0),
        NSColor(red: 0.80, green: 0.80, blue: 0.80, alpha: 1.0),
    ]

    /// Bright 8-color ANSI palette.
    private static let brightAnsiPalette: [NSColor] = [
        NSColor(red: 0.33, green: 0.33, blue: 0.33, alpha: 1.0),
        NSColor(red: 1.00, green: 0.33, blue: 0.33, alpha: 1.0),
        NSColor(red: 0.33, green: 1.00, blue: 0.33, alpha: 1.0),
        NSColor(red: 1.00, green: 1.00, blue: 0.33, alpha: 1.0),
        NSColor(red: 0.33, green: 0.33, blue: 1.00, alpha: 1.0),
        NSColor(red: 1.00, green: 0.33, blue: 1.00, alpha: 1.0),
        NSColor(red: 0.33, green: 1.00, blue: 1.00, alpha: 1.0),
        NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
    ]

    /// Returns a standard ANSI color (0-7) from the palette.
    private static func ansiColor(_ index: Int) -> NSColor {
        guard index >= 0, index < ansiPalette.count else { return .white }
        return ansiPalette[index]
    }

    /// Returns a bright ANSI color from the palette.
    private static func brightAnsiColor(_ index: Int) -> NSColor {
        guard index >= 0, index < brightAnsiPalette.count else { return .white }
        return brightAnsiPalette[index]
    }

    /// Converts a 256-color index to an NSColor using a 6x6x6 color cube plus grayscale ramp.
    private static func ansi256Color(_ index: Int) -> NSColor {
        guard index >= 0, index <= 255 else { return .white }

        if index < 8 {
            return ansiPalette[index]
        }
        if index < 16 {
            return brightAnsiPalette[index - 8]
        }
        if index < 232 {
            let cubeIndex = index - 16
            let r = cubeIndex / 36
            let g = (cubeIndex / 6) % 6
            let b = cubeIndex % 6
            return NSColor(red: CGFloat(r * 51) / 255.0,
                          green: CGFloat(g * 51) / 255.0,
                          blue: CGFloat(b * 51) / 255.0,
                          alpha: 1.0)
        }
        let gray = CGFloat((index - 232) * 10 + 8) / 255.0
        return NSColor(red: gray, green: gray, blue: gray, alpha: 1.0)
    }

    /// Creates an NSColor from 8-bit RGB components (true color).
    private static func trueColor(r: Int, g: Int, b: Int) -> NSColor {
        let clamp = { (v: Int) -> CGFloat in CGFloat(min(max(v, 0), 255)) / 255.0 }
        return NSColor(red: clamp(r), green: clamp(g), blue: clamp(b), alpha: 1.0)
    }
}
