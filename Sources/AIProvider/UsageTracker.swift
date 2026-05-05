import Foundation

/// Thread-safe usage tracker that persists API cost data as an append-only
/// CSV log on disk.
///
/// CSV location: `~/Library/Application Support/TerminalApp/usage_log.csv`
///
/// Columns:
///   `id,providerId,modelId,timestamp,inputTokens,outputTokens,estimatedCost,context`
public final class UsageTracker: @unchecked Sendable {
    public static let shared = UsageTracker()

    // MARK: - Properties

    private var records: [UsageRecord] = []
    private let lock = NSLock()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - File URL

    private var csvURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TerminalApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        return appDir.appendingPathComponent("usage_log.csv")
    }

    // MARK: - Init

    public init() {
        loadFromCSV()
    }

    // MARK: - Record

    /// Create and persist a usage record from its individual components.
    /// - Parameters:
    ///   - providerId:    The provider that handled the request.
    ///   - modelId:       The model that was invoked.
    ///   - inputTokens:   Prompt / input tokens consumed.
    ///   - outputTokens:  Completion / output tokens generated.
    ///   - estimatedCost: Pre-calculated monetary cost for this request.
    ///   - context:       Origin context (assistant / agent / skill).
    public func record(
        providerId: UUID,
        modelId: UUID,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCost: Decimal,
        context: UsageContext
    ) {
        let record = UsageRecord(
            providerId: providerId,
            modelId: modelId,
            timestamp: Date(),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCost,
            context: context
        )

        lock.lock()
        records.append(record)
        lock.unlock()

        appendToCSV(record)
    }

    /// Append a pre-built `UsageRecord` to the log.
    /// - Parameter record: The record to persist.
    public func record(_ record: UsageRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()

        appendToCSV(record)
    }

    /// All records currently held in memory, deserialized from the CSV log.
    public var allRecords: [UsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    // MARK: - Summaries

    /// Total estimated cost for today (local time).
    public func summaryToday() -> Decimal {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return sumCosts(from: startOfDay, to: Date())
    }

    /// Total estimated cost for the current calendar month.
    public func summaryThisMonth() -> Decimal {
        let now = Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        guard let startOfMonth = Calendar.current.date(from: comps) else { return 0 }
        return sumCosts(from: startOfMonth, to: now)
    }

    /// Cost broken down by provider.
    /// - Returns: An array of `(providerId, cost)` tuples.
    public func summaryByProvider() -> [(providerId: UUID, cost: Decimal)] {
        let snapshot = allRecords
        var costs: [UUID: Decimal] = [:]
        for record in snapshot {
            costs[record.providerId, default: 0] += record.estimatedCost
        }
        return costs.map { ($0.key, $0.value) }
    }

    // MARK: - Private

    private func sumCosts(from start: Date, to end: Date) -> Decimal {
        let snapshot = allRecords
        return snapshot
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .reduce(0) { $0 + $1.estimatedCost }
    }

    // MARK: - CSV Persistence

    private func loadFromCSV() {
        let url = csvURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            guard lines.count > 1 else { return }

            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var loaded: [UsageRecord] = []
            for line in lines.dropFirst() { // skip header
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let record = parseCSVLine(trimmed, dateFormatter: df) else {
                    continue
                }
                loaded.append(record)
            }

            lock.lock()
            records = loaded
            lock.unlock()
        } catch {
            print("UsageTracker: Failed to read CSV – \(error.localizedDescription)")
        }
    }

    private func appendToCSV(_ record: UsageRecord) {
        let timestamp = isoFormatter.string(from: record.timestamp)
        let contextStr = encodeContextForCSV(record.context)
        let costStr = "\(record.estimatedCost)"

        let line = [
            record.id.uuidString,
            record.providerId.uuidString,
            record.modelId.uuidString,
            timestamp,
            String(record.inputTokens),
            String(record.outputTokens),
            costStr,
            contextStr
        ].joined(separator: ",")

        let url = csvURL
        let header = "id,providerId,modelId,timestamp,inputTokens,outputTokens,estimatedCost,context"

        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("UsageTracker: Failed to write CSV header – \(error.localizedDescription)")
                return
            }
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            guard let data = (line + "\n").data(using: .utf8) else { return }
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            print("UsageTracker: Failed to append to CSV – \(error.localizedDescription)")
        }
    }

    // MARK: - CSV Encoding / Decoding

    private func encodeContextForCSV(_ context: UsageContext) -> String {
        switch context {
        case .assistant:
            return "assistant"
        case .agent(let taskId):
            return "agent:\(taskId.uuidString)"
        case .skill(let skillId):
            return "skill:\(skillId.uuidString)"
        }
    }

    private func decodeContextFromCSV(_ string: String) -> UsageContext? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed == "assistant" {
            return .assistant
        }
        if trimmed.hasPrefix("agent:"), let uuid = UUID(uuidString: String(trimmed.dropFirst(6))) {
            return .agent(taskId: uuid)
        }
        if trimmed.hasPrefix("skill:"), let uuid = UUID(uuidString: String(trimmed.dropFirst(6))) {
            return .skill(skillId: uuid)
        }
        return nil
    }

    private func parseCSVLine(_ line: String, dateFormatter: ISO8601DateFormatter) -> UsageRecord? {
        let columns = line.components(separatedBy: ",")
        guard columns.count >= 8 else { return nil }

        guard let id = UUID(uuidString: columns[0]),
              let providerId = UUID(uuidString: columns[1]),
              let modelId = UUID(uuidString: columns[2]),
              let timestamp = dateFormatter.date(from: columns[3]),
              let inputTokens = Int(columns[4]),
              let outputTokens = Int(columns[5]),
              let estimatedCost = Decimal(string: columns[6]),
              let context = decodeContextFromCSV(columns[7]) else {
            return nil
        }

        return UsageRecord(
            id: id,
            providerId: providerId,
            modelId: modelId,
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCost,
            context: context
        )
    }
}
