import Foundation
import Darwin  // for glob(), fnmatch

// MARK: - SSHConfigParser

/// Parses OpenSSH-style `~/.ssh/config` files into `[HostDefinition]`.
///
/// Only concrete (non-wildcard) `Host` entries produce definitions.
/// Supported directives: `HostName`, `Port`, `User`, `IdentityFile`,
/// and `Include` (including glob patterns).
public final class SSHConfigParser {

    // MARK: Init

public init() {}

    // MARK: Public API

    /// Parses an SSH config file and returns the host definitions found.
    /// If the file does not exist or is unreadable an empty array is returned.
  public func parse(path: String = NSHomeDirectory() + "/.ssh/config") -> [HostDefinition] {
        let url = URL(fileURLWithPath: path)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines)
        var hosts: [HostDefinition] = []
        var currentPatterns: [String] = []
        var currentConfig: [String: [String]] = [:]
        var pendingContinuation: String? = nil

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and full-line comments.
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // ----- Handle line continuation (trailing backslash) -----
            if let partial = pendingContinuation {
                // Appends the continued fragment and re-processes when
                // the continuation ends.
                if line.hasSuffix("\\") {
                    pendingContinuation = partial + " " + line.dropLast().trimmingCharacters(in: .whitespaces)
                    continue
                } else {
                    let combined = partial + " " + line
                    pendingContinuation = nil
                    processLine(combined, patterns: &currentPatterns, config: &currentConfig, hosts: &hosts)
                    continue
                }
            }

            if line.hasSuffix("\\") {
                pendingContinuation = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            processLine(line, patterns: &currentPatterns, config: &currentConfig, hosts: &hosts)
        }

        // Flush the last block in case the file doesn't end with a blank line.
        if !currentPatterns.isEmpty {
            let defs = buildDefinitions(patterns: currentPatterns, config: currentConfig)
            hosts.append(contentsOf: defs)
        }

        return hosts
    }

    // MARK: - Line Processing

    /// Dispatches a single (fully assembled) line.
    private func processLine(
        _ line: String,
        patterns: inout [String],
        config: inout [String: [String]],
        hosts: inout [HostDefinition]
    ) {
        guard let (directive, rawValue) = parseDirective(line) else { return }

        let key = directive.lowercased()
        let value = rawValue.trimmingCharacters(in: .whitespaces)

        switch key {
        case "include":
            processInclude(value, into: &hosts)

        case "host":
            // Flush previous block.
            if !patterns.isEmpty {
                let defs = buildDefinitions(patterns: patterns, config: config)
                hosts.append(contentsOf: defs)
            }
            patterns = value
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            config = [:]

        default:
            config[key, default: []].append(value)
        }
    }

    // MARK: - Parsing Helpers

    /// Splits a line into (directive, value) on the first whitespace run.
    private func parseDirective(_ line: String) -> (String, String)? {
        let scanner = Scanner(string: line)
        scanner.caseSensitive = false
        scanner.charactersToBeSkipped = nil

        guard let key = scanner.scanCharacters(from: .alphanumerics.union(.init(charactersIn: "_"))) else {
            return nil
        }

        // Skip whitespace.
        scanner.scanCharacters(from: .whitespaces)

        // Everything remaining is the value (trimmed).
        let value = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        return (key, value)
    }

    // MARK: - Host Definition Builder

    /// Creates `[HostDefinition]` from parsed patterns and config values.
    /// Wildcard / negation patterns (`*`, `?`, `!`) are silently skipped.
    private func buildDefinitions(patterns: [String], config: [String: [String]]) -> [HostDefinition] {
        let defaultUser = NSUserName()
        var definitions: [HostDefinition] = []

        for pattern in patterns {
            guard !pattern.contains("*"),
                  !pattern.contains("?"),
                  !pattern.contains("!") else { continue }

            let hostname = config["hostname"]?.first ?? pattern
            let user     = config["user"]?.first ?? defaultUser
            let port: UInt16 = {
                guard let raw = config["port"]?.first, let p = UInt16(raw.trimmingCharacters(in: .whitespaces)) else { return 22 }
                return p
            }()

            let authMode: AuthMode = {
                if let files = config["identityfile"], let first = files.first {
                    return .keyFile(path: resolveIdentityFilePath(first), passphraseKeychainRef: nil)
                }
                return .sshAgent
            }()

            let def = HostDefinition(
                source: .sshConfig,
                label: pattern,
                hostname: hostname,
                port: port,
                username: user,
                authMode: authMode,
                keepAliveInterval: 0,
                group: nil,
                tags: [],
                colorMark: nil,
                notes: nil,
                jumpHost: nil
            )
            definitions.append(def)
        }

        return definitions
    }

    // MARK: - Path Resolution

    /// Resolves an `IdentityFile` value to an absolute path.
    ///
    /// - `~` / `~/...` is home-directory expanded.
    /// - Relative paths (e.g. `id_rsa`) are treated as `~/.ssh/<path>`.
    private func resolveIdentityFilePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        if expanded.hasPrefix("/") { return expanded }
        return NSHomeDirectory() + "/.ssh/" + expanded
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = NSHomeDirectory()
        if path == "~" { return home }
        return home + path.dropFirst()
    }

    // MARK: - Include Directive

    /// Processes an `Include` directive by glob-expanding `pattern` and
    /// recursively parsing each matching path.
    ///
    /// Supports `~`, shell globs (`*`, `?`, `[abc]`, `{a,b}`), and relative
    /// paths (resolved from `~/.ssh/`).
    private func processInclude(_ pattern: String, into hosts: inout [HostDefinition]) {
        let expanded = expandTilde(pattern)

        // Resolve relative patterns from ~/.ssh/
        let searchPath: String
        if expanded.hasPrefix("/") {
            searchPath = expanded
        } else {
            searchPath = NSHomeDirectory() + "/.ssh/" + expanded
        }

        var gl = glob_t()
        defer { globfree(&gl) }

        let flags = GLOB_TILDE | GLOB_BRACE | GLOB_NOCHECK
        let rc = glob(searchPath, flags, nil, &gl)
        guard rc == 0 else { return }

        let standardConfig = NSHomeDirectory() + "/.ssh/config"

        for i in 0..<Int(gl.gl_matchc) {
            guard let cPath = gl.gl_pathv[i] else { continue }
            let path = String(cString: cPath)
            guard path != standardConfig else { continue }  // avoid trivial recursion

            let subHosts = parse(path: path)
            hosts.append(contentsOf: subHosts)
        }
    }
}
