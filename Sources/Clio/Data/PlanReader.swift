import Foundation

/// Reads the subscription tier Claude Code stores in `~/.claude.json` under
/// `oauthAccount`. It is the one piece of plan information recorded locally —
/// the tier name only, never the allowance behind it.
enum PlanReader {
    static func claudeCodePlan() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        let tier = (account["organizationRateLimitTier"] as? String)
            ?? (account["userRateLimitTier"] as? String)
        return tier.flatMap(displayName)
    }

    /// `default_claude_max_5x` → `Max 5×`.
    static func displayName(for tier: String) -> String? {
        let name = tier
            .replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
        switch name {
        case "max_5x": return "Max 5×"
        case "max_20x": return "Max 20×"
        case "pro": return "Pro"
        case "free": return "Free"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default:
            guard !name.isEmpty else { return nil }
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
