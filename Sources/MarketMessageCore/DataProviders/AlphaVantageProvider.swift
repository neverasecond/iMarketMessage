import Foundation

public protocol APIKeyStore: Sendable {
    func readKey(for provider: String) throws -> String?
    func saveKey(_ key: String, for provider: String) throws
    func deleteKey(for provider: String) throws
}

public enum APIKeyStoreError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "系统 Keychain 不可用"
        case .invalidKey: return "API key 为空或格式无效"
        }
    }
}

public struct MemoryAPIKeyStore: APIKeyStore {
    private let storage: Storage

    private final class Storage: @unchecked Sendable {
        var values: [String: String] = [:]
        let lock = NSLock()
    }

    public init() { storage = Storage() }

    public func readKey(for provider: String) throws -> String? {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.values[provider]
    }

    public func saveKey(_ key: String, for provider: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIKeyStoreError.invalidKey }
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.values[provider] = key
    }

    public func deleteKey(for provider: String) throws {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.values.removeValue(forKey: provider)
    }
}

#if canImport(Security)
import Security

public struct KeychainAPIKeyStore: APIKeyStore {
    public var service: String

    public init(service: String = "com.marketmessage.api-keys") {
        self.service = service
    }

    public func readKey(for provider: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.unavailable
        }
        return key
    }

    public func saveKey(_ key: String, for provider: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIKeyStoreError.invalidKey }
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIKeyStoreError.unavailable }
        } else if status != errSecSuccess {
            throw APIKeyStoreError.unavailable
        }
    }

    public func deleteKey(for provider: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeyStoreError.unavailable }
    }
}
#endif

public struct AlphaVantageProvider: MarketDataProvider {
    public let identifier = "alpha-vantage"
    public let displayName = "Alpha Vantage（日线，BYO key）"
    public var client: any HTTPClient
    public var keyStore: any APIKeyStore
    public var freshness: DataFreshnessPolicy

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        keyStore: any APIKeyStore,
        freshness: DataFreshnessPolicy = DataFreshnessPolicy()
    ) {
        self.client = client
        self.keyStore = keyStore
        self.freshness = freshness
    }

    public func fetch(symbol: String, now: Date = Date()) async throws -> MarketSnapshot {
        guard let key = try keyStore.readKey(for: identifier), !key.isEmpty else {
            throw DataProviderError.missingAPIKey(provider: identifier)
        }
        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "TIME_SERIES_DAILY"),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "outputsize", value: "compact"),
            URLQueryItem(name: "apikey", value: key)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        let (data, _) = try await client.get(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DataProviderError.malformedData("Alpha Vantage 返回非 JSON 对象")
        }
        if let note = object["Note"] as? String, !note.isEmpty {
            throw DataProviderError.rateLimited(provider: identifier)
        }
        if let information = object["Information"] as? String, !information.isEmpty {
            throw DataProviderError.rateLimited(provider: identifier)
        }
        if let message = object["Error Message"] as? String {
            throw DataProviderError.malformedData(message)
        }
        guard let series = object["Time Series (Daily)"] as? [String: [String: Any]] else {
            throw DataProviderError.malformedData("缺少 Time Series (Daily)")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let exchangeTimeZone = TimeZone(identifier: "America/New_York")!
        formatter.timeZone = exchangeTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let sorted = series.keys.compactMap { date -> (Date, [String: Any])? in
            guard let parsed = formatter.date(from: date), let values = series[date] else { return nil }
            return (parsed, values)
        }.sorted { $0.0 > $1.0 }
        guard let latest = sorted.first,
              let close = latest.1["4. close"] as? String,
              let closeValue = Double(close) else {
            throw DataProviderError.malformedData("缺少有效 close")
        }
        let previousClose: Double? = sorted.dropFirst().first.flatMap { $0.1["4. close"] as? String }.flatMap(Double.init)
        var exchangeCalendar = Calendar(identifier: .gregorian)
        exchangeCalendar.timeZone = exchangeTimeZone
        let dateComponents = exchangeCalendar.dateComponents([.year, .month, .day], from: latest.0)
        var closeComponents = DateComponents()
        closeComponents.year = dateComponents.year
        closeComponents.month = dateComponents.month
        closeComponents.day = dateComponents.day
        closeComponents.hour = 16
        closeComponents.minute = 0
        guard let observedAt = exchangeCalendar.date(from: closeComponents) else {
            throw DataProviderError.malformedData("无法构造交易所收盘时间")
        }
        try freshness.validate(observedAt: observedAt, now: now)
        return MarketSnapshot(
            symbol: symbol,
            provider: identifier,
            observedAt: observedAt,
            tradingDate: latest.0,
            timeZoneIdentifier: "America/New_York",
            metrics: [
                .close: closeValue,
                .dailyPercentChange: previousClose.map { closeValue / $0 * 100 - 100 } ?? 0
            ]
        )
    }
}
