import Foundation

public protocol MarketDataProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    func fetch(symbol: String, now: Date) async throws -> MarketSnapshot
}

public protocol HTTPClient: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DataProviderError.invalidResponse("不是 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DataProviderError.httpStatus(http.statusCode)
        }
        return (data, http)
    }
}

public enum DataProviderError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse(String)
    case httpStatus(Int)
    case malformedData(String)
    case staleData(Date)
    case unsupportedSymbol(String)
    case missingAPIKey(provider: String)
    case rateLimited(provider: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): return message
        case .httpStatus(let status): return "行情服务 HTTP 状态 " + String(status)
        case .malformedData(let message): return "行情数据格式错误：" + message
        case .staleData(let date): return "行情数据已过期（最后日期 " + date.formatted(.iso8601.year().month().day()) + "）"
        case .unsupportedSymbol(let symbol): return "数据源不支持证券代码 " + symbol
        case .missingAPIKey(let provider): return provider + " 未配置 API key"
        case .rateLimited(let provider): return provider + " 请求频率受限"
        }
    }
}

public struct DataFreshnessPolicy: Sendable {
    public var maximumAge: TimeInterval

    public init(maximumAge: TimeInterval = 72 * 60 * 60) {
        self.maximumAge = maximumAge
    }

    public func validate(observedAt: Date, now: Date) throws {
        guard observedAt <= now, now.timeIntervalSince(observedAt) <= maximumAge else {
            throw DataProviderError.staleData(observedAt)
        }
    }
}

public struct CboeVIXProvider: MarketDataProvider {
    public let identifier = "cboe-vix"
    public let displayName = "Cboe VIX（日线）"
    public var client: any HTTPClient
    public var freshness: DataFreshnessPolicy

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        freshness: DataFreshnessPolicy = DataFreshnessPolicy()
    ) {
        self.client = client
        self.freshness = freshness
    }

    public func fetch(symbol: String, now: Date = Date()) async throws -> MarketSnapshot {
        guard symbol.uppercased() == "VIX" || symbol.uppercased() == "^VIX" else {
            throw DataProviderError.unsupportedSymbol(symbol)
        }
        var request = URLRequest(url: URL(string: "https://cdn.cboe.com/api/global/us_indices/daily_prices/VIX_History.csv")!)
        request.httpMethod = "GET"
        request.setValue("MarketMessage/0.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await client.get(request)
        let row = try Self.latestRow(from: data)
        try freshness.validate(observedAt: row.observedAt, now: now)
        return MarketSnapshot(
            symbol: "VIX",
            provider: identifier,
            observedAt: row.observedAt,
            tradingDate: row.tradingDate,
            timeZoneIdentifier: "America/New_York",
            metrics: [
                .close: row.close,
                .dailyPercentChange: row.previousClose.map { row.close / $0 * 100 - 100 } ?? 0
            ]
        )
    }

    private struct Row {
        var tradingDate: Date
        var observedAt: Date
        var close: Double
        var previousClose: Double?
    }

    private static func latestRow(from data: Data) throws -> Row {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DataProviderError.malformedData("CSV 不是 UTF-8")
        }
        let lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.uppercased().contains("DATE") && $0.uppercased().contains("CLOSE") }) else {
            throw DataProviderError.malformedData("找不到 DATE/CLOSE 列")
        }
        let headers = lines[headerIndex].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard let dateIndex = headers.firstIndex(where: { $0 == "DATE" }),
              let closeIndex = headers.firstIndex(where: { $0 == "CLOSE" }) else {
            throw DataProviderError.malformedData("缺少 DATE/CLOSE 列")
        }
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "America/New_York")
        dateFormatter.dateFormat = "MM/dd/yyyy"
        var rows: [(date: Date, close: Double)] = []
        for line in lines.dropFirst(headerIndex + 1) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > max(dateIndex, closeIndex),
                  let date = dateFormatter.date(from: fields[dateIndex].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let close = Double(fields[closeIndex].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            rows.append((date, close))
        }
        guard let latest = rows.max(by: { $0.date < $1.date }) else {
            throw DataProviderError.malformedData("没有有效日线行")
        }
        let previous = rows.filter { $0.date < latest.date }.max(by: { $0.date < $1.date })?.close
        return Row(tradingDate: latest.date, observedAt: latest.date.addingTimeInterval(16 * 60 * 60), close: latest.close, previousClose: previous)
    }
}
