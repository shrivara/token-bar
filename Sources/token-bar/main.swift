// token-bar: menu bar readout of today's AI usage (Claude Code, OpenCode, pi).
// Build with ./build.sh; no dependencies beyond AppKit + SQLite3.

import AppKit
import CoreServices
import SQLite3

// MARK: - Aggregation model

struct Agg {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite5m = 0.0
    var cacheWrite1h = 0.0
    var cost = 0.0

    var cacheWrite: Double { cacheWrite5m + cacheWrite1h }
    var contextTotal: Double { input + cacheRead + cacheWrite }
    var hitRate: Double { contextTotal > 0 ? cacheRead / contextTotal : 0 }

    mutating func add(_ o: Agg) {
        input += o.input; output += o.output
        cacheRead += o.cacheRead
        cacheWrite5m += o.cacheWrite5m; cacheWrite1h += o.cacheWrite1h
        cost += o.cost
    }
}

struct SourceStats {
    let name: String
    var available = false
    var agg = Agg()
    var perModel: [String: Agg] = [:]
    var unknownPricing: Set<String> = []

    mutating func finishTotals() {
        for (_, a) in perModel { agg.add(a) }
    }
}

// MARK: - Claude pricing (per MTok; Claude API reference, cached 2026-06-24)

struct Rates { let inPerM: Double; let outPerM: Double }

func claudeRates(for model: String) -> Rates? {
    // Sonnet 5 intro pricing runs through 2026-08-31
    var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 1
    let introEnd = Calendar.current.date(from: comps) ?? .distantPast
    let sonnet5 = Date() < introEnd ? Rates(inPerM: 2, outPerM: 10) : Rates(inPerM: 3, outPerM: 15)

    let table: [(String, Rates)] = [
        ("claude-fable-5", Rates(inPerM: 10, outPerM: 50)),
        ("claude-mythos-5", Rates(inPerM: 10, outPerM: 50)),
        ("claude-opus-4", Rates(inPerM: 5, outPerM: 25)),
        ("claude-sonnet-5", sonnet5),
        ("claude-sonnet-4", Rates(inPerM: 3, outPerM: 15)),
        ("claude-haiku-4-5", Rates(inPerM: 1, outPerM: 5)),
    ]
    var best: (len: Int, rates: Rates)? = nil
    for (prefix, rates) in table where model.hasPrefix(prefix) {
        if best == nil || prefix.count > best!.len { best = (prefix.count, rates) }
    }
    return best?.rates
}

func claudeCost(_ a: Agg, _ r: Rates) -> Double {
    // Cache multipliers on the input rate: read 0.1x, 5m write 1.25x, 1h write 2x
    return (a.input * r.inPerM
        + a.output * r.outPerM
        + a.cacheRead * r.inPerM * 0.1
        + a.cacheWrite5m * r.inPerM * 1.25
        + a.cacheWrite1h * r.inPerM * 2.0) / 1_000_000
}

// MARK: - Shared helpers

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser

func num(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return 0
}

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Date? {
    isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [URL] {
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
    var out: [URL] = []
    for case let url as URL in en where url.pathExtension == "jsonl" {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if mtime >= cutoff { out.append(url) }
    }
    return out
}

// MARK: - Source scanners

func scanClaudeCode(since dayStart: Date) -> SourceStats {
    var s = SourceStats(name: "Claude Code")
    let root = home.appendingPathComponent(".claude/projects")
    guard fm.fileExists(atPath: root.path) else { return s }
    s.available = true

    // Streaming rewrites the same request multiple times; keep the last entry per request+message.
    var dedup: [String: (model: String, usage: [String: Any])] = [:]
    for file in jsonlFiles(under: root, modifiedAfter: dayStart) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = jsonObject(String(line)),
                  d["type"] as? String == "assistant",
                  let msg = d["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let model = msg["model"] as? String, model != "<synthetic>",
                  let ts = d["timestamp"] as? String,
                  let date = parseISO(ts), date >= dayStart
            else { continue }
            let req = (d["requestId"] as? String) ?? (d["uuid"] as? String) ?? ts
            let key = req + ":" + ((msg["id"] as? String) ?? "")
            dedup[key] = (model, usage)
        }
    }

    for (_, entry) in dedup {
        var a = s.perModel[entry.model] ?? Agg()
        let u = entry.usage
        a.input += num(u["input_tokens"])
        a.output += num(u["output_tokens"])
        a.cacheRead += num(u["cache_read_input_tokens"])
        if let cc = u["cache_creation"] as? [String: Any] {
            a.cacheWrite5m += num(cc["ephemeral_5m_input_tokens"])
            a.cacheWrite1h += num(cc["ephemeral_1h_input_tokens"])
        } else {
            a.cacheWrite5m += num(u["cache_creation_input_tokens"])
        }
        s.perModel[entry.model] = a
    }

    for (model, var a) in s.perModel {
        if let r = claudeRates(for: model) {
            a.cost = claudeCost(a, r)
        } else {
            a.cost = claudeCost(a, Rates(inPerM: 5, outPerM: 25))  // Opus fallback
            s.unknownPricing.insert(model)
        }
        s.perModel[model] = a
    }
    s.finishTotals()
    return s
}

