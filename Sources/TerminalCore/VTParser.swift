import Foundation

// MARK: - VTParserDelegate

/// Delegate protocol for receiving parsed terminal control sequence events.
///
/// Implement this protocol to respond to escape sequences, control characters,
/// and other terminal input parsed by `VTParser`.
public protocol VTParserDelegate: AnyObject {
    /// Called when a printable character should be written at the current cursor position.
  func writeCharacter(_ char: Character)

    /// Moves the cursor up by the specified number of lines.
  func cursorUp(_ count: Int)

    /// Moves the cursor down by the specified number of lines.
  func cursorDown(_ count: Int)

    /// Moves the cursor forward (right) by the specified number of columns.
  func cursorForward(_ count: Int)

    /// Moves the cursor backward (left) by the specified number of columns.
  func cursorBack(_ count: Int)

    /// Moves the cursor to an absolute position (1-based row and column).
  func cursorPosition(row: Int, col: Int)

    /// Erases part or all of the display.
    /// - Parameter mode: 0 = cursor to end, 1 = start to cursor, 2 = all.
  func eraseDisplay(_ mode: Int)

    /// Erases part or all of the current line.
    /// - Parameter mode: 0 = cursor to end, 1 = start to cursor, 2 = all.
  func eraseLine(_ mode: Int)

    /// Applies Select Graphic Rendition (SGR) parameters to set text attributes and colors.
    /// - Parameter params: An array of numeric parameters from the SGR sequence.
  func sgr(_ params: [Int])

    /// Moves the cursor to the next line (line feed).
  func lineFeed()

    /// Moves the cursor to the first column of the current line (carriage return).
  func carriageReturn()

    /// Moves the cursor back one column (backspace).
  func backspace()

    /// Performs a reverse index: moves cursor up one line, scrolling down if at the top.
  func reverseIndex()

    /// Saves the current cursor position (DECSC).
  func saveCursor()

    /// Restores the previously saved cursor position (DECRC).
  func restoreCursor()

    /// Resets the terminal to its initial state (RIS).
    func reset()

    /// DEC private mode set (DECSET: CSI ? Pm h)
    func decSet(_ params: [Int])

    /// DEC private mode reset (DECRST: CSI ? Pm l)
    func decReset(_ params: [Int])

    /// ANSI mode set (SM: CSI Pm h)
    func modeSet(_ params: [Int])

    /// ANSI mode reset (RM: CSI Pm l)
    func modeReset(_ params: [Int])

    /// DSR — Device Status Report (cursor position query)
    func dsrCursorPosition()
    /// DSR — Device Status Report (status query)
    func dsrStatusReport()
    /// DA — Device Attributes (primary)
    func daPrimary()
    /// DA — Device Attributes (secondary)
    func daSecondary()
    /// DECRPM — Query DEC private mode value (CSI ? Pm $ p)
    func decQuery(_ mode: Int)
    /// OSC 7 — Current working directory report
    func oscCwd(_ path: String)

    /// Advances the cursor to the next tab stop.
  func putTab()
}

// MARK: - VTParser

/// Parses ANSI/Xterm terminal escape sequences from raw input text.
///
/// `VTParser` processes input character-by-character, detecting CSI (Control Sequence
/// Introducer) sequences (`ESC[`), handling single-character control codes, and
/// forwarding decoded events to a `VTParserDelegate`.
///
/// Currently supported CSI sequences:
/// - `A` / `B` / `C` / `D` : Cursor Up / Down / Forward / Back
/// - `H` / `f` : Cursor Position
/// - `J` : Erase in Display
/// - `K` : Erase in Line
/// - `m` : Select Graphic Rendition (SGR)
/// - `s` / `u` : Save / Restore Cursor (DEC private mode variants)
public final class VTParser {
    /// The delegate that receives parsed events. Held weakly to avoid retain cycles.
    public var delegate: VTParserDelegate?

    /// Internal parser state machine states.
    private enum State {
        /// Waiting for new input; printable characters and control chars are processed directly.
        case idle
        /// Received an ESC (`\u{1B}`) character; waiting for the next byte to determine sequence type.
        case escape
        /// Received `ESC [` — building a CSI parameter string before the final command byte.
        case csi
        /// Received `ESC ]` — building an Operating System Command (OSC) string.
        case osc
    }

