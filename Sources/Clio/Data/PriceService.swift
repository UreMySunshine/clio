import Foundation

/// Where the price table in use came from.
enum PriceOrigin: String, Codable {
    /// Fetched from models.dev, either now or in an earlier session.
    case network
    /// A stored table is in use but this session could not revalidate it.
    case stale
    /// Never fetched — the table compiled into the app.
    case builtin

    var label: String {
        switch self {
        case .network: return "models.dev"
        case .stale: return "models.dev（本次校验失败，沿用上次结果）"
        case .builtin: return "内置价格（尚未联网获取）"
        }
    }
}

/// Price table backed by models.dev, cached on disk, falling back to the
/// built-in table. Refreshes are conditional requests, so an unchanged table
/// costs one 304 rather than the full 4 MB document.
actor PriceService {
    static let shared = PriceService()

    private struct Cache: Codable {
        var etag: String?
        var fetchedAt: Date
        var table: PriceTable
    }

    /// Only first-party providers are read. The document also carries resellers
    /// whose entries would otherwise shadow the real rate for the same id.
    private static let providers = ["anthropic", "openai"]
    private static let endpoint = URL(string: "https://models.dev/api.json")!
    private static let refreshInterval: TimeInterval = 24 * 3600

    private var cache: Cache?
    private(set) var origin: PriceOrigin = .builtin

    /// Hand-written rates, applied over everything else. Lets a user price a
    /// model the published table doesn't cover.
    private var overrides: PriceTable {
        guard let data = try? Data(contentsOf: AppPaths.support.appending(path: "pricing.json")),
              let decoded = try? JSONDecoder().decode([String: ModelPrice].self, from: data)
        else { return PriceTable(prices: [:]) }
        return PriceTable(prices: decoded)
    }

    private var cachePath: URL { AppPaths.support.appending(path: "pricing-cache.json") }

    init() {
        if let data = try? Data(contentsOf: AppPaths.support.appending(path: "pricing-cache.json")),
           let decoded = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = decoded
            // The cache is only ever written from a successful fetch, so the
            // table in hand did come from models.dev.
            origin = .network
        }
    }

    /// Current table: overrides, then the fetched/cached table, then built-in.
    func table() -> PriceTable {
        overrides
            .merging(cache?.table ?? PriceTable(prices: [:]))
            .merging(.builtin)
    }

    var lastFetch: Date? { cache?.fetchedAt }

    /// Fetch when the cache is missing or a day old. Any failure leaves the
    /// existing cache in place — prices never go blank because the network did.
    func refreshIfNeeded(force: Bool = false) async {
        if !force, let fetchedAt = cache?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.refreshInterval {
            return
        }
        await refresh()
    }

    func refresh() async {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        if let etag = cache?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                origin = cache == nil ? .builtin : .stale
                return
            }
            if http.statusCode == 304 {
                cache?.fetchedAt = Date()
                origin = .network
                persist()
                return
            }
            guard http.statusCode == 200, let parsed = Self.parse(data) else {
                origin = cache == nil ? .builtin : .stale
                return
            }
            cache = Cache(etag: http.value(forHTTPHeaderField: "ETag"),
                          fetchedAt: Date(),
                          table: parsed)
            origin = .network
            persist()
        } catch {
            // Keep whatever is already loaded and say the check didn't land.
            origin = cache == nil ? .builtin : .stale
        }
    }

    private func persist() {
        guard let cache, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cachePath, options: .atomic)
    }

    /// models.dev shape: provider -> models -> id -> cost { input, output,
    /// cache_read, cache_write }, all per million tokens.
    private static func parse(_ data: Data) -> PriceTable? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var prices: [String: ModelPrice] = [:]
        for provider in providers {
            guard let models = (root[provider] as? [String: Any])?["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                guard let cost = (value as? [String: Any])?["cost"] as? [String: Any],
                      let input = cost["input"] as? Double,
                      let output = cost["output"] as? Double
                else { continue }
                prices[id] = .make(input: input,
                                   output: output,
                                   cacheRead: cost["cache_read"] as? Double,
                                   cacheWrite: cost["cache_write"] as? Double)
            }
        }
        return prices.isEmpty ? nil : PriceTable(prices: prices)
    }
}
