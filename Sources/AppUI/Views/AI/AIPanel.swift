import SwiftUI
import AIProvider

// MARK: - AI Configuration Panel

struct AIPanel: View {
    @EnvironmentObject var aiRegistry: AIProviderRegistry
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var showProviderSettings = false
    @State private var settingsJSON: String = ""
    @State private var jsonError: String?
    @State private var jsonSaved: Bool = false
    @State private var cursorDetected: Bool = false
    @State private var stats: ClaudeStats?
    @State private var balanceInfo: BalanceInfo?
    @State private var balanceError: String?

    private var claudeSettingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }
    private var statsPath: String { NSHomeDirectory() + "/.claude/stats-cache.json" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI").font(.title).fontWeight(.bold)

                // MARK: - Usage Summary
                if let s = stats {
                    GroupBox(label: Label("Usage", systemImage: "chart.bar")) {
                        VStack(alignment: .leading, spacing: 12) {
                            // Balance bar
                            if let bal = balanceInfo, let info = bal.balanceInfos.first {
                                HStack(spacing: 6) {
                                    Image(systemName: "dollarsign.circle.fill").foregroundColor(.green)
                                    Text("Balance").font(.caption).foregroundColor(.secondary)
                                    Text("\(info.currency) \(info.totalBalance)")
                                        .font(.caption).fontWeight(.bold).foregroundColor(.green)
                                    Spacer()
                                    if let err = balanceError { Text(err).font(.caption2).foregroundColor(.red) }
                                }
                            } else if balanceError == nil {
                                HStack { ProgressView().scaleEffect(0.5); Text("Fetching balance...").font(.caption2).foregroundColor(.secondary); Spacer() }
                            }

                            // Summary cards
                            HStack(spacing: 16) {
                                QuickStatCard(title: "Total Tokens", value: formatTokens(totalTokens(s)), color: .blue)
                                QuickStatCard(title: "Est. Cost", value: "$\(String(format: "%.2f", estimatedCost(s)))", color: .green)
                                QuickStatCard(title: "Sessions", value: "\(s.totalSessions)", color: .orange)
                                QuickStatCard(title: "Messages", value: "\(s.totalMessages)", color: .purple)
                            }

                            Divider()

                            // Model breakdown
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model Breakdown").font(.caption).fontWeight(.medium)
                                let totalAll = s.modelUsage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
                                ForEach(s.modelUsage.sorted(by: { $0.value.totalTokens > $1.value.totalTokens }), id: \.key) { model, usage in
                                    let modelTotal = usage.totalTokens
                                    let pct = totalAll > 0 ? Double(modelTotal) / Double(totalAll) : 0
                                    VStack(spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(shortModelName(model)).font(.caption2).frame(width: 80, alignment: .trailing)
                                            GeometryReader { geo in
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color.accentColor.opacity(0.5))
                                                    .frame(width: max(CGFloat(pct) * geo.size.width, 2))
                                            }.frame(height: 10)
                                            Text(formatTokens(modelTotal)).font(.caption2).frame(width: 55, alignment: .trailing)
                                            Text("\(Int(pct * 100))%").font(.caption2).foregroundColor(.secondary).frame(width: 32, alignment: .trailing)
                                        }
                                        HStack(spacing: 6) {
                                            Text("").frame(width: 80) // spacer
                                            Text("in: \(formatTokens(usage.inputTokens))  out: \(formatTokens(usage.outputTokens))  cache: \(formatTokens(usage.cacheReadInputTokens))")
                                                .font(.caption2).foregroundColor(.secondary)
                                            Spacer()
                                        }
                                    }
                                }
                            }

                            Divider()

                            // Daily table
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Daily").font(.caption).fontWeight(.medium)
                                // Header
                                HStack(spacing: 4) {
                                    Text("Date").font(.caption2).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
                                    Text("Msgs").font(.caption2).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
                                    Text("Sessions").font(.caption2).foregroundColor(.secondary).frame(width: 50, alignment: .trailing)
                                    Text("Tokens").font(.caption2).foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                                    Text("Est. Cost").font(.caption2).foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                                    Spacer()
                                }
                                Divider()
                                ForEach(mergedDaily(s).reversed().prefix(7), id: \.date) { day in
                                    HStack(spacing: 4) {
                                        Text(shortDate(day.date)).font(.caption2).frame(width: 72, alignment: .leading)
                                        Text("\(day.messageCount)").font(.caption2).frame(width: 40, alignment: .trailing)
                                        Text("\(day.sessionCount)").font(.caption2).frame(width: 50, alignment: .trailing)
                                        Text(formatTokens(day.totalTokens)).font(.caption2).frame(width: 60, alignment: .trailing)
                                        Text("$\(String(format: "%.2f", dayEstimatedCost(day)))").font(.caption2).frame(width: 60, alignment: .trailing)
                                        Spacer()
                                    }
                                }
                            }

                            HStack {
                                Text("Last updated: \(s.lastComputedDate)")
                                    .font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                Button("Refresh") { loadStats() }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }.padding(.vertical, 4)
                    }
                } else {
                    GroupBox(label: Label("Usage", systemImage: "chart.bar")) {
                        HStack {
                            Text("No stats yet. Run Claude Code to generate data.")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Load") { loadStats() }.buttonStyle(.bordered).controlSize(.small)
                        }.padding(.vertical, 4)
                    }
                }

                // MARK: - Claude Code settings.json
                GroupBox(label: Label("Claude Code", systemImage: "sparkles")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(claudeSettingsPath).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                            Button("Load") { loadSettingsJSON() }.buttonStyle(.bordered).controlSize(.small)
                            Button("Save") { saveSettingsJSON() }.buttonStyle(.bordered).controlSize(.small)
                                .disabled(settingsJSON.isEmpty)
                        }
                        if let err = jsonError { Text(err).font(.caption2).foregroundColor(.red) }
                        if jsonSaved { Text("Saved ✓").font(.caption2).foregroundColor(.green) }
                        TextEditor(text: $settingsJSON)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                            .onChange(of: settingsJSON) { _ in jsonSaved = false; jsonError = nil }
                    }.padding(.vertical, 4)
                }

                // MARK: - Cursor
                GroupBox(label: Label("Cursor IDE", systemImage: "cursorarrow.and.square.on.square.dashed")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: cursorDetected ? "checkmark.circle.fill" : "questionmark.circle")
                                .foregroundColor(cursorDetected ? .green : .secondary)
                            Text(cursorDetected ? "Cursor detected" : "Cursor not detected").font(.caption)
                            Spacer()
                            Button("Detect") { detectCursor() }.buttonStyle(.bordered).controlSize(.small)
                        }
                        Text("Cursor AI IDE integration — sync Claude settings and detect projects.")
                            .font(.caption2).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                }

                Spacer()
            }.padding()
        }
        .sheet(isPresented: $showProviderSettings) { AIProviderSettings() }
        .onAppear { loadSettingsJSON(); loadStats(); detectCursor() }
        .task { await fetchBalance() }
    }

    // MARK: - Stats helpers

    private func totalTokens(_ s: ClaudeStats) -> Int {
        s.modelUsage.values.reduce(0) { $0 + $1.totalTokens }
    }

    private func estimatedCost(_ s: ClaudeStats) -> Double {
        s.modelUsage.reduce(0) { total, entry in
            total + modelCost(model: entry.key, usage: entry.value)
        }
    }

    private func modelCost(model: String, usage: ModelUsageStats) -> Double {
        let (inputPrice, outputPrice): (Double, Double) = model.lowercased().contains("flash")
            ? (0.14, 0.55) : (0.28, 1.10) // DeepSeek pricing per 1M
        let input = Double(usage.inputTokens + usage.cacheReadInputTokens) / 1_000_000 * inputPrice
        let output = Double(usage.outputTokens) / 1_000_000 * outputPrice
        return input + output
    }

    private func dayEstimatedCost(_ day: MergedDaily) -> Double {
        var cost = 0.0
        for (model, tokens) in day.tokensByModel {
            let rate = model.lowercased().contains("flash") ? (0.14, 0.55) : (0.28, 1.10)
            cost += Double(tokens) / 1_000_000 * rate.0 // rough: treat all as input
        }
        return cost
    }

    private func formatTokens(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t)/1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK", Double(t)/1_000) }
        return "\(t)"
    }

    private func shortModelName(_ m: String) -> String {
        if m.contains("flash") { return "flash" }
        if m.contains("pro") { return "pro" }
        return String(m.prefix(20))
    }

    private func shortDate(_ d: String) -> String {
        // "2026-04-28" → "04/28"
        let parts = d.split(separator: "-")
        guard parts.count >= 3 else { return d }
        return "\(parts[1])/\(parts[2])"
    }

    private struct MergedDaily {
        let date: String; let messageCount: Int; let sessionCount: Int
        let toolCallCount: Int; let totalTokens: Int; let tokensByModel: [String: Int]
    }

    private func mergedDaily(_ s: ClaudeStats) -> [MergedDaily] {
        var result: [MergedDaily] = []
        for act in s.dailyActivity {
            let tokensForDay = s.dailyModelTokens.first(where: { $0.date == act.date })
            let total = tokensForDay?.tokensByModel.values.reduce(0, +) ?? 0
            result.append(MergedDaily(date: act.date, messageCount: act.messageCount,
                sessionCount: act.sessionCount, toolCallCount: act.toolCallCount,
                totalTokens: total, tokensByModel: tokensForDay?.tokensByModel ?? [:]))
        }
        return result
    }

    // MARK: - JSON helpers

    private func loadSettingsJSON() {
        guard FileManager.default.fileExists(atPath: claudeSettingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
              let text = String(data: data, encoding: .utf8) else { settingsJSON = ""; return }
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let prettyStr = String(data: pretty, encoding: .utf8) { settingsJSON = prettyStr } else { settingsJSON = text }
    }

    private func saveSettingsJSON() {
        guard !settingsJSON.isEmpty, let data = settingsJSON.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) else { jsonError = "Invalid JSON."; return }
        do {
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try pretty.write(to: URL(fileURLWithPath: claudeSettingsPath))
            } else { try data.write(to: URL(fileURLWithPath: claudeSettingsPath)) }
            jsonSaved = true; jsonError = nil
        } catch { jsonError = "Save failed: \(error.localizedDescription)" }
    }

    private func loadStats() {
        guard FileManager.default.fileExists(atPath: statsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: statsPath)) else { return }
        stats = try? JSONDecoder().decode(ClaudeStats.self, from: data)
    }

    // MARK: - Balance

    private func fetchBalance() async {
        // Get API key from settings.json
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let key = env["ANTHROPIC_AUTH_TOKEN"] as? String,
              let baseURL = env["ANTHROPIC_BASE_URL"] as? String,
              let url = URL(string: baseURL.replacingOccurrences(of: "/anthropic", with: "")) else {
            balanceError = "No API key in settings.json"
            return
        }
        let balanceURL = url.appendingPathComponent("user/balance")
        var req = URLRequest(url: balanceURL)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (respData, _) = try await URLSession.shared.data(for: req)
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(BalanceInfo.self, from: respData)
            await MainActor.run { balanceInfo = decoded; balanceError = nil }
        } catch {
            await MainActor.run { balanceError = error.localizedDescription }
        }
    }

    private func detectCursor() {
        cursorDetected = [
            NSHomeDirectory() + "/Applications/Cursor.app",
            "/Applications/Cursor.app", NSHomeDirectory() + "/.cursor"
        ].contains { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Stats Models

struct ClaudeStats: Codable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]
    let modelUsage: [String: ModelUsageStats]
    let totalSessions: Int
    let totalMessages: Int
}