    /// The current parser state.
    private var state: State = .idle

    /// Buffer accumulating numeric/parameter characters for the current CSI sequence.
    private var paramBuffer: String = ""

    /// Buffer accumulating characters for the current OSC sequence.
    private var oscBuffer: String = ""

    /// Stack of saved cursor positions for saveCursor / restoreCursor (DECSC / DECRC).
    private var savedRow: Int = 0
    private var savedCol: Int = 0

    /// Creates a new parser instance.
    public init() {}

    /// Feeds a string of terminal input to the parser.
    ///
    /// The input is processed character-by-character. Control characters and escape
    /// sequences are decoded and forwarded to the delegate as callback invocations.
    ///
    /// - Parameter input: The raw terminal input string to parse.
    public func feed(_ input: String) {
        for char in input {
            process(char)
        }
    }

    // MARK: - Character Processing

    /// Process a single character through the state machine.
    private func process(_ char: Character) {
        switch state {
        case .idle:
            processIdle(char)
        case .escape:
            processEscape(char)
        case .csi:
            processCSI(char)
        case .osc:
            processOSC(char)
        }
    }

    /// Process a character while in the idle state.
    private func processIdle(_ char: Character) {
        switch char {
        case "\u{1B}": // ESC
            state = .escape

        case "\u{07}": // BEL
            // Bell — typically ignored by terminal emulators; no delegate action needed.
            break

        case "\u{08}": // BS (Backspace)
            delegate?.backspace()

        case "\u{09}": // HT (Horizontal Tab)
            delegate?.putTab()

        case "\u{0A}": // LF (Line Feed)
            delegate?.lineFeed()

        case "\u{0B}": // VT (Vertical Tab)
            delegate?.carriageReturn()
            delegate?.lineFeed()

        case "\u{0C}": // FF (Form Feed)
            delegate?.carriageReturn()
            delegate?.lineFeed()

        case "\u{0D}": // CR (Carriage Return)
            delegate?.carriageReturn()

        case "\u{7F}": // DEL — ignore
            break

        default:
            // Printable characters (including multi-byte UTF-8 sequences)
            if char >= " " || char.isASCII == false {
                delegate?.writeCharacter(char)
            }
        }
    }

    /// Process a character after receiving ESC.
    private func processEscape(_ char: Character) {
        state = .idle

        switch char {
        case "[": // CSI introducer
            state = .csi
            paramBuffer.removeAll()

        case "]": // OSC introducer
            state = .osc
            oscBuffer.removeAll()

        case "7": // DECSC — Save cursor
            delegate?.saveCursor()

        case "8": // DECRC — Restore cursor
            delegate?.restoreCursor()

        case "s": // ESC s — Save cursor (alternate form)
            delegate?.saveCursor()

        case "u": // ESC u — Restore cursor (alternate form)
            delegate?.restoreCursor()

        case "=": // DECPAM — Application Keypad mode (ignore, no delegate action)
            break

        case ">": // DECPNM — Normal Keypad mode (ignore)
            break

        case "c": // RIS — Reset to initial state
            delegate?.reset()

        case "D": // IND — Index (line feed)
            delegate?.lineFeed()

        case "E": // NEL — Next Line (CR + LF)
            delegate?.carriageReturn()
            delegate?.lineFeed()

        case "H": // HTS — Horizontal tab set (ignore)
            break

        case "M": // RI — Reverse Index
            delegate?.reverseIndex()

        case "Z": // DECID — Identify terminal (same as CSI c; ignore)
            break

        default:
            // Unrecognized escape sequence — silently ignore
            break
        }
    }

    /// Process a character inside a CSI sequence (`ESC[ ... `).
    private func processCSI(_ char: Character) {
        if char >= "0", char <= "9" {
            paramBuffer.append(char)
        } else if char == ";" {
            paramBuffer.append(char)
        } else if char == "?" || char == ">" {
            // DEC private / Secondary DA prefix
            paramBuffer.append(char)
        } else if char == " " || char == "\"" || char == "'" || char == "#" || char == "!" || char == "$" {
            // Intermediate bytes — keep in buffer (used by DECRPM, etc.)
            paramBuffer.append(char)
        } else if char < " " {
            // Control character in CSI — abort, reset, and re-process
            state = .idle
            processIdle(char)
        } else {
            // Final byte — dispatch the sequence
            dispatchCSI(char)
            state = .idle
        }
    }

