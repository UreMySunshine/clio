import Foundation

/// Price per million tokens. models.dev publishes a single `cache_write`,
/// which is the 5-minute rate; the 1-hour tier costs twice base input.
struct ModelPrice: Codable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double

    static func make(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) -> ModelPrice {
        ModelPrice(input: input,
                   output: output,
                   cacheRead: cacheRead ?? input * 0.1,
                   cacheWrite5m: cacheWrite ?? input * 1.25,
                   cacheWrite1h: input * 2)
    }
}

/// Model id to price. Longest-prefix lookup resolves dated ids such as
/// `claude-haiku-4-5-20251001` against the undated entry.
struct PriceTable: Codable, Equatable {
    var prices: [String: ModelPrice]

    func price(for model: String) -> ModelPrice? {
        if let exact = prices[model] { return exact }
        return prices
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Dollars for one set of token counts, or nil when the model has no price
    /// on file — the UI shows a dash rather than a wrong number.
    func cost(_ counts: TokenCounts, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        let m = 1_000_000.0
        return Double(counts.input) / m * p.input
            + Double(counts.output) / m * p.output
            + Double(counts.cacheRead) / m * p.cacheRead
            + Double(counts.cacheWrite5m) / m * p.cacheWrite5m
            + Double(counts.cacheWrite1h) / m * p.cacheWrite1h
    }

    func merging(_ other: PriceTable) -> PriceTable {
        PriceTable(prices: prices.merging(other.prices) { mine, _ in mine })
    }

    /// Last resort when the app has never reached the network and has no cache.
    static let builtin = PriceTable(prices: [
        "claude-fable-5-1": .make(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": .make(input: 10, output: 50, cacheRead: 1.0),
        "claude-opus-5-5": .make(input: 4, output: 20, cacheRead: 0.2),
        "claude-opus-5": .make(input: 5, output: 25),
        "claude-opus-4-8": .make(input: 5, output: 25),
        "claude-opus-4-7": .make(input: 5, output: 25),
        "claude-opus-4-6": .make(input: 5, output: 25),
        "claude-sonnet-5": .make(input: 2, output: 10),
        "claude-sonnet-4-6": .make(input: 3, output: 15),
        "claude-haiku-4-5": .make(input: 1, output: 5),
    ])
}

enum ModelNaming {
    /// `claude-opus-5-5` → "Opus 5.5", `claude-haiku-4-5-20251001` → "Haiku 4.5".
    /// Ids of any other shape are shown as they are.
    static func displayName(for model: String) -> String {
        guard let match = model.wholeMatch(of: #/claude-([a-z]+)-(\d{1,2})(?:-(\d{1,2}))?(?:-\d{8})?/#)
        else { return model }
        let version = [match.2, match.3].compactMap { $0 }.joined(separator: ".")
        return match.1.capitalized + " " + version
    }
}
