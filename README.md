# cTerm

> **Alpha Release** — functional but with known issues and missing features. Please read before use.

A native macOS terminal emulator built with SwiftTerm + libssh2. Supports local shell, SSH, Claude Code integration, and multi-tab workspaces.

## Installation

1. Download `cTerm.dmg`
2. Double-click to mount, drag `cTerm.app` to `Applications`
3. First launch: **Right-click → Open** (ad-hoc signed, Gatekeeper warning)

## Features

- Local terminal (zsh), rendered with SwiftTerm
- SSH (password / key / agent authentication)
- Jump host support
- Multi-tab + split pane
- Workspace management (isolated working directories)
- Claude Code integration (one-click session launch)
- Floating sidebar panels (Hosts, File Transfer, AI config, etc.)
- Terminal theme presets (Matrix, Hacker Green, Amber Mono, Cyber Blue)
- SFTP file transfer panel (dual-pane drag & drop)

## Shortcuts (Terminal)

| Key | Action |
|-----|--------|
| `Cmd+F` | Search |
| `Cmd+C/V` | Copy / Paste |

## Dependencies (Development)

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal rendering engine
- [libssh2](https://libssh2.org) — SSH protocol
- [libvterm](https://launchpad.net/libvterm) — VT100 parsing
- [Citadel](https://github.com/orlandos-nl/Citadel) — SFTP client

The packaged build bundles libvterm and libssh2. Homebrew is not required for end users.

## Known Issues (Alpha)

- **Window resize**: Claude TUI input area may offset after large window resize or fullscreen
- **Tab focus**: Clicking a tab title does not auto-focus the terminal; click inside the terminal area
- **Content loss on resize**: Expanding the window significantly may cause rendering artifacts or content drift
- **No session persistence**: All sessions are lost when the app quits
- **No scrollback search**: Search only covers the visible screen area
- **SSH not fully tested**: Basic SSH works, edge cases untested
- **Limited SFTP**: Download via drag works; upload drag not yet supported
- **Settings not live**: Font/color changes require a new terminal to take effect

## Architecture

```
cTerm
├── SwiftUI (AppUI)         — UI, views, view models
├── SessionManager           — session lifecycle, splits, persistence
├── SSHClient               — SSH connection, channels, SFTP (libssh2)
├── TerminalCore             — terminal emulation, parser, screen buffer
├── AIProvider              — AI API integration
├── AIAssistant/AIAgent     — AI assistance features
└── HostStore               — host config persistence
```

## Development

```bash
# Requirements
# macOS 14.0+, Xcode 16+, Swift 6.0

# Install dependencies
brew install libssh2 libvterm

# Build
cd cTerm
swift build

# Run
swift run

# Package
swift build -c release
# then manually create .app bundle and DMG
```

## License

MIT
