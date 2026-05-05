import Foundation
import AppKit

public struct TerminalSettings: Codable, Equatable, Sendable {
    public var fontSize: Double = 13
    public var fontName: String = "Menlo"
    public var shellPath: String = "/bin/zsh"
    public var shellArgs: [String] = ["-i"]
    public var workingDirectory: String? = nil  // Initial CWD for cloned tabs

    public var foregroundColor: CodableColor = .white
    public var backgroundColor: CodableColor = .black
    public var cursorColor: CodableColor = .white
    public var backgroundOpacity: Double = 1.0
    public var selectedScheme: String = ColorSchemePreset.systemDefault.rawValue
    public var globalKeepAlive: Bool = true
    public var keepAliveInterval: Int = 30

    public var ansiColors: [CodableColor] = CodableColor.defaultAnsiPalette
    public var ansiBrightColors: [CodableColor] = CodableColor.defaultBrightPalette

    public nonisolated(unsafe) static let `default` = TerminalSettings()
}

// MARK: - Codable NSColor wrapper

public struct CodableColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public var nsColor: NSColor { NSColor(red: red, green: green, blue: blue, alpha: alpha) }

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init(_ color: NSColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = r; self.green = g; self.blue = b; self.alpha = a
    }

    public nonisolated(unsafe) static let white = CodableColor(red: 1, green: 1, blue: 1)
    public nonisolated(unsafe) static let black = CodableColor(red: 0, green: 0, blue: 0)
    public nonisolated(unsafe) static let red = CodableColor(red: 0.8, green: 0, blue: 0)
    public nonisolated(unsafe) static let green = CodableColor(red: 0, green: 0.8, blue: 0)
    public nonisolated(unsafe) static let blue = CodableColor(red: 0, green: 0, blue: 0.8)
    public nonisolated(unsafe) static let cyan = CodableColor(red: 0, green: 0.8, blue: 0.8)
    public nonisolated(unsafe) static let magenta = CodableColor(red: 0.8, green: 0, blue: 0.8)
    public nonisolated(unsafe) static let yellow = CodableColor(red: 0.8, green: 0.8, blue: 0)

    public nonisolated(unsafe) static let defaultAnsiPalette: [CodableColor] = [
        .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white
    ]
    public nonisolated(unsafe) static let defaultBrightPalette: [CodableColor] = [
        CodableColor(red: 0.33, green: 0.33, blue: 0.33),
        CodableColor(red: 1, green: 0.33, blue: 0.33),
        CodableColor(red: 0.33, green: 1, blue: 0.33),
        CodableColor(red: 1, green: 1, blue: 0.33),
        CodableColor(red: 0.33, green: 0.33, blue: 1),
        CodableColor(red: 1, green: 0.33, blue: 1),
        CodableColor(red: 0.33, green: 1, blue: 1),
        CodableColor(red: 1, green: 1, blue: 1),
    ]
}

// MARK: - Color Schemes

public enum ColorSchemePreset: String, CaseIterable, Codable {
    case systemDefault = "System Default"
    case solarizedDark = "Solarized Dark"
    case dracula = "Dracula"
    case gruvboxDark = "Gruvbox Dark"
    case nord = "Nord"
    case tokyoNight = "Tokyo Night"
    case monokai = "Monokai"

