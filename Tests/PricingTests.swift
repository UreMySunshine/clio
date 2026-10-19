import Foundation

private final class PricingProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["ETag": "catalog-v2"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main enum PricingTests {
    private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
    }

    private static func catalog() throws -> Data {
        func model(_ input: Double, _ output: Double, _ read: Double, canonical: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["cost": ["input": input, "output": output, "cache_read": read, "cache_write": input * 1.25]]
            if let canonical { value["canonical_model_id"] = canonical }
            return value
        }
        return try JSONSerialization.data(withJSONObject: [
            "anthropic": ["models": ["claude-sonnet-4-6": model(2, 10, 0.2)]],
            "openai": ["models": ["gpt-6-sol": model(3, 12, 0.3), "o3": model(2, 8, 0.5)]],
            "deepseek": ["models": [
                "deepseek-flash": model(0.3, 1.2, 0.006, canonical: "deepseek/deepseek-v4.1-flash-1017"),
                "deepseek-v4-flash": model(0.3, 1.2, 0.006, canonical: "deepseek/deepseek-v4.1-flash-1017"),
                "deepseek-v4-pro": model(1.32, 3.96, 0.044),
                "gpt-6-sol": model(999, 999, 999),
            ]],
            "reseller": ["models": [
                "gpt-6-sol": model(99, 99, 99),
                "deepseek-v4.1-flash": model(99, 99, 99, canonical: "deepseek/deepseek-v4.1-flash"),
            ]],
        ])
    }

    private static func matching(_ data: Data) {
        let table = PriceService.parse(data)!
        for name in ["gpt-6-sol", "openai/gpt-6-sol", "gateway/gpt-6-sol"] {
            expect(table.price(for: name)?.input == 3, "gateway models use the original OpenAI rate")
        }
        expect(table.price(for: "gateway/o3")?.input == 2, "OpenAI reasoning models reuse the same provider normalization")
        expect(table.price(for: "gateway/claude-sonnet-4-6-20261017")?.input == 2, "dated Claude snapshot retains its named base")
        for name in ["gpt-6-sol-preview", "gpt-6-solar", "claude-sonnet-4-60", "deepseek-v4-pro-preview",
                     "workbuddy-ai/deepseek-v4.1-flash", "deepseek-v4.1-flash-1018"] {
            expect(table.price(for: name) == nil, "model versions and variants cannot inherit a different model's price: \(name)")
        }
        expect(table.price(for: "workbuddy-ai/deepseek-v4.1-flash-1017")?.input == 0.3,
               "only the original provider's explicit canonical identity can supply an alias rate")
        expect(table.price(for: "other/deepseek-v4-pro")?.input == 1.32, "DeepSeek variants keep their own rates")
        expect(table.prices["deepseek/gpt-6-sol"] == nil && table.prices["reseller/gpt-6-sol"] == nil,
               "a supplier cannot publish another supplier's model rate")
        let million = TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
        expect(abs(table.cost(million, model: "gateway/deepseek-flash")! - 1.506) < 1e-12,
               "original cache-read prices use dollars per million tokens")
        let writes = TokenCounts(cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        expect(table.cost(writes, model: "gateway/claude-sonnet-4-6") == 6.5, "Claude cache-write lifetimes retain their own prices")
        expect(table.cost(.init(reportedTotal: 10_000), model: "gateway/deepseek-flash") == nil,
               "a total without token details cannot be estimated")
        expect(PriceTable.builtin.cost(.init(input: 100), model: "gateway/codex-auto-review") == 0,
               "automatic review retains its explicit zero rate")
        let missingCache = PriceService.parse(Data(#"{"openai":{"models":{"gpt-plain":{"cost":{"input":2,"output":4}}}}}"#.utf8))!
        expect(missingCache.cost(.init(input: 1_000_000), model: "gateway/gpt-plain") == 2,
               "missing cache prices do not hide available non-cache estimates")
        expect(missingCache.cost(.init(cacheRead: 100), model: "gateway/gpt-plain") == nil,
               "missing official cache-read rates cannot be inferred from input rates")
        expect(missingCache.cost(.init(cacheWrite5m: 100), model: "gateway/gpt-plain") == nil,
               "missing official cache-write rates remain unpriced")
        expect(PriceService.parse(Data(#"{"reseller":{"models":{"gpt-6-sol":{"cost":{"input":1,"output":1}}}}}"#.utf8)) == nil,
               "a reseller-only catalog is not a valid original-provider catalog")
    }

    private static func writeCache(_ path: URL, date: Date, version: Int? = nil) throws {
        let table = PriceTable(prices: ["gpt-6-sol": .make(input: 4, output: 8)])
        var cache: [String: Any] = ["etag": "old-etag", "fetchedAt": date.timeIntervalSinceReferenceDate,
                                  "table": try JSONSerialization.jsonObject(with: JSONEncoder().encode(table))]
        if let version { cache["catalogVersion"] = version }
        try JSONSerialization.data(withJSONObject: cache).write(to: path)
    }

    static func main() async throws {
        let data = try catalog()
        matching(data)
        let root = FileManager.default.temporaryDirectory.appending(path: "clio-pricing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PricingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let freshPath = root.appending(path: "legacy-fresh.json")
        try writeCache(freshPath, date: Date())
        PricingProtocol.handler = { _ in (200, data) }
        let upgraded = PriceService(cachePath: freshPath, session: session)
        await upgraded.refreshIfNeeded()
        expect(PricingProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil,
               "a fresh legacy cache must request the full catalog after adding a provider")
        let upgradedTable = await upgraded.table()
        expect(upgradedTable.price(for: "gateway/deepseek-flash")?.input == 0.3, "new provider rates are available after upgrade")
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: freshPath)) as! [String: Any]
        expect(stored["catalogVersion"] as? Int == 2, "successful refresh records the provider catalog version")
        let count = PricingProtocol.requests.count
        await upgraded.refreshIfNeeded()
        expect(PricingProtocol.requests.count == count, "fresh current catalogs skip the network")
        let restored = PriceService(cachePath: freshPath, session: session)
        expect(await restored.table() == upgradedTable, "cached provider identities and canonical rates survive restart")

        let stalePath = root.appending(path: "stale.json")
        let oldDate = Date().addingTimeInterval(-90_000)
        try writeCache(stalePath, date: oldDate, version: 2)
        PricingProtocol.handler = { request in
            expect(request.value(forHTTPHeaderField: "If-None-Match") == "old-etag", "current stale caches use conditional requests")
            return (304, Data())
        }
        let revalidated = PriceService(cachePath: stalePath, session: session)
        await revalidated.refreshIfNeeded()
        expect(await revalidated.lastFetch! > oldDate, "304 advances a current catalog's validation date")
        expect(await revalidated.table().price(for: "gateway/gpt-6-sol")?.input == 4, "304 preserves cached rates")

        for version in [nil, Optional(2)] {
            let offlinePath = root.appending(path: "offline-\(version ?? 0).json")
            try writeCache(offlinePath, date: oldDate, version: version)
            PricingProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
            let offline = PriceService(cachePath: offlinePath, session: session)
            await offline.refreshIfNeeded()
            let table = await offline.table()
            expect(table.price(for: "gateway/gpt-6-sol")?.input == 4, "offline mode retains legacy and current original-provider rates")
            expect(table.price(for: "gateway/claude-sonnet-4-6") != nil, "offline mode keeps built-in rates")
            expect(table.price(for: "gateway/deepseek-v4.1-flash") == nil, "offline mode cannot invent a DeepSeek model rate")
            let origin = await offline.origin
            let fetchedAt = await offline.lastFetch
            expect(origin == .stale && fetchedAt == oldDate, "failed refresh cannot mark an old catalog as validated")
        }
        let empty = PriceService(cachePath: root.appending(path: "absent.json"), session: session)
        await empty.refreshIfNeeded()
        expect(await empty.origin == .builtin, "without a cache offline mode uses built-in rates")

        let incompletePath = root.appending(path: "legacy-304.json")
        try writeCache(incompletePath, date: oldDate)
        PricingProtocol.handler = { _ in (304, Data()) }
        let incomplete = PriceService(cachePath: incompletePath, session: session)
        await incomplete.refreshIfNeeded()
        expect(await incomplete.lastFetch == oldDate, "304 cannot validate a catalog missing newly supported providers")
        print("Original-provider pricing checks passed (matching, versions, units, cache upgrade, 304 and offline fallback)")
    }
}
