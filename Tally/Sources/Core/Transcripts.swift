import Foundation

// "Where it went": today's Claude Code tokens per project, from the local transcripts
// ~/.claude/projects/<encoded-path>/*.jsonl. Reads only numbers and timestamps; never keeps or logs content.

struct ProjectTokens: Equatable, Sendable, Identifiable {
    var name: String
    var tokens: Int
    var cached: Int = 0
    var id: String { name }
}

enum Transcripts {
    static let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects", isDirectory: true)

    /// "-Users-erik-Projects-copper-shop" to "copper-shop": walks the real folders, taking the longest run of
    /// dash-joined words that exists on disk (a dash may be a path separator or part of a name). A double
    /// dash is a hidden folder ("--claude" is "/.claude"). Falls back to the last word.
    static func projectName(folder: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        var words: [String] = []
        var hidden = false
        for w in folder.split(separator: "-", omittingEmptySubsequences: false).dropFirst() {
            if w.isEmpty { hidden = true; continue }
            words.append((hidden ? "." : "") + w); hidden = false
        }
        var dir = "", name = "", i = 0
        while i < words.count {
            var best: Int?
            var j = words.count
            while j > i {
                if exists(dir + "/" + words[i..<j].joined(separator: "-")) { best = j; break }
                j -= 1
            }
            let end = best ?? i + 1
            name = words[i..<end].joined(separator: "-")
            dir += "/" + name
            i = end
        }
        return name.isEmpty ? folder : name
    }

    struct Key: Hashable { var message: String; var request: String? }
    struct Usage { var at: Date; var tokens: Int; var cached: Int }

    static func parse(line: Substring, iso: ISO8601DateFormatter) -> (id: Key, usage: Usage)? {
        guard line.contains("\"usage\""), line.contains("\"assistant\""),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let ts = obj["timestamp"] as? String, let at = iso.date(from: ts),
              let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { return nil }
        let id = Key(message: (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? ts, request: obj["requestId"] as? String)
        let tokens = (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
        let cached = (u["cache_creation_input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
        return (id, Usage(at: at, tokens: tokens, cached: cached))
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f M", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: n >= 100_000 ? "%.0f K" : "%.1f K", Double(n) / 1000) }
        return "\(n)"
    }

    /// Top rows by tokens; the rest fold into "Other".
    static func top(_ rows: [ProjectTokens], keep: Int = 5) -> [ProjectTokens] {
        var merged: [String: ProjectTokens] = [:]
        for row in rows where row.tokens > 0 || row.cached > 0 {
            var total = merged[row.name] ?? ProjectTokens(name: row.name, tokens: 0)
            total.tokens += row.tokens; total.cached += row.cached
            merged[row.name] = total
        }
        let sorted = merged.values.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
        guard sorted.count > keep + 1 else { return sorted }
        let rest = sorted.dropFirst(keep)
        return Array(sorted.prefix(keep)) + [ProjectTokens(name: "Other", tokens: rest.reduce(0) { $0 + $1.tokens }, cached: rest.reduce(0) { $0 + $1.cached })]
    }
}

/// Scans transcripts off the main thread. Per file it remembers size, mtime and how far it has read, so a
/// file that only grew is read from where it stopped and an untouched one is not opened at all.
actor TranscriptScanner {
    private typealias Messages = [Transcripts.Key: Transcripts.Usage]
    private struct Entry { var size: UInt64; var mtime: Date; var offset: UInt64; var day: Date; var byID: Messages }
    private var cache: [String: Entry] = [:]
    private var names: [String: String] = [:]
    private let root: URL

    init(root: URL = Transcripts.root) { self.root = root }

    func today(now: Date = Date(), calendar: Calendar = .current) -> [ProjectTokens] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fm = FileManager.default
        var out: [ProjectTokens] = []
        var seen = Set<String>()
        for folder in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let dir = root.appendingPathComponent(folder)
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var files = entries.filter { $0.pathExtension == "jsonl" }
            for session in entries where session.hasDirectoryPath {
                let agents = session.appendingPathComponent("subagents", isDirectory: true)
                files += ((try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
            }
            var messages: Messages = [:]
            for url in files {
                guard let a = try? fm.attributesOfItem(atPath: url.path), let mtime = a[.modificationDate] as? Date,
                      let size = (a[.size] as? NSNumber)?.uint64Value, mtime >= start else { continue }   // untouched today: no events today
                seen.insert(url.path)
                messages.merge(read(url, size: size, mtime: mtime, start: start, end: end, iso: iso)) { old, new in
                    (old.at, old.tokens, old.cached) > (new.at, new.tokens, new.cached) ? old : new
                }
            }
            if !messages.isEmpty {
                if names[folder] == nil { names[folder] = Transcripts.projectName(folder: folder) }
                out.append(ProjectTokens(name: names[folder]!, tokens: messages.values.reduce(0) { $0 + $1.tokens }, cached: messages.values.reduce(0) { $0 + $1.cached }))
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return Transcripts.top(out)
    }

    private func read(_ url: URL, size: UInt64, mtime: Date, start: Date, end: Date, iso: ISO8601DateFormatter) -> Messages {
        var e = cache[url.path]
        if let c = e, c.size == size, c.mtime == mtime, c.day == start { return c.byID }
        if let c = e, c.day != start || size < c.size { e = nil }                   // new day or rewritten file: start over
        var entry = e ?? Entry(size: size, mtime: mtime, offset: 0, day: start, byID: [:])
        guard let h = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? h.close() }
        try? h.seek(toOffset: entry.offset)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return entry.byID }
        var consumed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {      // the last piece may be half a line
            consumed += line.utf8.count + 1
            if let p = Transcripts.parse(line: line, iso: iso), p.usage.at >= start, p.usage.at < end { entry.byID[p.id] = p.usage }
        }
        entry.offset += UInt64(consumed); entry.size = size; entry.mtime = mtime
        cache[url.path] = entry
        return entry.byID
    }
}