func scanOpenCode(since dayStart: Date) -> SourceStats {
    var s = SourceStats(name: "OpenCode")
    let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
    guard fm.fileExists(atPath: dbURL.path) else { return s }
    s.available = true

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return s
    }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT data FROM message WHERE time_created >= ?", -1, &stmt, nil) == SQLITE_OK else { return s }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(dayStart.timeIntervalSince1970 * 1000))

    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let c = sqlite3_column_text(stmt, 0) else { continue }
        guard let d = jsonObject(String(cString: c)),
              d["role"] as? String == "assistant",
              let tokens = d["tokens"] as? [String: Any]
        else { continue }
        let model = (d["modelID"] as? String) ?? "unknown"
        var a = s.perModel[model] ?? Agg()
        a.input += num(tokens["input"])
        a.output += num(tokens["output"]) + num(tokens["reasoning"])  // reasoning bills as output
        if let cache = tokens["cache"] as? [String: Any] {
            a.cacheRead += num(cache["read"])
            a.cacheWrite5m += num(cache["write"])
        }
        a.cost += num(d["cost"])  // OpenCode pre-computes cost per message
        s.perModel[model] = a
    }
    s.finishTotals()
    return s
}

func scanPi(since dayStart: Date) -> SourceStats {
    var s = SourceStats(name: "pi")
    let root = home.appendingPathComponent(".pi/agent/sessions")
    guard fm.fileExists(atPath: root.path) else { return s }
    s.available = true

    for file in jsonlFiles(under: root, modifiedAfter: dayStart) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = jsonObject(String(line)),
                  d["type"] as? String == "message",
                  let msg = d["message"] as? [String: Any],
                  msg["role"] as? String == "assistant",
                  let usage = msg["usage"] as? [String: Any],
                  let ts = d["timestamp"] as? String,
                  let date = parseISO(ts), date >= dayStart
            else { continue }
            let model = (msg["model"] as? String) ?? "unknown"
            var a = s.perModel[model] ?? Agg()
            a.input += num(usage["input"])
            a.output += num(usage["output"])
            a.cacheRead += num(usage["cacheRead"])
            a.cacheWrite5m += num(usage["cacheWrite"])
            if let cost = usage["cost"] as? [String: Any] {
                a.cost += num(cost["total"])  // pi pre-computes cost per message
            }
            s.perModel[model] = a
        }
    }
    s.finishTotals()
    return s
}

// MARK: - Formatting

func fmtTokens(_ n: Double) -> String {
    if n >= 10_000_000 { return String(format: "%.0fM", n / 1_000_000) }
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 100_000 { return String(format: "%.0fK", n / 1_000) }
    if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
    return String(format: "%.0f", n)
}

func fmtMoney(_ d: Double) -> String { String(format: "$%.2f", d) }

// MARK: - App

struct BarValues {
    var cost = 0.0, input = 0.0, output = 0.0, hit = 0.0

