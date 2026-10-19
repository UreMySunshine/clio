import Foundation

/// Dollars per million tokens; missing cache rates remain unavailable.
/// Anthropic cache writes use the published 5-minute rate and twice base input for 1 hour.
struct ModelPrice: Codable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite5m: Double?
    var cacheWrite1h: Double?

    static func make(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) -> ModelPrice {
        ModelPrice(input: input,
                   output: output,
                   cacheRead: cacheRead ?? input * 0.1,
                   cacheWrite5m: cacheWrite ?? input * 1.25,
                   cacheWrite1h: input * 2)
    }
}

/// Original-provider rates keyed by provider and exact model id.
struct PriceTable: Codable, Equatable {
    var prices: [String: ModelPrice]

    func price(for model: String) -> ModelPrice? {
        let id = ModelNaming.key(for: model, source: nil)
        let provider = ModelNaming.provider(for: id)
        func exact(_ id: String) -> ModelPrice? {
            if let provider, let price = prices["\(provider)/\(id)"] { return price }
            return prices[id]
        }
        if let price = exact(id) { return price }
        // Anthropic's dated snapshots retain their explicitly named base model.
        if provider == "anthropic", let match = id.wholeMatch(of: #/(claude-.+)-\d{8}/#) {
            return exact(String(match.1))
        }
        return nil
    }

    /// Totals without token details or an equivalent original-provider model remain unpriced.
    func cost(_ counts: TokenCounts, model: String) -> Double? {
        let detailed = counts.input + counts.output + counts.cacheRead + counts.cacheWrite
        guard counts.total == detailed, let p = price(for: model),
              counts.cacheRead == 0 || p.cacheRead != nil,
              counts.cacheWrite5m == 0 || p.cacheWrite5m != nil,
              counts.cacheWrite1h == 0 || p.cacheWrite1h != nil
        else { return nil }
        let m = 1_000_000.0
        return Double(counts.input) / m * p.input
            + Double(counts.output) / m * p.output
            + Double(counts.cacheRead) / m * (p.cacheRead ?? 0)
            + Double(counts.cacheWrite5m) / m * (p.cacheWrite5m ?? 0)
            + Double(counts.cacheWrite1h) / m * (p.cacheWrite1h ?? 0)
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
        // Codex's automatic review is free with a ChatGPT sign-in and has no
        // published rate.
        "codex-auto-review": .make(input: 0, output: 0),
    ])
}

enum ModelNaming {
    static func provider(for model: String) -> String? {
        if model.hasPrefix("claude-") { return "anthropic" }
        if model.hasPrefix("deepseek-") { return "deepseek" }
        if ["gpt-", "chatgpt-", "o1", "o3", "o4", "text-embedding-"].contains(where: { model.hasPrefix($0) }) {
            return "openai"
        }
        return nil
    }

    static func key(for model: String, source: Tool?) -> String {
        if model == "unknown", source == .codex { return "codex:unknown" }
        guard let leaf = model.split(separator: "/", omittingEmptySubsequences: false).last,
              !leaf.isEmpty else { return model }
        let name = leaf.lowercased()
        let known = provider(for: name) != nil || name == "codex-auto-review"
        return known ? name : model
    }

    /// `claude-opus-5-5` → "Opus 5.5", `claude-haiku-4-5-20251001` → "Haiku 4.5".
    /// Ids of any other shape are shown as they are.
    static func displayName(for model: String) -> String {
        if model == "codex:unknown" { return "Codex" }
        guard let match = model.wholeMatch(of: #/claude-([a-z]+)-(\d{1,2})(?:-(\d{1,2}))?(?:-\d{8})?/#)
        else { return model }
        let version = [match.2, match.3].compactMap { $0 }.joined(separator: ".")
        return match.1.capitalized + " " + version
    }
}