    public func apply(to settings: inout TerminalSettings) {
        switch self {
        case .systemDefault:
            settings.foregroundColor = .white
            settings.backgroundColor = .black
            settings.cursorColor = .white
            settings.ansiColors = CodableColor.defaultAnsiPalette
            settings.ansiBrightColors = CodableColor.defaultBrightPalette

        case .solarizedDark:
            settings.foregroundColor = CodableColor(red: 0.51, green: 0.58, blue: 0.59)
            settings.backgroundColor = CodableColor(red: 0.00, green: 0.17, blue: 0.21)
            settings.cursorColor = CodableColor(red: 0.51, green: 0.58, blue: 0.59)
            settings.ansiColors = [
                CodableColor(red: 0.03, green: 0.13, blue: 0.18),  // 0
                CodableColor(red: 0.86, green: 0.20, blue: 0.18),  // 1
                CodableColor(red: 0.52, green: 0.60, blue: 0.00),  // 2
                CodableColor(red: 0.71, green: 0.54, blue: 0.00),  // 3
                CodableColor(red: 0.15, green: 0.55, blue: 0.82),  // 4
                CodableColor(red: 0.83, green: 0.15, blue: 0.53),  // 5
                CodableColor(red: 0.16, green: 0.63, blue: 0.60),  // 6
                CodableColor(red: 0.93, green: 0.91, blue: 0.83),  // 7
            ]
            settings.ansiBrightColors = settings.ansiColors.map {
                CodableColor(red: min($0.red * 1.3, 1), green: min($0.green * 1.3, 1), blue: min($0.blue * 1.3, 1))
            }

        case .dracula:
            settings.foregroundColor = CodableColor(red: 0.97, green: 0.97, blue: 0.95)
            settings.backgroundColor = CodableColor(red: 0.16, green: 0.16, blue: 0.24)
            settings.cursorColor = CodableColor(red: 0.97, green: 0.97, blue: 0.95)
            settings.ansiColors = [
                CodableColor(red: 0.13, green: 0.13, blue: 0.13),
                CodableColor(red: 1.00, green: 0.33, blue: 0.33),
                CodableColor(red: 0.31, green: 0.98, blue: 0.48),
                CodableColor(red: 0.95, green: 0.90, blue: 0.37),
                CodableColor(red: 0.38, green: 0.53, blue: 0.93),
                CodableColor(red: 0.74, green: 0.44, blue: 0.93),
                CodableColor(red: 0.54, green: 0.89, blue: 0.94),
                CodableColor(red: 0.87, green: 0.87, blue: 0.85),
            ]
            settings.ansiBrightColors = [
                CodableColor(red: 0.33, green: 0.33, blue: 0.33),
                CodableColor(red: 1.00, green: 0.44, blue: 0.44),
                CodableColor(red: 0.44, green: 1.00, blue: 0.56),
                CodableColor(red: 1.00, green: 0.93, blue: 0.51),
                CodableColor(red: 0.51, green: 0.63, blue: 1.00),
                CodableColor(red: 0.82, green: 0.56, blue: 1.00),
                CodableColor(red: 0.65, green: 0.93, blue: 0.98),
                CodableColor(red: 1.00, green: 1.00, blue: 1.00),
            ]

        case .gruvboxDark:
            settings.foregroundColor = CodableColor(red: 0.92, green: 0.89, blue: 0.78)
            settings.backgroundColor = CodableColor(red: 0.16, green: 0.16, blue: 0.13)
            settings.cursorColor = CodableColor(red: 0.92, green: 0.89, blue: 0.78)
            settings.ansiColors = [
                CodableColor(red: 0.16, green: 0.16, blue: 0.13),
                CodableColor(red: 0.80, green: 0.19, blue: 0.15),
                CodableColor(red: 0.60, green: 0.69, blue: 0.18),
                CodableColor(red: 0.85, green: 0.60, blue: 0.13),
                CodableColor(red: 0.27, green: 0.52, blue: 0.62),
                CodableColor(red: 0.69, green: 0.38, blue: 0.56),
                CodableColor(red: 0.41, green: 0.64, blue: 0.54),
                CodableColor(red: 0.67, green: 0.64, blue: 0.58),
            ]
            settings.ansiBrightColors = [
                CodableColor(red: 0.36, green: 0.36, blue: 0.31),
                CodableColor(red: 0.98, green: 0.24, blue: 0.19),
                CodableColor(red: 0.72, green: 0.80, blue: 0.21),
                CodableColor(red: 0.98, green: 0.71, blue: 0.16),
                CodableColor(red: 0.33, green: 0.62, blue: 0.75),
                CodableColor(red: 0.84, green: 0.45, blue: 0.68),
                CodableColor(red: 0.49, green: 0.78, blue: 0.65),
                CodableColor(red: 0.78, green: 0.76, blue: 0.69),
            ]

        case .nord:
            settings.foregroundColor = CodableColor(red: 0.85, green: 0.87, blue: 0.89)
            settings.backgroundColor = CodableColor(red: 0.18, green: 0.21, blue: 0.26)
            settings.cursorColor = CodableColor(red: 0.85, green: 0.87, blue: 0.89)
            settings.ansiColors = [
                CodableColor(red: 0.23, green: 0.26, blue: 0.33),
                CodableColor(red: 0.75, green: 0.27, blue: 0.29),
                CodableColor(red: 0.64, green: 0.75, blue: 0.42),
                CodableColor(red: 0.92, green: 0.77, blue: 0.41),
                CodableColor(red: 0.51, green: 0.63, blue: 0.84),
                CodableColor(red: 0.71, green: 0.44, blue: 0.61),
                CodableColor(red: 0.53, green: 0.75, blue: 0.77),
                CodableColor(red: 0.93, green: 0.93, blue: 0.95),
            ]
            settings.ansiBrightColors = settings.ansiColors.map {
                CodableColor(red: min($0.red * 1.2, 1), green: min($0.green * 1.2, 1), blue: min($0.blue * 1.2, 1))
            }

        case .tokyoNight:
            settings.foregroundColor = CodableColor(red: 0.76, green: 0.80, blue: 0.90)
            settings.backgroundColor = CodableColor(red: 0.10, green: 0.11, blue: 0.18)
            settings.cursorColor = CodableColor(red: 0.76, green: 0.80, blue: 0.90)
            settings.ansiColors = [
                CodableColor(red: 0.13, green: 0.15, blue: 0.22),
                CodableColor(red: 0.88, green: 0.22, blue: 0.29),
                CodableColor(red: 0.62, green: 0.76, blue: 0.28),
                CodableColor(red: 0.89, green: 0.72, blue: 0.23),
                CodableColor(red: 0.48, green: 0.60, blue: 0.88),
                CodableColor(red: 0.61, green: 0.36, blue: 0.65),
                CodableColor(red: 0.45, green: 0.73, blue: 0.76),
                CodableColor(red: 0.66, green: 0.67, blue: 0.72),
            ]
            settings.ansiBrightColors = settings.ansiColors.map {
                CodableColor(red: min($0.red * 1.3, 1), green: min($0.green * 1.3, 1), blue: min($0.blue * 1.3, 1))
            }

        case .monokai:
            settings.foregroundColor = CodableColor(red: 0.97, green: 0.97, blue: 0.95)
            settings.backgroundColor = CodableColor(red: 0.15, green: 0.15, blue: 0.15)
            settings.cursorColor = CodableColor(red: 0.97, green: 0.97, blue: 0.95)
            settings.ansiColors = [
                CodableColor(red: 0.15, green: 0.15, blue: 0.15),
                CodableColor(red: 0.98, green: 0.15, blue: 0.26),
                CodableColor(red: 0.65, green: 0.89, blue: 0.18),
                CodableColor(red: 0.90, green: 0.86, blue: 0.25),
                CodableColor(red: 0.40, green: 0.62, blue: 0.93),
                CodableColor(red: 0.68, green: 0.27, blue: 0.67),
                CodableColor(red: 0.40, green: 0.84, blue: 0.84),
                CodableColor(red: 0.93, green: 0.93, blue: 0.93),
            ]
            settings.ansiBrightColors = settings.ansiColors.map {
                CodableColor(red: min($0.red * 1.4, 1), green: min($0.green * 1.4, 1), blue: min($0.blue * 1.4, 1))
            }
        }
    }
}