    static func lerp(_ a: BarValues, _ b: BarValues, _ t: Double) -> BarValues {
        BarValues(cost: a.cost + (b.cost - a.cost) * t,
                  input: a.input + (b.input - a.input) * t,
                  output: a.output + (b.output - a.output) * t,
                  hit: a.hit + (b.hit - a.hit) * t)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var eventStream: FSEventStreamRef?
    var pendingRefresh: DispatchWorkItem?
    var displayed = BarValues()
    var animTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        startWatching()
        // Fallback: catches midnight rollover, missed events, and dirs created after launch
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func startWatching() {
        let paths = [
            home.appendingPathComponent(".claude/projects").path,
            home.appendingPathComponent(".local/share/opencode").path,
            home.appendingPathComponent(".pi/agent/sessions").path,
        ].filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().scheduleRefresh()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // coalesce events within 300ms
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    // Debounce bursts of file events into a single rescan
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc func quitClicked() { NSApp.terminate(nil) }

    func refresh() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let sources = [
            scanClaudeCode(since: dayStart),
            scanOpenCode(since: dayStart),
            scanPi(since: dayStart),
        ]
        var total = Agg()
        for s in sources { total.add(s.agg) }

        animateBar(to: BarValues(cost: total.cost, input: total.input,
                                 output: total.output, hit: total.hitRate))
        rebuildMenu(total: total, sources: sources)
    }

    func setBarTitle(_ v: BarValues) {
        let text = "\(fmtMoney(v.cost))  \(fmtTokens(v.input))↑ \(fmtTokens(v.output))↓  \(String(format: "%.0f%%", v.hit * 100))"
        // Monospaced digits keep the title from wobbling while values roll
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
    }

    // Roll the bar through intermediate values (ease-out, ~0.8s)
    func animateBar(to target: BarValues) {
        animTimer?.invalidate()
        let start = displayed
        let changed = setBarNeedsUpdate(from: start, to: target)
        guard changed else { return }

        let duration = 0.8
        let t0 = Date()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(t0) / duration)
            let eased = 1 - pow(1 - p, 3)
            self.displayed = BarValues.lerp(start, target, eased)
            self.setBarTitle(self.displayed)
            if p >= 1 { timer.invalidate() }
        }
    }

    func setBarNeedsUpdate(from a: BarValues, to b: BarValues) -> Bool {
        if a.cost == b.cost && a.input == b.input && a.output == b.output && a.hit == b.hit {
            setBarTitle(b)  // keep title in sync even when nothing changed (first draw)
            return false
        }
        return true
    }

    func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    func rebuildMenu(total: Agg, sources: [SourceStats]) {
        guard let menu = statusItem.menu else { return }
        menu.autoenablesItems = false
        menu.removeAllItems()

        // Plain title + trailing badge: native right-aligned value, uniform alignment
        func statItem(_ label: String, _ value: String) -> NSMenuItem {
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.isEnabled = true  // label color, not dimmed; inert (no action)
            item.badge = NSMenuItemBadge(string: value)
            return item
        }

        // Submenu with the full stat block for one aggregate
        func statsSubmenu(_ a: Agg, marker: String = "") -> NSMenu {
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(statItem("Spend", fmtMoney(a.cost) + marker))
            sub.addItem(statItem("Input", fmtTokens(a.input)))
            sub.addItem(statItem("Output", fmtTokens(a.output)))
            sub.addItem(statItem("Cache read", fmtTokens(a.cacheRead)))
            sub.addItem(statItem("Cache write", fmtTokens(a.cacheWrite)))
            sub.addItem(statItem("Cache hit", String(format: "%.0f%%", a.hitRate * 100)))
            return sub
        }

        menu.addItem(NSMenuItem.sectionHeader(title: "Today"))
        menu.addItem(statItem("Spend", fmtMoney(total.cost)))
        menu.addItem(statItem("Input", fmtTokens(total.input)))
        menu.addItem(statItem("Output", fmtTokens(total.output)))
        menu.addItem(statItem("Cache hit", String(format: "%.0f%%", total.hitRate * 100)))

        let active = sources.filter { $0.available && ($0.agg.cost > 0 || $0.agg.contextTotal > 0 || $0.agg.output > 0) }
        for s in active {
            menu.addItem(NSMenuItem.sectionHeader(title: s.name))
            for (model, a) in s.perModel.sorted(by: { $0.value.cost > $1.value.cost }) {
                let marker = s.unknownPricing.contains(model) ? " ~" : ""
                let item = statItem(shortModel(model), fmtMoney(a.cost) + marker)
                item.submenu = statsSubmenu(a, marker: marker)
                menu.addItem(item)
            }
            if s.perModel.count > 1 {
                let item = statItem("Total", fmtMoney(s.agg.cost))
                item.submenu = statsSubmenu(s.agg)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }
}

if CommandLine.arguments.contains("--print") {
    let dayStart = Calendar.current.startOfDay(for: Date())
    let sources = [scanClaudeCode(since: dayStart), scanOpenCode(since: dayStart), scanPi(since: dayStart)]
    var total = Agg()
    for s in sources { total.add(s.agg) }
    for s in sources where s.available {
        for (model, a) in s.perModel.sorted(by: { $0.value.cost > $1.value.cost }) {
            print("\(s.name) / \(model): in=\(Int(a.input)) out=\(Int(a.output)) cache_read=\(Int(a.cacheRead)) cache_write=\(Int(a.cacheWrite)) cost=\(fmtMoney(a.cost))")
        }
    }
    print("TOTAL: spend=\(fmtMoney(total.cost)) in=\(Int(total.input)) out=\(Int(total.output)) hit=\(String(format: "%.1f%%", total.hitRate * 100))")
    print("BAR: \(fmtMoney(total.cost))  \(fmtTokens(total.input))↑ \(fmtTokens(total.output))↓  \(String(format: "%.0f%%", total.hitRate * 100))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
