import Foundation

struct OpenAIAPIUsageProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .openAIAPI
    private let keys: any AdminKeyStoring
    private let request: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let now: () -> Date

    init(keys: any AdminKeyStoring = KeychainAdminKeyStore(),
         now: @escaping () -> Date = Date.init,
         request: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let response = response as? HTTPURLResponse else { throw ExternalProviderError.connection }
             return (data, response)
         }) {
        self.keys = keys
        self.now = now
        self.request = request
    }

    func fetch() async throws -> ExternalUsageSnapshot {
        guard let key = keys.read(), !key.isEmpty else { throw ExternalProviderError.authenticationRequired }
        guard key.hasPrefix("sk-admin-") else { throw ExternalProviderError.permissionDenied }
        let fetchedAt = now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.startOfDay(for: fetchedAt)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: fetchedAt))!
        let day = try await totals(from: dayStart, to: fetchedAt, key: key)
        let month = try await totals(from: monthStart, to: fetchedAt, key: key)
        return ExternalUsageSnapshot(metrics: .api(day: day, month: month), fetchedAt: fetchedAt)
    }

    private func totals(from start: Date, to end: Date, key: String) async throws -> APITotals {
        let parameters = [URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                          URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
                          URLQueryItem(name: "bucket_width", value: "1d"),
                          URLQueryItem(name: "limit", value: "31")]
        let usage = try await pages(path: "organization/usage/completions", parameters: parameters, key: key)
        let costs = try await pages(path: "organization/costs", parameters: parameters, key: key)
        var input: Int64 = 0
        var output: Int64 = 0
        var usd = 0.0
        do {
            for data in usage {
                let page = try JSONDecoder().decode(CompletionsPage.self, from: data)
                for bucket in page.data {
                    for result in bucket.results {
                        guard result.inputTokens >= 0, result.outputTokens >= 0 else {
                            throw ExternalProviderError.invalidResponse
                        }
                        let nextInput = input.addingReportingOverflow(result.inputTokens)
                        let nextOutput = output.addingReportingOverflow(result.outputTokens)
                        guard !nextInput.overflow, !nextOutput.overflow else {
                            throw ExternalProviderError.invalidResponse
                        }
                        input = nextInput.partialValue
                        output = nextOutput.partialValue
                    }
                }
            }
            for data in costs {
                let page = try JSONDecoder().decode(CostsPage.self, from: data)
                for bucket in page.data {
                    for result in bucket.results {
                        guard let amount = result.amount else { continue }
                        guard amount.currency.lowercased() == "usd", amount.value.isFinite else {
                            throw ExternalProviderError.invalidResponse
                        }
                        usd += amount.value
                    }
                }
            }
        } catch { throw (error as? ExternalProviderError) ?? .invalidResponse }
        return APITotals(inputTokens: input, outputTokens: output, costUSD: usd)
    }

    private func pages(path: String, parameters: [URLQueryItem], key: String) async throws -> [Data] {
        var result: [Data] = []
        var page: String?
        repeat {
            var components = URLComponents(string: "https://api.openai.com/v1/\(path)")!
            components.queryItems = parameters + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var apiRequest = URLRequest(url: components.url!)
            apiRequest.httpMethod = "GET"
            apiRequest.timeoutInterval = 20
            apiRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await request(apiRequest) }
            catch let error as URLError {
                throw error.code == .timedOut ? ExternalProviderError.timeout : .connection
            } catch { throw (error as? ExternalProviderError) ?? .connection }
            switch response.statusCode {
            case 200: break
            case 401: throw ExternalProviderError.authenticationRequired
            case 403: throw ExternalProviderError.permissionDenied
            case 408: throw ExternalProviderError.timeout
            default: throw ExternalProviderError.connection
            }
            guard let cursor = try? JSONDecoder().decode(PageCursor.self, from: data) else {
                throw ExternalProviderError.invalidResponse
            }
            result.append(data)
            guard result.count <= 20 else { throw ExternalProviderError.invalidResponse }
            if cursor.hasMore && (cursor.nextPage == nil || cursor.nextPage == page) {
                throw ExternalProviderError.invalidResponse
            }
            page = cursor.hasMore ? cursor.nextPage : nil
        } while page != nil
        return result
    }
}

private struct PageCursor: Decodable {
    let hasMore: Bool
    let nextPage: String?
    enum CodingKeys: String, CodingKey { case hasMore = "has_more", nextPage = "next_page" }
}

private struct CompletionsPage: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable {
        let inputTokens: Int64
        let outputTokens: Int64
        enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens" }
    }
}

private struct CostsPage: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable { let amount: Amount? }
    struct Amount: Decodable { let value: Double; let currency: String }
}
