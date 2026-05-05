import Foundation
import AIProvider
import TerminalCore

/// Convenience wrapper around ``AssistantService`` that reviews shell commands
/// for safety. Includes a static categoriser that classifies commands by their
/// base command name, and optionally enriches the AI review with this
/// pre-classification.
public struct RiskReviewer {
    private let service: AssistantService

    public init(service: AssistantService) {
        self.service = service
    }

    /// Review a shell command and return a structured risk assessment.
    ///
    /// The assessment combines a static keyword-based pre-classification with
    /// the AI's deeper analysis.
    ///
    /// - Parameters:
    ///   - command: The shell command to review.
    ///   - providerId: Registered provider to use.
    ///   - modelId: Registered model to use.
    /// - Returns: A ``RiskAssessment`` with risk level, explanation, and
    ///   optional safer alternative.
    public func review(
        command: String,
        providerId: UUID,
        modelId: UUID
    ) async throws -> RiskAssessment {
        // Pre-classify so we can supply it as extra context to the AI.
        let staticLevel = Self.categorizeCommand(command)

        // For trivially safe commands we can skip the network round-trip
        // when the static analysis is definitive.
        if staticLevel == .safe && Self.isTriviallySafe(command) {
            return RiskAssessment(
                riskLevel: .safe,
                explanation: "This command is a read-only information command and poses no risk.",
                warnings: [],
                saferAlternative: nil
            )
        }

        // Enrich the AI request with our pre-classification so it has a hint.
        let enrichedCommand = """
        [Pre-classification: \(staticLevel.rawValue)]
        Command:
        \(command)
        """

        return try await service.reviewRisk(enrichedCommand, providerId: providerId, modelId: modelId)
    }

    // MARK: - Static Classification

    /// Statically classify a command's risk level based on its base command name.
    ///
    /// - Parameter command: The full shell command string.
    /// - Returns: The estimated ``RiskLevel``.
    public static func categorizeCommand(_ command: String) -> RiskLevel {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let firstWord = trimmed.split(whereSeparator: \.isWhitespace).first?
            .trimmingCharacters(in: .punctuationCharacters)
        else {
            return .safe
        }

        let base = firstWord.lowercased()

        // Dangerous — data destruction or system corruption
        if Self.dangerousCommands.contains(base) {
            return .dangerous
        }

        // Moderate — affects system state but is recoverable
        if Self.moderateCommands.contains(base) {
            return .moderate
        }

        // Safe — everything else defaults to safe
        return .safe
    }

    /// Returns `true` for commands that are unambiguously safe (read-only info).
    public static func isTriviallySafe(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let firstWord = trimmed.split(whereSeparator: \.isWhitespace).first?
            .trimmingCharacters(in: .punctuationCharacters)
        else {
            return false
        }
        return Self.safeCommands.contains(firstWord.lowercased())
    }

    // MARK: - Command Lists

    /// Commands that can cause data loss or system damage.
    private static let dangerousCommands: Set<String> = [
        "rm", "dd", "mkfs", "mke2fs", "mkfs.ext4", "mkfs.ext3", "mkfs.ext2",
        "mkfs.xfs", "mkfs.btrfs", "fdisk", "parted", "gdisk",
        "format", "newfs", "zfs", "zpool",
        "drop", "truncate", "shred", "wipefs", "blkdiscard",
        "pvcreate", "vgcreate", "lvcreate", "pvremove", "vgremove", "lvremove",
        "mkswap", "swapoff",
        "flashrom", "ddrescue",
    ]

    /// Commands that affect system state (services, processes, permissions).
    private static let moderateCommands: Set<String> = [
        "systemctl", "journalctl", "service",
        "kill", "killall", "pkill", "pgrep",
        "reboot", "shutdown", "poweroff", "halt", "init",
        "chmod", "chown", "chgrp",
        "sudo", "su", "doas",
        "passwd", "chpasswd", "usermod", "groupmod",
        "mount", "umount",
        "ifconfig", "ip", "iwconfig", "route", "iptables", "ufw",
        "apt", "apt-get", "aptitude", "dpkg", "rpm", "yum", "dnf", "pacman",
        "brew", "port",
        "pip", "pip3", "gem", "npm", "cargo",
        "touch", "mkdir", "cp", "mv", "ln", "link", "unlink",
        "tee", "dd",  // dd already in dangerous, but keep here as sub-categorisation
        "crontab", "at", "batch",
    ]

    /// Commands that are purely informational / read-only.
    private static let safeCommands: Set<String> = [
        "ls", "cat", "less", "more", "head", "tail",
        "grep", "egrep", "fgrep", "rg", "ag", "ack",
        "find", "locate", "mlocate",
        "echo", "printf",
        "cd", "pwd", "pushd", "popd", "dirs",
        "whoami", "id", "who", "w", "users", "groups",
        "date", "cal", "time",
        "man", "info", "help", "whatis", "apropos",
        "which", "whereis", "type",
        "wc", "sort", "uniq", "cut", "tr", "fold", "fmt",
        "diff", "cmp", "comm", "patch",
        "env", "printenv", "export",
        "history", "fc",
        "alias", "unalias",
        "type", "file",
        "du", "df", "stat",
        "ps", "top", "htop", "btop",
        "uname", "hostname", "arch", "uptime",
        "lsof", "netstat", "ss",
        "dig", "nslookup", "host", "ping", "traceroute", "mtr",
        "curl", "wget", "httpie",
        "git", "hg", "svn",
        "tree", "exa", "eza", "lsd",
        "jq", "yq",
        "xargs", "parallel",
        "yes", "true", "false",
        "nano", "vim", "vi", "emacs", "nvim", "code",
        "screen", "tmux",
        "bc", "dc",
        "seq", "shuf",
        "od", "hexdump", "xxd",
        "base64", "md5", "md5sum", "sha1sum", "sha256sum",
        "watch",
        "open",
        "mdfind", "mdls",
    ]
}
