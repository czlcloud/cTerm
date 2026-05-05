import Foundation

// MARK: - ApprovalFlow

/// Evaluates shell commands for risk and determines whether human approval is
/// required before execution.
///
/// The flow uses a fast client-side heuristic (pattern matching) as a first
/// pass. The risk level returned by the AI planner is also respected — the
/// two signals are combined to produce an ``ApprovalRequirement``.
public final class ApprovalFlow {

    public init() {}

    /// Performs a fast client-side risk assessment of a shell command by
    /// matching against known dangerous / moderate / safe patterns.
    ///
    /// - Parameter command: The raw shell command string.
    /// - Returns: The heuristic risk level.
    public func evaluateRisk(command: String) -> RiskLevel {
        let lower = command.lowercased().trimmingCharacters(in: .whitespaces)

        // ------ Dangerous patterns (destructive / irreversible) ------
        let dangerousPrefixes = [
            "rm -rf", "rm -fr", "rm --recursive",
            "dd if=",
            "mkfs.", "mkswap",
            "chmod 777 /", "chmod -r 777 /", "chown -r /",
            "shutdown", "reboot", "halt", "poweroff",
            "iptables -f", "ufw reset", "pfctl -f",
            ":(){ :|:& };:",
            "mv / ", "cp / ", "mv /* ", "cp /* ",
            "sudo rm -rf", "sudo dd", "sudo mkfs",
        ]

        for prefix in dangerousPrefixes {
            if lower.hasPrefix(prefix) {
                return .dangerous
            }
        }

        // Check for "rm -rf" anywhere in the command (e.g. after sudo, &&, etc.)
        if lower.contains("rm -rf") || lower.contains("rm -fr") {
            return .dangerous
        }

        // ------ Moderate patterns (service mgmt, package mgmt, mutations) ------
        let moderatePrefixes = [
            "systemctl", "service ", "launchctl",
            "apt ", "apt-get", "yum ", "dnf ", "brew ", "port ",
            "pip ", "pip3", "gem ", "npm ", "yarn ",
            "chmod", "chown",
            "kill ", "killall",
            "sed -i", "sed -ie",
            "useradd", "usermod", "userdel", "passwd",
            "groupadd", "groupmod", "groupdel",
            "ln -sf", "ln -s",
            "mount", "umount",
            "ifconfig", "ip addr", "ip link",
            "ufw ", "iptables", "pfctl",
            "docker ", "podman ",
            "git push", "git merge", "git rebase", "git commit",
            "mysql", "psql", "redis-cli", "mongosh",
            "export ", "source ",
            "cat > ", "cat >>", "echo > ", "echo >>",
            "tee ", "dd if=",
            "sudo ", "su ",
            "curl ", "wget ",
            "tar -x", "unzip ", "gunzip ",
        ]

        for prefix in moderatePrefixes {
            if lower.hasPrefix(prefix) || lower.contains(" " + prefix) {
                return .moderate
            }
        }

        // ------ Safe patterns (read-only / informational) ------
        let safePrefixes = [
            "ls", "cd", "pwd", "echo",
            "cat ", "head ", "tail ", "less ", "more ",
            "grep", "awk", "sed ", "sort", "uniq", "wc", "cut", "tr",
            "find ", "locate", "which", "whereis",
            "date", "cal", "whoami", "id", "who", "w", "uptime",
            "ps ", "top ", "htop", "df ", "du ", "free",
            "uname", "hostname", "env", "printenv",
            "ping", "traceroute", "nslookup", "dig", "host",
            "netstat", "ss ", "lsof",
            "git status", "git log", "git diff", "git branch ",
            "file ", "stat ", "type ",
            "man ", "info ", "whatis", "apropos",
            "history", "alias",
        ]

        for prefix in safePrefixes {
            if lower == prefix || lower.hasPrefix(prefix + " ") || lower.hasPrefix(prefix + "\t") {
                return .safe
            }
        }

        // Default: moderate for unknown commands
        return .moderate
    }

    /// Determines what kind of approval is needed for a planned step.
    ///
    /// The method considers both the risk level assigned by the AI planner and
    /// the client-side heuristic.
    ///
    /// - Parameter step: The step produced by the planner.
    /// - Returns: The approval requirement.
    public func requiresApproval(step: PlannedStep) -> ApprovalRequirement {
        switch step.riskLevel {
        case .safe:
            // Double-check with the heuristic.
            let heuristic = evaluateRisk(command: step.command)
            if heuristic == .safe {
                return .autoApprove
            }
            // Heuristic disagrees — escalate to confirm.
            return .confirm

        case .moderate:
            return .confirm

        case .dangerous:
            return .confirmWithYES
        }
    }

    /// Validates an approval attempt against the command and its stated risk
    /// level. This is primarily used when the caller already knows the risk
    /// level (e.g., from a stored approval record) and wants to know what form
    /// of confirmation is required.
    ///
    /// - Parameters:
    ///   - command: The shell command string.
    ///   - riskLevel: The risk level of the command.
    /// - Returns: The approval requirement.
    public func validateApproval(command: String, riskLevel: RiskLevel) -> ApprovalRequirement {
        switch riskLevel {
        case .safe:
            return .autoApprove
        case .moderate:
            return .confirm
        case .dangerous:
            return .confirmWithYES
        }
    }
}
