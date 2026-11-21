import Foundation

// Run with scripts/test.sh. Scratch data only; touches no real files or processes.
@main
struct TallyTests {
    nonisolated(unsafe) static var failed = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "PASS \(name)" : "FAIL \(name)")
        if !ok { failed += 1 }
    }
    static func fixture(_ name: String) -> Data {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        return try! Data(contentsOf: dir.appendingPathComponent(name))
    }

    @MainActor static func testLimitAlerts(now: Date) {
        let end = now.addingTimeInterval(300)
        var state = LimitAlertState()
        func read(_ percent: Double, _ seconds: Double, _ metric: Metric = .fiveHour, reset: Date? = nil) -> [LimitAlert] {
            let time = now.addingTimeInterval(seconds)
            return state.update(metric, reading: Reading(t: time, p: percent, resets: reset ?? end), now: time)
        }
        check(read(79, 0).isEmpty && read(80, 1) == [.five80], "5-hour alert starts at exactly 80%")
        check(read(79, 2).isEmpty && read(94.9, 3).isEmpty && read(95, 4) == [.five95], "a dip does not rearm thresholds; 95% fires once")
        state = try! JSONDecoder().decode(LimitAlertState.self, from: JSONEncoder().encode(state))
        check(read(99, 5).isEmpty && read(70, 6).isEmpty, "restart preserves alert history")
        check(state.update(.fiveHour, reading: nil, now: end) == [.reset] && state.update(.fiveHour, reading: nil, now: end).isEmpty, "busy 5-hour window resets once without another reading")
        check(read(99, 7).isEmpty, "late old-window reading cannot rearm alerts")
        let next = end.addingTimeInterval(18000)
        check(read(80, 301, reset: next) == [.five80] && state.update(.fiveHour, reading: nil, now: next).isEmpty, "new window rearms thresholds; exactly 80% does not earn a reset alert")
        state = LimitAlertState()
        check(read(96, 0, .weekly) == [.weekly80, .weekly95] && read(100, 1, .weekly).isEmpty, "weekly jump crosses both thresholds once")
        check(read(96, 301, .weekly, reset: next) == [.weekly80, .weekly95], "weekly rollover rearms both without a reset alert")
        state = LimitAlertState()
        check(state.update(.fiveHour, reading: Reading(t: now.addingTimeInterval(-1000), p: 99, resets: end), now: now).isEmpty, "stale readings never trigger limit alerts")
        let defaults = UserDefaults(suiteName: "Tally.tests.limitAlerts.\(UUID())")!
        let settings = Settings(defaults: defaults, qa: true)
        check(LimitAlert.allCases.allSatisfy { settings[$0] }, "all five limit alert switches default on")
        settings[.five80] = false
        let restored = Settings(defaults: defaults, qa: true)
        check(LimitAlert.allCases.filter { !restored[$0] } == [.five80], "muting one alert persists independently")
    }

    @MainActor static func testSuddenJumps(now: Date) {
        var detector = SuddenJumpDetector()
        func read(_ percent: Double, _ seconds: Double, key: String = "claude.weekly", reset: Date? = nil, delay: Double = 0) -> Double? {
            let time = now.addingTimeInterval(seconds)
            return detector.update(window: key, reading: Reading(t: time, p: percent, resets: reset), now: time.addingTimeInterval(delay))
        }
        check(read(20, 0) == nil && read(29.9, 600) == nil && read(30, 900) == 10, "10 points across multiple readings at exactly 15 minutes triggers a jump")
        check(read(10, 901, key: "codex.fiveHour") == nil && read(22, 902, key: "codex.fiveHour") == nil, "jump cooldown is shared across windows and services")
        detector = SuddenJumpDetector(lastAlert: detector.lastAlert)
        check(read(10, 4400) == nil && read(25, 4499) == nil && read(26, 4500) == 16, "jump cooldown survives restart and ends at exactly one hour")
        detector = SuddenJumpDetector()
        check(read(10, 0) == nil && read(25, 901) == nil, "jump ignores a baseline older than 15 minutes")
        check(read(42, 901) == nil && read(5, 900) == nil && read(34, 902) == nil, "duplicate and out-of-order readings do not alter the jump baseline")
        check(read(60, 903, key: "claude.model.Sonnet") == nil && read(72, 904, key: "claude.model.Sonnet") == 12, "model windows use their own jump baseline")
        detector = SuddenJumpDetector()
        check(read(10, 0, reset: now.addingTimeInterval(60)) == nil && read(25, 61, reset: now.addingTimeInterval(3600)) == nil, "jump never spans a window reset")
        check(read(10, 0, key: "codex.weekly", delay: 901) == nil && read(30, 60, key: "codex.weekly", delay: 880) == nil, "stale readings cannot seed a jump")
        let defaults = UserDefaults(suiteName: "Tally.tests.suddenJumps.\(UUID())")!
        let settings = Settings(defaults: defaults, qa: true)
        check(settings.suddenJumpAlerts, "sudden-jump switch defaults on")
        settings.suddenJumpAlerts = false
        check(!Settings(defaults: defaults, qa: true).suddenJumpAlerts, "sudden-jump switch persists off")
    }

    static func main() async {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let now = ISO8601DateFormatter().date(from: "2026-11-20T09:00:00Z")!
        testLimitAlerts(now: now)
        testSuddenJumps(now: now)

        // Claude
        let c = ClaudeParser.parse(fixture("claude-usage.json"), readAt: now)!
        check(c.fiveHour?.percent == 34 && c.weekly?.percent == 61.5, "claude windows")
        check(c.extras.keys.sorted() == ["Sonnet"] && c.extras["Sonnet"]?.percent == 12, "claude per-model (null and oauth_apps skipped)")
        check(abs((c.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0) - 1_795_168_800) < 1, "claude microsecond date")
        check(ClaudeParser.parse(Data("{}".utf8), readAt: now) == nil, "claude empty json is unavailable")
        check(ClaudeParser.parse(Data("nope".utf8), readAt: now) == nil, "claude garbage is unavailable")
        let cred = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":\#(Int(now.timeIntervalSince1970 * 1000) + 60000)}}"#
        check(ClaudeParser.token(fromCredentials: Data(cred.utf8), now: now).token == "t", "token valid")
        check(ClaudeParser.token(fromCredentials: Data(cred.utf8), now: now.addingTimeInterval(120)).expired, "token expired")

        let sl = #"{"rate_limits":{"five_hour":{"used_percentage":2,"resets_at":1795085400},"seven_day":{"used_percentage":19,"resets_at":1795536000}}}"#
        let slu = ClaudeParser.parseStatusLine(Data(sl.utf8), readAt: now)!
        let defaults = UserDefaults(suiteName: "Tally.tests.claudeSetup")!
        let model = TallyModel(settings: Settings(defaults: defaults, qa: true), defaults: defaults, live: false)
        check(!model.showsClaudeSetup, "no setup prompt while loading")
        model.claude.error = "No plan reading"
        model.tokens = [ProjectTokens(name: "Paper Planes", tokens: 1240)]
        check(model.showsClaudeSetup, "Claude setup appears without plan readings even with local tokens")
        model.claude.usage = slu
        check(!model.showsClaudeSetup, "status line data hides setup")
        model.claude.usage = c
        check(!model.showsClaudeSetup, "sign-in data hides setup")
        model.claude.usage = nil; model.codex.usage = c
        check(!model.showsClaudeSetup, "Codex data hides setup")
        check(slu.fiveHour?.percent == 2 && slu.weekly?.percent == 19 && slu.weekly?.resetsAt == Date(timeIntervalSince1970: 1795536000), "statusline windows and epoch reset")
        check(ClaudeParser.parseStatusLine(Data(#"{"rate_limits":null}"#.utf8), readAt: now) == nil && ClaudeParser.parseStatusLine(Data("x".utf8), readAt: now) == nil, "statusline without limits is unavailable")
        check(!slu.isStale(now: now.addingTimeInterval(14 * 60)) && slu.isStale(now: now.addingTimeInterval(16 * 60)), "statusline staleness follows the file's mtime")
        var keychainTouched = false
        let off = ClaudeRoute.select(live: false, file: { "file" }, oauth: { keychainTouched = true; return "oauth" })
        check(off == "file" && !keychainTouched, "opt-in gate: no Keychain source when off")
        check(ClaudeRoute.select(live: true, file: { "file" }, oauth: { "oauth" }) == "oauth", "opt-in gate: on overrides the file")

        var backoff: UsageBackoff?
        var failureTime = now
        for minutes in [2, 4, 8, 30, 30] {
            let next = UsageBackoff(after: backoff, now: failureTime)
            let due = failureTime.addingTimeInterval(Double(minutes * 60))
            check(next.retryAt == due && !next.canRetry(at: due.addingTimeInterval(-0.1)) && next.canRetry(at: due), "busy retry waits exactly \(minutes) minutes")
            backoff = try! JSONDecoder().decode(UsageBackoff.self, from: JSONEncoder().encode(next))
            failureTime = due.addingTimeInterval(1)
        }

        // Codex
        let text = String(decoding: fixture("codex-rollout.jsonl"), as: UTF8.self)
        let x = CodexParser.latest(in: text)!
        check(x.weekly?.percent == 24 && x.fiveHour == nil, "codex newest codex event, other limit_id and null skipped")
        check(x.weekly?.resetsAt == Date(timeIntervalSince1970: 1795567621), "codex reset epoch")
        let first = text.split(separator: "\n").first!
        let both = CodexParser.parse(line: Data(first.utf8))!
        check(both.fiveHour?.percent == 20 && both.weekly?.percent == 22, "codex 5h + weekly by window minutes")
        check(CodexParser.latest(in: "{\"payload\":{}}\n") == nil, "codex no data")

        // Stale
        for (usage, percent) in [(c, 34.0), (x, 24.0)] {
            for (seconds, age) in [(600.0, Staleness.fresh), (7200, .stale("as of 2 h ago")), (8 * 86400, .expired)] {
                let time = usage.readAt.addingTimeInterval(seconds)
                check(usage.staleness(now: time) == age && usage.menuPercent(.fiveHour, now: time) == (age == .expired ? nil : percent), "reading at \(Int(seconds / 60)) min: \(age.label ?? "fresh")")
            }
        }
        check(Staleness(age: 900) == .fresh && Staleness(age: 901) == .stale("as of 15 min ago"), "15-minute boundary")
        check(Staleness(age: 604800) == .stale("as of 7 d ago") && Staleness(age: 604801).label == "No recent reading", "seven-day boundary")
        check(x.menuPercent(.fiveHour, now: x.readAt) == 24, "no 5h window falls back to weekly")

        // Today maths (Bangkok midnight = 17:00Z)
        let reset1 = now.addingTimeInterval(4 * 86400)
        let midnight = cal.startOfDay(for: now)
        let afternoon = now.addingTimeInterval(-3600)
        func daily(_ previous: DayBaseline?, _ date: Date, _ percent: Double, reset: Date? = nil) -> DayBaseline {
            Today.record(previous, Reading(t: date, p: percent, resets: reset), calendar: cal)
        }
        func restart(_ state: DayBaseline) -> DayBaseline {
            try! JSONDecoder().decode(DayBaseline.self, from: JSONEncoder().encode(state))
        }
        let early = daily(nil, midnight.addingTimeInterval(-120), 36)
        let lastNight = daily(early, midnight.addingTimeInterval(-1), 40)
        let full = daily(restart(lastNight), afternoon, 47.5)
        check(full.used == 7.5 && full.since == nil, "restart uses last reading before local midnight")
        let partial = daily(restart(daily(nil, afternoon, 40)), now, 47.5)
        check(partial.used == 7.5 && partial.since == afternoon && Fmt.clock(afternoon, now: now, calendar: cal) == "15:00", "restart without prior reading retains since 15:00")
        let reset = daily(restart(partial), now.addingTimeInterval(60), 3)
        check(reset.used == 10.5 && reset.since == afternoon, "weekly reset preserves observed usage on both sides")
        check(daily(restart(reset), now.addingTimeInterval(120), 5).used == 12.5, "restart after reset continues counting")
        check(daily(reset, now, 47.5) == reset, "replayed older reading does not change usage")
        let rollover = daily(daily(nil, lastNight.last.t, 2, reset: midnight), midnight, 5, reset: reset1)
        check(rollover.used == 5 && rollover.since == nil, "reset between midnight anchor and first new reading counts new window")
        check(Today.newAlerts(used: 10.5, budget: 13, alerted: []) == [80], "alert at 80%")
        check(Today.newAlerts(used: 13, budget: 13, alerted: [80]) == [100], "alert at 100% once")
        check(Today.newAlerts(used: 14, budget: 13, alerted: [80, 100]).isEmpty, "no repeat alerts")
        check(Today.newAlerts(used: 5, budget: 0, alerted: []).isEmpty, "zero budget never alerts")

        // Formatting
        check(Fmt.remaining(2 * 3600 + 15 * 60) == "2h 15m", "remaining h m")
        check(Fmt.remaining(3 * 86400 + 5 * 3600) == "3d 5h", "remaining d h")
        check(Fmt.remaining(-5) == "0m", "remaining never negative")
        check(Fmt.reset(now.addingTimeInterval(8100), now: now, weekday: false, calendar: cal) == "resets in 2h 15m, 18:15", "reset line")

        // Pace
        let h: TimeInterval = 3600
        let resetAt = now.addingTimeInterval(48 * h)
        func rd(_ hoursAgo: Double, _ p: Double, _ r: Date? = resetAt) -> Reading { Reading(t: now.addingTimeInterval(-hoursAgo * h), p: p, resets: r) }
        let cur = rd(0, 50)
        func forecast(_ history: [Reading], _ latest: Reading, _ metric: Metric = .weekly) -> Pace.Result {
            Pace.project(history, current: latest, metric: metric, now: now.addingTimeInterval(120))
        }
        let shortReset = now.addingTimeInterval(2 * h)
        func short(_ hours: Double, _ percent: Double) -> Reading { rd(hours, percent, shortReset) }
        check(forecast([short(1.01, 10), short(1, 54), short(0.5, 58)], short(0, 62), .fiveHour) == .finishes(78), "forecast: steady 5-hour pace uses only last 60 min")
        let burst = forecast([rd(24.1, 0), rd(24, 20), rd(12, 20)], rd(0, 68))
        check(burst == .reaches(now.addingTimeInterval(16 * h)), "forecast: weekly burst uses last 24 h and provider time")
        check(forecast([rd(6, 50), rd(4, 50)], cur) == .finishes(50), "forecast: idle stays at current usage")
        check(forecast([rd(25, 10), rd(4, 40), cur], cur) == .gathering, "forecast: fewer than three distinct recent readings")
        check(forecast([rd(8, 80), rd(4, 40)], cur) == .gathering, "forecast: percent drop cuts history")
        check(forecast([rd(8, 30, resetAt.addingTimeInterval(-7 * 86400)), rd(4, 40)], cur) == .gathering, "forecast: older epoch ignored")
        check(forecast([rd(8, 30), rd(4, 40)], rd(0, 50, nil)) == .gathering, "forecast: missing reset is not guessed")
        check(forecast([], rd(0, 100)) == .gathering && forecast([rd(8, 80), rd(4, 90)], rd(0, 100)) == .reaches(now), "forecast: even a full meter needs three readings")
        check(forecast([short(1, 70), short(0.5, 75)], short(0, 80), .fiveHour) == .finishes(100), "forecast: reaching 100 exactly at reset is not early")
        check(Fmt.forecast(burst, readAt: now, reset: resetAt, calendar: cal) == "At this pace you run out around Sat 08:00, 32 h before reset", "forecast: weekday, clock and lead before reset")
        var ring: [Reading] = []
        for i in 0..<200 { ring = Pace.record(ring, Reading(t: now.addingTimeInterval(Double(i) * 6 * 60), p: Double(i) / 10, resets: nil), .fiveHour) }
        check(ring.count == 64 && ring.last?.p == 19.9, "ring buffer caps at capacity, keeps newest")
        check(Pace.record(ring, Reading(t: ring.last!.t.addingTimeInterval(60), p: 99, resets: nil), .fiveHour) == ring, "ring buffer skips readings within 5 min")
        check(Pace.record(ring, Reading(t: ring.last!.t.addingTimeInterval(2000), p: 99, resets: nil), .weekly).count == 65, "weekly buffer keeps one per 30 min and more of them")
        check(Pace.landing(.reaches(now)) == 100 && Pace.landing(.finishes(42)) == 42 && Pace.landing(.gathering) == nil && Pace.landing(nil) == nil, "landing percent for the projection outline")
        check(Pace.epoch([rd(2, 5), rd(1, 6, resetAt.addingTimeInterval(-7 * 86400)), rd(0.5, 7)], resets: resetAt, .weekly).map(\.p) == [5, 7], "strip keeps only this window's readings")
        check(Fmt.pace(.finishes(63.6), now: now) == "On pace to finish at 64%", "pace text finishes")
        check(Fmt.pace(.reaches(now.addingTimeInterval(30 * h)), now: now, calendar: cal) == "At this pace you reach 100% around Sat 22:00", "pace text reaches")
        check(Fmt.clock(now.addingTimeInterval(3600), now: now, calendar: cal) == "17:00", "clock same day")

        // transcripts: names, parsing, today filter, dedup, incremental reads
        let tree: Set<String> = ["/Users", "/Users/e", "/Users/e/Projects", "/Users/e/Projects/copper-shop", "/Users/e/.claude"]
        check(Transcripts.projectName(folder: "-Users-e-Projects-copper-shop", exists: { tree.contains($0) }) == "copper-shop", "project name keeps a dash inside a real folder name")
        check(Transcripts.projectName(folder: "-Users-e--claude", exists: { tree.contains($0) }) == ".claude" && Transcripts.projectName(folder: "-Users-e-Projects-gone-dir", exists: { _ in false }) == "dir", "project name: hidden folder, and the last word when nothing exists")
        check(Transcripts.tokens(812) == "812" && Transcripts.tokens(1_234_567) == "1.2 M" && Transcripts.tokens(48_300) == "48.3 K" && Transcripts.tokens(340_000) == "340 K", "token format")
        let rows = (1...8).map { ProjectTokens(name: "p\($0)", tokens: $0 * 100, cached: $0) } + [ProjectTokens(name: "p8", tokens: 5, cached: 2), ProjectTokens(name: "cache-only", tokens: 0, cached: 9000)]
        let topRows = Transcripts.top(rows)
        check(topRows.count == 6 && topRows[0] == ProjectTokens(name: "p8", tokens: 805, cached: 10) && topRows.last == ProjectTokens(name: "Other", tokens: 600, cached: 9006), "top rows rank by fresh tokens and preserve cached totals in Other")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tally-tr-\(getpid())")
        let proj = tmp.appendingPathComponent("-Users-e-Projects-copper-shop")
        try! FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func ev(_ id: String, _ at: Date, _ i: Int, _ o: Int, _ cc: Int = 0, _ cr: Int = 0, type: String = "assistant", request: String = "r1") -> String {
            #"{"type":"\#(type)","timestamp":"\#(iso.string(from: at))","requestId":"\#(request)","message":{"id":"\#(id)","usage":{"input_tokens":\#(i),"output_tokens":\#(o),"cache_creation_input_tokens":\#(cc),"cache_read_input_tokens":\#(cr)}}}"#
        }
        let file = proj.appendingPathComponent("s.jsonl")
        let lines = [ev("a", noon, 10, 5, 100, 1000), ev("a", noon, 10, 50, 100, 1000), ev("b", noon, 1, 1), ev("old", noon.addingTimeInterval(-86400 * 2), 9999, 9999),
                     ev("u", noon, 7, 7, type: "user"), "not json with \"usage\" and \"assistant\"", #"{"type":"assistant","timestamp":"x","message":{"usage":{}}}"#]
        try! (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let scanner = TranscriptScanner(root: tmp)
        let r1 = await scanner.today(now: noon)
        let agents = proj.appendingPathComponent("s/subagents")
        try! FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let agentLines = [ev("a", noon.addingTimeInterval(-1), 10, 5, 100, 1000), ev("a", noon, 2, 3, 0, 4000, request: "r2")]
        try! (agentLines.joined(separator: "\n") + "\n").write(to: agents.appendingPathComponent("agent.jsonl"), atomically: true, encoding: .utf8)
        let withAgent = await scanner.today(now: noon)
        check(withAgent.count == 1 && withAgent.first?.tokens == 67 && withAgent.first?.cached == 5100, "transcripts: subagent usage deduped across files by message and request")
        let ha = try! FileHandle(forWritingTo: file); ha.seekToEndOfFile()
        ha.write(Data((ev("c", noon, 100, 0) + "\n" + #"{"type":"assistant","times"#).utf8)); try? ha.close()   // a new event and half a line
        let r2 = await scanner.today(now: noon)
        let hb = try! FileHandle(forWritingTo: file); hb.seekToEndOfFile()
        hb.write(Data(#"tamp":"1"}"#.utf8 + Data("\n".utf8))); try? hb.close()
        let r3 = await scanner.today(now: noon)
        check(r1.count == 1 && r1[0].name != "" && r1[0].tokens == 62 && r1[0].cached == 1100, "transcripts: today's input and output counted separately from cache writes and reads")
        check(r2.first?.tokens == 167 && r2.first?.cached == 5100 && r3 == r2, "transcripts: append is read incrementally, half a line waits")

        introFlowChecks { check($0, $1) }

        print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
