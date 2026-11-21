import CoreServices
import Foundation
import Security

enum SourceError: Error, Sendable {
    case message(String)
    case busy
}

/// Default Claude source: the JSON Claude Code's status line writes to a file. No credentials, no network.
enum ClaudeFile {
    static let defaultPath = "~/.claude/cache/usage-latest.json"
    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// nil when the file is missing or has no rate limits. The reading time is the file's modification time.
    static func read(path: String) -> ServiceUsage? {
        let url = URL(fileURLWithPath: expand(path))
        guard let data = try? Data(contentsOf: url),
              let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return ClaudeParser.parseStatusLine(data, readAt: mtime)
    }

    /// A 3-line status line helper for people who do not have the file yet.
    static let helper = """
    input=$(cat)
    mkdir -p ~/.claude/cache && printf '%s' "$input" | jq -c '{rate_limits}' > ~/.claude/cache/usage-latest.json
    echo "$input" | jq -r '.model.display_name'
    """
}

/// Opt-in Claude source: Claude Code's own sign-in, read locally, sent only to api.anthropic.com.
/// shortcut: the token is never refreshed here (that would rotate Claude Code's refresh token);
/// when it has expired, Tally says so until Claude Code runs again.
enum ClaudeSource {
    static func fetch() async -> Result<ServiceUsage, SourceError> {
        let creds = await Task.detached { credentials() }.value
        guard let creds else { return .failure(.message("Sign in to Claude Code to see Claude usage")) }
        let (token, expired) = ClaudeParser.token(fromCredentials: creds, now: Date())
        guard let token else {
            return .failure(.message(expired ? "Claude Code sign-in expired. Use Claude Code once." : "No Claude sign-in found"))
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                if let usage = ClaudeParser.parse(data, readAt: Date()) { return .success(usage) }
                return .failure(.message("Claude usage came back in an unknown format"))
            case 401, 403: return .failure(.message("Claude Code sign-in expired. Use Claude Code once."))
            case 429, 500...599: return .failure(.busy)
            default: return .failure(.message("Claude usage unavailable (HTTP \(code))"))
            }
        } catch {
            return .failure(.message("Claude usage unavailable (offline?)"))
        }
    }

    /// Keychain item "Claude Code-credentials" (one-time macOS prompt), else ~/.claude/.credentials.json.
    private static func credentials() -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Claude Code-credentials",
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        return try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"))
    }
}

/// Codex limits: the newest `rate_limits` event in ~/.codex/sessions rollout files.
/// shortcut: looks at the 5 newest files by name; an old session resumed later is missed.
enum CodexSource {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    static func read(root: URL = root) -> ServiceUsage? {
        newestFiles(root: root, limit: 5).compactMap { tail(of: $0) }.compactMap(CodexParser.latest).max { $0.readAt < $1.readAt }
    }

    static func newestFiles(root: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        func sorted(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var files: [URL] = []
        for y in sorted(root) { for m in sorted(y) { for d in sorted(m) {
            files += sorted(d).filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            if files.count >= limit { return Array(files.prefix(limit)) }
        } } }
        return files
    }

    private static func tail(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        return (try? h.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// FSEvents on a folder (no polling). The callback runs on the main queue.
final class FolderWatcher: @unchecked Sendable {
    private final class Box { let f: @Sendable () -> Void; init(_ f: @escaping @Sendable () -> Void) { self.f = f } }
    private var stream: FSEventStreamRef?
    private let box: Unmanaged<Box>

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        box = Unmanaged.passRetained(Box(onChange))
        var ctx = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().f()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          3.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else {
            box.release(); return nil
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        box.release()
    }
}
