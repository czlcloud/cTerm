import SwiftUI
import AIAgent

struct AgentApprovalPopup: View {
    let approval: ApprovalRecord
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var confirmText = ""

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: riskIcon)
                    .font(.title)
                    .foregroundColor(riskColor)
                VStack(alignment: .leading) {
                    Text("Agent Approval Required")
                        .font(.headline)
                    Text("Step \(approval.stepIndex + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Command
            VStack(alignment: .leading, spacing: 8) {
                Text("Command to execute:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(approval.command)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Reasoning
            VStack(alignment: .leading, spacing: 8) {
                Text("AI Reasoning:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(approval.reasoning)
                    .font(.body)
            }

            // Risk badge
            HStack {
                Text("Risk Level:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(approval.riskLevel.rawValue.uppercased())
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(riskColor.opacity(0.2))
                    .foregroundColor(riskColor)
                    .clipShape(Capsule())
            }

            // Explicit confirmation for dangerous operations
            if approval.riskLevel == .dangerous {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This is a DANGEROUS operation. Type YES to confirm:")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fontWeight(.bold)
                    TextField("YES", text: $confirmText)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                Button(role: .destructive, action: onReject) {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(approval.riskLevel == .dangerous && confirmText != "YES")
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var riskIcon: String {
        switch approval.riskLevel {
        case .safe: "checkmark.shield"
        case .moderate: "exclamationmark.shield"
        case .dangerous: "xmark.shield"
        }
    }

    private var riskColor: Color {
        switch approval.riskLevel {
        case .safe: .green
        case .moderate: .orange
        case .dangerous: .red
        }
    }
}