struct DailyActivity: Codable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct DailyModelTokens: Codable {
    let date: String
    let tokensByModel: [String: Int]
}

struct ModelUsageStats: Codable {
    let inputTokens: Int; let outputTokens: Int
    let cacheReadInputTokens: Int; let cacheCreationInputTokens: Int
    let webSearchRequests: Int; let costUSD: Double
    let contextWindow: Int; let maxOutputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens + cacheReadInputTokens }
}

// MARK: - Balance Model

struct BalanceInfo: Codable {
    let isAvailable: Bool
    let balanceInfos: [BalanceEntry]
}

struct BalanceEntry: Codable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String?
    let toppedUpBalance: String?
}

// MARK: - Quick Stat Card

struct QuickStatCard: View {
    let title: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.caption).fontWeight(.bold).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Provider Settings Sheet

struct AIProviderSettings: View {
    @EnvironmentObject var aiRegistry: AIProviderRegistry
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My Provider"
    @State private var apiKey = ""
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var providerType: ProviderType = .openAICompatible
    @State private var editingProviderId: UUID?

    private var isEditing: Bool { editingProviderId != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Providers").font(.title2).fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
            }.padding(); Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(isEditing ? "Edit Provider" : "Add Provider").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                if !isEditing {
                    Picker("Provider Type", selection: $providerType) {
                        Text("OpenAI").tag(ProviderType.openAI)
                        Text("Anthropic (Claude)").tag(ProviderType.anthropic)
                        Text("OpenAI Compatible").tag(ProviderType.openAICompatible)
                        Text("Ollama").tag(ProviderType.ollama)
                    }.pickerStyle(.menu)
                } else {
                    HStack { Text("Type:").font(.caption).foregroundColor(.secondary); Text(typeLabel(for: providerType)).font(.caption) }
                }
                TextField(isEditing ? "API Key (leave blank to keep)" : "API Key", text: $apiKey).textFieldStyle(.roundedBorder)
                TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                    .onChange(of: providerType) { newType in
                        guard !isEditing else { return }
                        switch newType {
                        case .openAI, .openAICompatible: baseURL = "https://api.openai.com/v1"
                        case .anthropic: baseURL = "https://api.anthropic.com"
                        case .ollama: baseURL = "http://localhost:11434"
                        case .custom: baseURL = ""
                        }
                    }
                HStack {
                    Button(isEditing ? "Update" : "Add") {
                        if isEditing { updateExistingProvider() } else { addNewProvider() }
                    }.buttonStyle(.borderedProminent).disabled(name.isEmpty || (!isEditing && apiKey.isEmpty))
                    if isEditing { Button("Cancel") { resetForm() }.buttonStyle(.plain) }
                }
            }.padding(); Divider()

            if !aiRegistry.providers.isEmpty {
                List {
                    ForEach(aiRegistry.providers) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.name).font(.body).fontWeight(.medium)
                                HStack(spacing: 4) {
                                    Text(typeLabel(for: p.providerType)).font(.caption2).foregroundColor(.blue)
                                    Text(p.baseURL ?? "").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button(action: { editProvider(p) }) { Image(systemName: "pencil") }.buttonStyle(.plain)
                            Button(action: { aiRegistry.removeProvider(id: p.id) }) { Image(systemName: "trash").foregroundColor(.red) }.buttonStyle(.plain)
                        }.contentShape(Rectangle()).onTapGesture { editProvider(p) }
                    }
                }.listStyle(.inset)
            }
            Spacer()
        }.frame(width: 520, height: 480)
    }

    private func typeLabel(for type: ProviderType) -> String {
        switch type {
        case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .ollama: "Ollama"
        case .openAICompatible: "OpenAI Compatible"; case .custom: "Custom"
        }
    }

    private func defaultModels(for type: ProviderType) -> [AIModel] {
        switch type {
        case .anthropic:
            return [
                AIModel(modelId: "claude-sonnet-4-6", displayName: "Claude Sonnet 4", contextWindow: 200000, maxOutputTokens: 8192, supportsVision: true, supportsToolUse: true),
                AIModel(modelId: "claude-opus-4-7", displayName: "Claude Opus 4", contextWindow: 200000, maxOutputTokens: 8192, supportsVision: true, supportsToolUse: true),
                AIModel(modelId: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", contextWindow: 200000, maxOutputTokens: 8192, supportsVision: true, supportsToolUse: true),
            ]
        case .ollama:
            return [AIModel(modelId: "llama3", displayName: "Llama 3", contextWindow: 8192, maxOutputTokens: 4096, supportsVision: false, supportsToolUse: true)]
        default:
            return [AIModel(modelId: "gpt-4o", displayName: "GPT-4o", contextWindow: 128000, maxOutputTokens: 4096, supportsVision: true, supportsToolUse: true)]
        }
    }

    private func addNewProvider() {
        let models = defaultModels(for: providerType)
        let ref = "ai_key_\(UUID().uuidString.prefix(8))"
        try? CredentialStore.shared.saveString(key: ref, value: apiKey)
        aiRegistry.addProvider(AIProviderConfig(name: name, providerType: providerType, apiKeyRef: ref, baseURL: baseURL, enabledModels: models, defaultModelId: models.first!.id))
        resetForm()
    }

    private func editProvider(_ p: AIProviderConfig) {
        editingProviderId = p.id; name = p.name; providerType = p.providerType; baseURL = p.baseURL ?? ""; apiKey = ""
    }

    private func updateExistingProvider() {
        guard let editingId = editingProviderId, var provider = aiRegistry.getProvider(by: editingId) else { return }
        provider.name = name; provider.baseURL = baseURL
        if !apiKey.isEmpty { try? CredentialStore.shared.saveString(key: provider.apiKeyRef, value: apiKey) }
        aiRegistry.updateProvider(provider)
        resetForm()
    }

    private func resetForm() {
        editingProviderId = nil; name = "My Provider"; apiKey = ""; baseURL = "https://api.openai.com/v1"; providerType = .openAICompatible
    }
}
