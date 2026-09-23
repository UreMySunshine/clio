import Foundation

/// Substring search over raw bytes.
///
/// The session logs are ~1 GiB of UTF-8. Decoding that into `String` and using
/// `String.contains` costs orders of magnitude more than the JSON parsing that
/// follows, because Swift's string comparison is grapheme-aware; `memmem` on
/// the bytes is what makes a full scan take seconds instead of minutes.
enum ByteSearch {
    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { pattern in
            memmem(base, haystack.count, pattern.baseAddress!, needle.count) != nil
        }
    }
}

/// Incremental reader over a tree of append-only `.jsonl` logs.
///
/// A full re-read of every session log is ~1 GiB on an active machine, so each
/// file is remembered by size and modification date and only the bytes appended
/// since the last pass are handed to the parser. A file that shrank was rotated
/// or rewritten and is read from the start again.
final class LogScanner {
    struct FileState {
        var size: Int
        var modified: Date
        var offset: Int
    }

    /// Records older than this are never displayed (the heatmap covers 22
    /// weeks), so files untouched for longer are skipped entirely.
    static let retention: TimeInterval = 180 * 86400

    private let root: URL
    private var states: [String: FileState] = [:]

    init(root: URL) {
        self.root = root
    }

    var rootExists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    /// Walk the tree and pass each newly appended line to `handle` as raw bytes,
    /// with the path of the file it came from.
    /// The buffer is only valid for the duration of the call.
    /// Returns the number of files that had new content.
    @discardableResult
    func scan(handle: (String, UnsafeRawBufferPointer) -> Void) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let cutoff = Date().addingTimeInterval(-Self.retention)
        var touched = 0

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate,
                  modified > cutoff
            else { continue }

            let key = url.path
            let previous = states[key]
            if let previous, previous.size == size, previous.modified == modified { continue }

            // A file smaller than last time was replaced, not appended to.
            let start = (previous.map { size < $0.size ? 0 : $0.offset }) ?? 0
            let consumed = read(url, from: start) { handle(key, $0) }
            states[key] = FileState(size: size, modified: modified, offset: consumed)
            touched += 1
        }
        return touched
    }

    /// Read from `offset` to EOF, emitting complete lines. Returns the offset of
    /// the last newline consumed so a half-written trailing line is re-read on
    /// the next pass instead of being parsed in two halves.
    private func read(_ url: URL, from offset: Int, handle: (UnsafeRawBufferPointer) -> Void) -> Int {
        // Mapped, not read into the heap: single session logs reach tens of
        // megabytes, and mapped pages are reclaimable under memory pressure.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > offset
        else { return offset }

        var consumed = offset
        data[offset...].withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var lineStart = 0
            while lineStart < raw.count {
                guard let newline = memchr(base + lineStart, 0x0A, raw.count - lineStart) else { break }
                let lineEnd = UnsafeRawPointer(newline) - base
                if lineEnd > lineStart {
                    // Each parsed line produces bridged Foundation objects; drain
                    // them per line or a full scan accumulates them all.
                    autoreleasepool {
                        handle(UnsafeRawBufferPointer(start: base + lineStart, count: lineEnd - lineStart))
                    }
                }
                consumed += lineEnd - lineStart + 1
                lineStart = lineEnd + 1
            }
        }
        return consumed
    }
}
