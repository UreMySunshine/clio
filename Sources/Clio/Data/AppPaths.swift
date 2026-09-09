import Foundation

enum AppPaths {
    /// `~/Library/Application Support/Clio`. Holds the milestone
    /// snapshot and the hand-written price overrides.
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "Clio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
