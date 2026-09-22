import Foundation

/// Incrementally reads complete lines appended to JSONL files, remembering
/// a byte offset per file so each refresh only parses what's new.
struct JSONLTail {
    private var offsets: [String: UInt64] = [:]

    /// Returns complete (newline-terminated) lines appended since the last call.
    /// `reset` is set when the file shrank and is being re-read from the start.
    mutating func newLines(at url: URL, reset: inout Bool) -> [Data] {
        let path = url.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else { return [] }
        var start = offsets[path] ?? 0
        reset = size.uint64Value < start
        if reset { start = 0 }
        guard size.uint64Value > start, let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: start) } catch { return [] }
        guard let data = try? fh.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        offsets[path] = start + UInt64(complete.count)
        return complete.split(separator: 0x0A).map { Data($0) }
    }

    static func recentFiles(under root: URL, modifiedSince horizon: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, modified >= horizon {
                out.append(url)
            }
        }
        return out
    }
}

extension Data {
    func has(_ needle: Data) -> Bool { range(of: needle) != nil }
}

final class ISODate {
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()

    func parse(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }
}

/// Only keep a bit more than a week of history in memory.
let logHorizon: TimeInterval = 8 * 86400
