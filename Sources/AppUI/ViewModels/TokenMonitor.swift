import Foundation

/// Tracks token usage for a Claude Code session by parsing its JSONL session file.
/// Falls back to time-based estimates until real data is available.
@MainActor
public final class TokenMonitor: ObservableObject {
    @Published public var tokenUsage = TokenUsage()

    private let sessionId: UUID
    private let model: String
    private let startTime: Date
    private let basePricePer1MInput: Decimal
    private let basePricePer1MOutput: Decimal
    private var pollingTask: Task<Void, Never>?

    /// Tokens-per-minute estimate by model tier.
    private var estimatedTokensPerMinute: Int {
        switch model {
        case "opus": return 1500
        case "haiku": return 4000
        default: return 2000  // sonnet
        }
    }

    public init(sessionId: UUID, model: String) {
        self.sessionId = sessionId
        self.model = model
        self.startTime = Date()
        switch model {
        case "opus":
            self.basePricePer1MInput = 15; self.basePricePer1MOutput = 75
        case "haiku":
            self.basePricePer1MInput = 0.80; self.basePricePer1MOutput = 4
        default: // sonnet
            self.basePricePer1MInput = 3; self.basePricePer1MOutput = 15
        }
        updateEstimate()
        startPolling()
    }

    deinit { pollingTask?.cancel() }

    // MARK: - Coarse Estimate

    private func updateEstimate() {
        let elapsed = max(Date().timeIntervalSince(startTime), 1)
        let minutes = elapsed / 60
        let estimatedTotal = Int(Double(estimatedTokensPerMinute) * minutes)
        // Rough 3:1 input:output ratio
        let estimatedInput = Int(Double(estimatedTotal) * 0.75)
        let estimatedOutput = estimatedTotal - estimatedInput
        let inputCost = Decimal(estimatedInput) / 1_000_000 * basePricePer1MInput
        let outputCost = Decimal(estimatedOutput) / 1_000_000 * basePricePer1MOutput
        tokenUsage = TokenUsage(
            inputTokens: estimatedInput,
            outputTokens: estimatedOutput,
            isEstimated: true,
            estimatedCost: inputCost + outputCost,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Real Data Polling

    private func startPolling() {
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                if let real = await self.parseSessionJSONL() {
                    await MainActor.run {
                        self.tokenUsage = TokenUsage(
                            inputTokens: real.inputTokens,
                            outputTokens: real.outputTokens,
                            cacheReadTokens: real.cacheReadTokens,
                            isEstimated: false,
                            estimatedCost: real.estimatedCost,
                            elapsedSeconds: Date().timeIntervalSince(self.startTime)
                        )
                    }
                } else {
                    // No file yet — refresh estimate
                    await MainActor.run { self.updateEstimate() }
                }
            }
        }
    }

    private func parseSessionJSONL() async -> TokenUsage? {
        let projectPath = sessionProjectPath()
        let jsonlPath = projectPath + "/" + sessionId.uuidString + ".jsonl"
        guard FileManager.default.fileExists(atPath: jsonlPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath)),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var inputTotal = 0, outputTotal = 0, cacheReadTotal = 0
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let json = try? JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any],
                  let usage = json["usage"] as? [String: Any] else { continue }
            inputTotal += usage["input_tokens"] as? Int ?? 0
            outputTotal += usage["output_tokens"] as? Int ?? 0
            cacheReadTotal += usage["cache_read_input_tokens"] as? Int ?? 0
        }

        let inputCost = Decimal(inputTotal) / 1_000_000 * basePricePer1MInput
        let outputCost = Decimal(outputTotal) / 1_000_000 * basePricePer1MOutput
        return TokenUsage(
            inputTokens: inputTotal,
            outputTokens: outputTotal,
            cacheReadTokens: cacheReadTotal,
            isEstimated: false,
            estimatedCost: inputCost + outputCost,
            elapsedSeconds: Date().timeIntervalSince(startTime)
        )
    }

    /// Derive the Claude project path from the current working directory.
    private func sessionProjectPath() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let home = NSHomeDirectory()
        return home + "/.claude/projects/" + encoded
    }

    public func stop() { pollingTask?.cancel() }
}

// MARK: - TokenUsage Model

public struct TokenUsage {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var isEstimated: Bool = true
    public var estimatedCost: Decimal = 0
    public var elapsedSeconds: TimeInterval = 0

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens }

    public var formattedTokens: String {
        let prefix = isEstimated ? "~" : ""
        if totalTokens >= 1_000_000 {
            return prefix + String(format: "%.1fM tok", Double(totalTokens) / 1_000_000)
        } else if totalTokens >= 1_000 {
            return prefix + String(format: "%.1fK tok", Double(totalTokens) / 1_000)
        }
        return prefix + "\(totalTokens) tok"
    }

    public var formattedCost: String {
        let prefix = isEstimated ? "~" : ""
        if estimatedCost >= 1 {
            return prefix + "$" + String(format: "%.2f", Double(truncating: estimatedCost as NSNumber))
        } else {
            return prefix + "$" + String(format: "%.4f", Double(truncating: estimatedCost as NSNumber))
        }
    }

    public var formattedElapsed: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