    /// Process a character inside an OSC sequence (`ESC] ... BEL or ST`).
    private func processOSC(_ char: Character) {
        if char == "\u{07}" || char == "\u{1B}" {
            // OSC is terminated by BEL or by ST (ESC \)
            // For ST (ESC \), the \ will be consumed on next call via the escape handler
            state = .idle
            // Currently no delegate action defined for OSC; could be extended for
            // setting window title, icon name, etc.
            oscBuffer.removeAll()
        } else if char == "\u{07}" || (char == "\u{1B}" && oscBuffer.count >= 2) {
            // OSC terminated — parse OSC 7 for CWD
            let content = String(oscBuffer)
            if content.hasPrefix("7;file://") {
                let path = String(content.dropFirst(9))  // Remove "7;file://"
                if let hostEnd = path.firstIndex(of: "/") {
                    let dir = String(path[hostEnd...])  // Path after hostname
                    delegate?.oscCwd(dir)
                }
            }
            state = .idle
            oscBuffer.removeAll()
        } else {
            oscBuffer.append(char)
        }
    }

    // MARK: - CSI Dispatch

    /// Parse the accumulated parameter string and invoke the appropriate delegate method.
    private func dispatchCSI(_ finalByte: Character) {
        // Remove DEC private prefix '?' if present
        let paramsString = paramBuffer.replacingOccurrences(of: "?", with: "")
        let params = parseParameters(paramsString)

        switch finalByte {
        case "A":
            delegate?.cursorUp(params.first ?? 1)
        case "B":
            delegate?.cursorDown(params.first ?? 1)
        case "C":
            delegate?.cursorForward(params.first ?? 1)
        case "D":
            delegate?.cursorBack(params.first ?? 1)
        case "H", "f":
            // Cursor Position: rows and cols are 1-based in the escape sequence
            let row = params.indices.contains(0) ? params[0] : 1
            let col = params.indices.contains(1) ? params[1] : 1
            delegate?.cursorPosition(row: max(1, row), col: max(1, col))
        case "J":
            delegate?.eraseDisplay(params.first ?? 0)
        case "K":
            delegate?.eraseLine(params.first ?? 0)
        case "m":
            delegate?.sgr(params)
        case "s": // ANSI.SYS variant — save cursor
            delegate?.saveCursor()
        case "u": // ANSI.SYS variant — restore cursor
            delegate?.restoreCursor()
        case "n": // DSR — Device Status Report
            if params.first == 6 {
                delegate?.dsrCursorPosition()
            } else if params.first == 5 {
                delegate?.dsrStatusReport()
            }
        case "c": // DA — Device Attributes (primary, secondary)
            if paramBuffer.contains(">") {
                delegate?.daSecondary()
            } else if params.first == 0 {
                delegate?.daPrimary()
            }
        case "h": // DECSET
            if paramBuffer.contains("?") || paramBuffer.contains(">") {
                delegate?.decSet(params)
            } else {
                delegate?.modeSet(params)
            }
        case "l": // DECRST
            if paramBuffer.contains("?") || paramBuffer.contains(">") {
                delegate?.decReset(params)
            } else {
                delegate?.modeReset(params)
            }
        case "p":
            if paramBuffer.contains("$"), let mode = params.first {
                delegate?.decQuery(mode)
            }
        default:
            break
        }
    }

    /// Parse a semicolon-separated parameter string into an array of integers.
    ///
    /// Empty parameters (e.g., from sequences like `ESC[;m`) are treated as `0`.
    /// If the string is empty, returns an empty array.
    ///
    /// - Parameter string: The raw parameter string (e.g., `"3;5"`).
    /// - Returns: An array of parsed integer parameters.
    private func parseParameters(_ string: String) -> [Int] {
        guard !string.isEmpty else { return [] }
        return string
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }
}
