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
        var catalogVersion: Int?
    }

    /// Only first-party providers are read. The document also carries resellers
    /// whose entries would otherwise shadow the real rate for the same id.
    private static let providers = ["anthropic", "openai", "deepseek", "zai"]
    private static let catalogVersion = 3
    private static let endpoint = URL(string: "https://models.dev/api.json")!
    private static let refreshInterval: TimeInterval = 24 * 3600

    private var cache: Cache?
    private(set) var origin: PriceOrigin = .builtin

    private let cachePath: URL
    private let session: URLSession

    init(cachePath: URL = AppPaths.support.appending(path: "pricing-cache.json"), session: URLSession = .shared) {
        self.cachePath = cachePath
        self.session = session
        if let data = try? Data(contentsOf: cachePath),
           let decoded = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = decoded
            origin = .network
        }
    }

    /// The fetched original-provider catalog falls back to the built-in rates.
    func table() -> PriceTable {
        (cache?.table ?? PriceTable(prices: [:])).merging(.builtin)
    }

    var lastFetch: Date? { cache?.fetchedAt }

    /// Fetch when the cache is missing or a day old. Any failure leaves the
    /// existing cache in place — prices never go blank because the network did.
    func refreshIfNeeded(force: Bool = false) async {
        if !force, cache?.catalogVersion == Self.catalogVersion, let fetchedAt = cache?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.refreshInterval {
            return
        }
        await refresh()
    }

    func refresh() async {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        if cache?.catalogVersion == Self.catalogVersion, let etag = cache?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                origin = cache == nil ? .builtin : .stale
                return
            }
            if http.statusCode == 304 {
                guard cache?.catalogVersion == Self.catalogVersion else {
                    origin = cache == nil ? .builtin : .stale
                    return
                }
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
                          table: parsed, catalogVersion: Self.catalogVersion)
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
    static func parse(_ data: Data) -> PriceTable? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var prices: [String: ModelPrice] = [:]
        var canonicalPrices: [String: ModelPrice] = [:]
        for provider in providers {
            guard let models = (root[provider] as? [String: Any])?["models"] as? [String: Any] else { continue }
            for id in models.keys.sorted() {
                guard let model = models[id] as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = cost["input"] as? Double,
                      let output = cost["output"] as? Double
                else { continue }
                let name = ModelNaming.key(for: id, source: nil)
                guard ModelNaming.provider(for: name) == provider else { continue }
                let rate = ModelPrice(input: input, output: output,
                                      cacheRead: cost["cache_read"] as? Double,
                                      cacheWrite5m: cost["cache_write"] as? Double,
                                      cacheWrite1h: provider == "anthropic" ? input * 2 : nil)
                prices["\(provider)/\(name)"] = rate
                if let canonical = model["canonical_model_id"] as? String,
                   canonical.hasPrefix(provider + "/") {
                    let canonicalName = ModelNaming.key(for: canonical, source: nil)
                    guard ModelNaming.provider(for: canonicalName) == provider else { continue }
                    canonicalPrices["\(provider)/\(canonicalName)"] = rate
                }
            }
        }
        return prices.isEmpty ? nil : PriceTable(prices: prices.merging(canonicalPrices) { direct, _ in direct })
    }
}
