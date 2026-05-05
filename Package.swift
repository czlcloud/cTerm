// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TerminalApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cTerm", targets: ["AppUI"]),
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
        .library(name: "SSHClient", targets: ["SSHClient"]),
        .library(name: "SessionManager", targets: ["SessionManager"]),
        .library(name: "HostStoreModule", targets: ["HostStoreModule"]),
        .library(name: "AIProvider", targets: ["AIProvider"]),
        .library(name: "AIAssistant", targets: ["AIAssistant"]),
        .library(name: "AIAgent", targets: ["AIAgent"]),
        .library(name: "SkillManager", targets: ["SkillManager"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CVTerm",
            path: "Sources/CVTerm",
            linkerSettings: [
                .linkedLibrary("vterm"),
                .unsafeFlags(["-L/opt/homebrew/lib"])
            ]
        ),
        .target(
            name: "CLibssh2",
            path: "Sources/CLibssh2",
            linkerSettings: [
                .linkedLibrary("ssh2"),
                .unsafeFlags(["-L/opt/homebrew/lib"])
            ]
        ),
        .target(
            name: "TerminalCore",
            dependencies: ["CVTerm"],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib"])]
        ),
        .target(
            name: "SSHClient",
            dependencies: ["CLibssh2", "TerminalCore"],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib"])]
        ),
        .target(name: "SessionManager", dependencies: ["SSHClient", "TerminalCore"]),
        .target(name: "HostStoreModule", dependencies: [], path: "Sources/HostStore"),
        .target(name: "AIProvider", dependencies: []),
        .target(name: "AIAssistant", dependencies: ["AIProvider", "TerminalCore"]),
        .target(name: "AIAgent", dependencies: ["AIProvider", "SSHClient"]),
        .target(name: "SkillManager", dependencies: ["AIProvider"]),
        .executableTarget(
            name: "AppUI",
            dependencies: [
                "SessionManager", "HostStoreModule",
                "AIProvider", "AIAssistant", "AIAgent", "SkillManager", "Citadel",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            linkerSettings: [
                .linkedLibrary("vterm"),
                .linkedLibrary("ssh2"),
                .unsafeFlags(["-L/opt/homebrew/lib"])
            ]
        ),
        // Test targets (sources not yet created)
        // .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
        // .testTarget(name: "SSHClientTests", dependencies: ["SSHClient"]),
        // .testTarget(name: "SessionManagerTests", dependencies: ["SessionManager"]),
        // .testTarget(name: "HostStoreTests", dependencies: ["HostStoreModule"]),
        // .testTarget(name: "AIProviderTests", dependencies: ["AIProvider"]),
        // .testTarget(name: "SkillManagerTests", dependencies: ["SkillManager"]),
    ]
)
