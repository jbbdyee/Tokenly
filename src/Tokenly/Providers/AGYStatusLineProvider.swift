import Foundation

struct AGYStatusLineProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    let fileURL: URL
    let now: () -> Date

    init(fileURL: URL = Self.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tokenly/agy-quota.json")
    }

    var hasFeed: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    func fetch() async throws -> ExternalUsageSnapshot {
        guard hasFeed else { throw ExternalProviderError.setupRequired }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw ExternalProviderError.connection }
        return try AGYQuotaParser.parse(data, now: now())
    }

    func storedQuotaRecord() -> [QuotaMetric]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return AGYQuotaParser.storedRecord(data)
    }
}

enum AGYQuotaParser {
    static func parse(_ data: Data, now: Date, maxAge: TimeInterval = 900) throws -> ExternalUsageSnapshot {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw ExternalProviderError.invalidResponse }
        guard let captured = ISO8601DateFormatter().date(from: payload.capturedAt),
              captured <= now.addingTimeInterval(60),
              now.timeIntervalSince(captured) <= maxAge else { throw ExternalProviderError.staleData }
        let quotas = payload.quota.compactMap { name, value -> QuotaMetric? in
            guard let fraction = value.remainingFraction, fraction.isFinite,
                  (0...1).contains(fraction) else { return nil }
            let reset = value.resetTime.flatMap { ISO8601DateFormatter().date(from: $0) }
            return QuotaMetric(name: name, remainingPercent: fraction * 100, resetsAt: reset)
        }.sorted { $0.name < $1.name }
        guard !quotas.isEmpty else { throw ExternalProviderError.noData }
        return ExternalUsageSnapshot(metrics: .quotas(quotas), fetchedAt: captured)
    }

    /// Valid buckets in a received file regardless of age, used only as "previously received" evidence.
    static func storedRecord(_ data: Data) -> [QuotaMetric]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              ISO8601DateFormatter().date(from: payload.capturedAt) != nil else { return nil }
        let quotas = payload.quota.compactMap { name, value -> QuotaMetric? in
            guard let fraction = value.remainingFraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
            return QuotaMetric(name: name, remainingPercent: fraction * 100, resetsAt: nil)
        }.sorted { $0.name < $1.name }
        return quotas.isEmpty ? nil : quotas
    }

    private struct Payload: Decodable {
        let capturedAt: String
        let quota: [String: Value]
        enum CodingKeys: String, CodingKey { case capturedAt = "captured_at", quota }
    }
    private struct Value: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        enum CodingKeys: String, CodingKey { case remainingFraction = "remaining_fraction", resetTime = "reset_time" }
    }
}
