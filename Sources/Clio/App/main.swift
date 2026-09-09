import AppKit

// Two development entry points sit in front of the app: `--dump` prints the
// parsed dashboard, and `--snapshot <dir>` renders each screen to PNG. Both
// exist so the readers and the layout can be checked without the menu bar.
if CommandLine.arguments.contains("--statusline") {
    // Runs as (or in front of) Claude Code's status-line command: capture the
    // quota payload, then hand stdin to the wrapped command untouched.
    let arguments = CommandLine.arguments
    let wrapped = arguments.firstIndex(of: "--").map { Array(arguments[(arguments.index(after: $0))...]) } ?? []
    exit(RateLimitBridge.run(passthrough: wrapped))
} else if CommandLine.arguments.contains("--dump") {
    MainActor.assumeIsolated { DashboardDump.run() }
} else if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
          CommandLine.arguments.count > index + 1 {
    let directory = CommandLine.arguments[index + 1]
    MainActor.assumeIsolated { Snapshot.run(into: directory) }
} else {
    // Top-level code is not main-actor isolated here, but everything it touches
    // is; the process is single-threaded at this point, so the assertion holds.
    let application = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    application.delegate = delegate
    application.run()
}
