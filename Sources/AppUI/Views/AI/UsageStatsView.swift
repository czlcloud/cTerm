import SwiftUI
import AIProvider
import SessionManager

struct UsageStatsView: View {
    @EnvironmentObject var aiRegistry: AIProviderRegistry

    @State private var todayCost: Decimal = 0
    @State private var monthCost: Decimal = 0
    @State private var byProvider: [(String, Decimal)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Usage")
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            // Summary cards
            HStack(spacing: 16) {
                UsageCard(title: "Today", amount: todayCost, color: .blue)
                UsageCard(title: "This Month", amount: monthCost, color: .green)
            }

            Divider()

            // By provider
            Text("By Provider").font(.headline)

            if byProvider.isEmpty {
                Text("No usage data yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(byProvider, id: \.0) { provider, cost in
                    HStack {
                        Text(provider)
                        Spacer()
                        Text(cost, format: .currency(code: "USD"))
                            .fontWeight(.medium)
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer()

            // Recent records
            if !aiRegistry.usageRecords.isEmpty {
                Text("Recent Requests").font(.headline)
                ScrollView {
                    ForEach(aiRegistry.usageRecords.prefix(20)) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(contextLabel(for: record.context))
                                    .font(.caption)
                                Text(record.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(record.inputTokens + record.outputTokens) tokens")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding()
        .onAppear { loadSummaries() }
    }

    private func loadSummaries() {
        let tracker = UsageTracker()
        todayCost = tracker.summaryToday()
        monthCost = tracker.summaryThisMonth()
        byProvider = tracker.summaryByProvider().map { (providerId, cost) in
            let name = aiRegistry.providers.first { $0.id == providerId }?.name ?? "Unknown"
            return (name, cost)
        }
    }

    private func contextLabel(for context: UsageContext) -> String {
        switch context {
        case .assistant: return "Assistant"
        case .agent: return "Agent"
        case .skill: return "Skill"
        }
    }
}

struct UsageCard: View {
    let title: String
    let amount: Decimal
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(amount, format: .currency(code: "USD"))
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
