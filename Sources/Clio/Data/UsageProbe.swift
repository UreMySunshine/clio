import Foundation
import CFNetwork

/// Asks Claude Code itself for the plan's quota state.
///
/// The CLI answers a `get_usage` control request with the full set — the
/// 5-hour and 7-day windows plus the per-model weekly one — using the existing
/// login, spending no tokens and writing no transcript. Nothing on disk records
/// any of it, so this is the only source.
enum UsageProbe {
    private static let candidates = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    static var executable: URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `nil` when the CLI is absent, too slow, or answers without limits — it
    /// reports `rate_limits: null` for a while after a window resets. The caller
    /// keeps showing the previous reading rather than asking again.
    static func fetch(timeout: TimeInterval = 20) -> RateLimitSnapshot? {
        guard let executable else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--print", "--verbose",
                             "--input-format", "stream-json",
                             "--output-format", "stream-json"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // A GUI process launched from the Finder has no `USER`, and without it
        // the CLI resolves no account and answers with `rate_limits: null`. The
        // proxy settings matter for the same reason: the CLI reaches the API
        // through whatever the system is configured to use, and a request that
        // cannot leave the machine also comes back as null.
        var environment = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // Node trusts the system store, so a proxy signing with a locally
            // installed CA still validates.
            "NODE_USE_SYSTEM_CA": "1",
        ]
        environment.merge(systemProxyEnvironment()) { current, _ in current }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // Terminating the child closes the pipe, which is what releases the
        // blocking read below if the answer never comes.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }

        let request = #"{"type":"control_request","request_id":"clio","request":{"subtype":"get_usage","skip_behaviors":true}}"# + "\n"
        input.fileHandleForWriting.write(Data(request.utf8))
        try? input.fileHandleForWriting.close()

        var buffer = Data()
        var snapshot: RateLimitSnapshot?
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let found = parse(buffer) { snapshot = found; break }
        }
        if process.isRunning { process.terminate() }
        return snapshot
    }

    /// The system's own proxy configuration, in the form command-line tools read.
    private static func systemProxyEnvironment() -> [String: String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        var environment: [String: String] = [:]
        func proxy(_ enable: CFString, _ host: CFString, _ port: CFString) -> String? {
            guard settings[enable as String] as? Int == 1,
                  let host = settings[host as String] as? String,
                  let port = settings[port as String] as? Int
            else { return nil }
            return "http://\(host):\(port)"
        }
        if let https = proxy(kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort) {
            environment["HTTPS_PROXY"] = https
        }
        if let http = proxy(kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy, kCFNetworkProxiesHTTPPort) {
            environment["HTTP_PROXY"] = http
        }
        if let exceptions = settings[kCFNetworkProxiesExceptionsList as String] as? [String], !exceptions.isEmpty {
            environment["NO_PROXY"] = exceptions.joined(separator: ",")
        }
        return environment
    }

    private static func parse(_ buffer: Data) -> RateLimitSnapshot? {
        for line in buffer.split(separator: UInt8(ascii: "\n")) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  root["type"] as? String == "control_response",
                  let response = root["response"] as? [String: Any],
                  let payload = response["response"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }
            return RateLimitPayload.snapshot(from: limits)
        }
        return nil
    }
}
