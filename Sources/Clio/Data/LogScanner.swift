import CZstd
import Foundation

/// Decode all frames before parsing, so an incomplete or corrupt archive
/// cannot leave partially imported usage behind.
private enum Zstd {
    static func decode(_ data: Data) -> Data? {
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        return data.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var decoded = Data()
            return buffer.withUnsafeMutableBytes { destination in
                while true {
                    var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let remaining = ZSTD_decompressStream(stream, &output, &input)
                    guard ZSTD_isError(remaining) == 0 else { return nil }
                    decoded.append(contentsOf: destination.prefix(output.pos))
                    if remaining == 0 && input.pos == input.size { return decoded }
                    if input.pos == input.size && output.pos < output.size { return nil }
                }
            }
        }
    }
}

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

/// Incremental reader over `.jsonl` logs and `.jsonl.zst` archives.
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
        var identity: AnyHashable?
        var needsRetry = false
    }

    struct Scan {
        fileprivate let files: [(path: String, state: FileState)]
        let needsRebuild: Bool
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

    func reset() {
        states.removeAll()
    }

    /// One metadata walk serves both rebuild detection and incremental reading.
    /// Readers prepare every root before resetting their shared deduplication state.
    func prepare() -> Scan {
        var files: [(path: String, state: FileState)] = []
        var seen: Set<String> = []
        var needsRebuild = false
        let cutoff = Date().addingTimeInterval(-Self.retention)
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
            ],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".jsonl.zst") else {
                    continue
                }
                guard
                    let values = try? url.resourceValues(forKeys: [
                        .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
                    ]),
                    let size = values.fileSize,
                    let modified = values.contentModificationDate,
                    modified > cutoff
                else { continue }

                let key = url.path
                let state = FileState(
                    size: size, modified: modified, offset: 0,
                    identity: values.fileResourceIdentifier as? AnyHashable)
                files.append((key, state))
                seen.insert(key)
                if let previous = states[key] {
                    needsRebuild =
                        needsRebuild || size < previous.size
                        || (size == previous.size && modified != previous.modified)
                        || state.identity != previous.identity
                        || (key.hasSuffix(".jsonl.zst") && (size != previous.size || modified != previous.modified))
                }
            }
        }
        needsRebuild = needsRebuild || states.keys.contains { !seen.contains($0) }
        return Scan(files: files, needsRebuild: needsRebuild)
    }

    /// Emit complete appended lines. Raw buffers live only for the callback.
    /// Returns the number of files with new content.
    @discardableResult
    func scan(_ prepared: Scan? = nil, handle: (String, UnsafeRawBufferPointer) -> Void) -> Int {
        let prepared = prepared ?? prepare()
        var touched = 0
        for (key, current) in prepared.files {
            let previous = states[key]
            if let previous, previous.size == current.size, previous.modified == current.modified,
                !previous.needsRetry
            {
                continue
            }
            let start = previous.map { current.size < $0.size ? 0 : $0.offset } ?? 0
            var state = current
            let reading = autoreleasepool {
                read(URL(fileURLWithPath: key), from: start) { handle(key, $0) }
            }
            state.offset = reading.offset
            state.needsRetry = reading.needsRetry
            states[key] = state
            touched += 1
        }
        return touched
    }

    private struct Reading {
        var offset: Int
        var needsRetry = false
    }

    /// Uncompressed logs use a bounded buffer, including when mmap would fall
    /// back to copying the entire file. Only a line spanning chunks is retained.
    private func read(_ url: URL, from offset: Int, handle: (UnsafeRawBufferPointer) -> Void) -> Reading {
        if url.pathExtension == "zst" { return readArchive(url, from: offset, handle: handle) }
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return Reading(offset: offset, needsRetry: true) }
        defer { close(descriptor) }
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { return Reading(offset: offset, needsRetry: true) }
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var pending = Data()
        var position = offset
        var committed = offset
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return Reading(offset: committed) }
            if count < 0 {
                if errno == EINTR { continue }
                return Reading(offset: committed, needsRetry: true)
            }
            buffer.withUnsafeBytes { whole in
                let raw = UnsafeRawBufferPointer(rebasing: whole[..<count])
                let base = raw.baseAddress!
                var start = 0
                while start < count, let newline = memchr(base + start, 0x0A, count - start) {
                    let end = UnsafeRawPointer(newline) - base
                    let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                    autoreleasepool {
                        if !pending.isEmpty {
                            pending.append(contentsOf: line)
                            pending.withUnsafeBytes(handle)
                            pending.removeAll(keepingCapacity: true)
                        } else if !line.isEmpty {
                            handle(line)
                        }
                    }
                    committed = position + end + 1
                    start = end + 1
                }
                if start < count { pending.append(contentsOf: raw[start..<count]) }
            }
            position += count
        }
    }

    /// Validate the entire compressed archive before exposing any of its lines.
    private func readArchive(_ url: URL, from offset: Int, handle: (UnsafeRawBufferPointer) -> Void) -> Reading {
        guard let compressed = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return Reading(offset: offset, needsRetry: true) }
        guard let data = Zstd.decode(compressed), data.count > offset else { return Reading(offset: offset) }

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
        return Reading(offset: consumed)
    }
}
