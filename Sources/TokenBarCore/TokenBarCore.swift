// TokenBarCore: pure aggregation logic for token-bar (no AppKit).

import Foundation
import SQLite3

// MARK: - Aggregation model

public struct Agg: Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cost: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0,
                cacheWrite5m: Double = 0, cacheWrite1h: Double = 0, cost: Double = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h; self.cost = cost
    }

    public var cacheWrite: Double { cacheWrite5m + cacheWrite1h }
    public var contextTotal: Double { input + cacheRead + cacheWrite }
    public var hitRate: Double { contextTotal > 0 ? cacheRead / contextTotal : 0 }

    public mutating func add(_ o: Agg) {
        input += o.input; output += o.output
        cacheRead += o.cacheRead
        cacheWrite5m += o.cacheWrite5m; cacheWrite1h += o.cacheWrite1h
        cost += o.cost
    }
}

public struct SourceStats {
    public let name: String
    public var available = false
    public var agg = Agg()
    public var perModel: [String: Agg] = [:]
    public var unknownPricing: Set<String> = []
    /// Spend per time bucket (see BucketSpec; defaults to 24 hours from the scan start)
    public var buckets: [Double] = []
    /// Approximate date of this source's oldest data on disk (tools prune their
    /// logs; Claude Code keeps ~30 days by default), regardless of scan period
    public var dataSince: Date?

    public init(name: String) { self.name = name }

    mutating func finishTotals() {
        for (_, a) in perModel { agg.add(a) }
    }
}

/// How to slice a period into spend buckets: a count and a date-to-index mapping.
public struct BucketSpec {
    public let count: Int
    public let index: (Date) -> Int?

    public init(count: Int, index: @escaping (Date) -> Int?) {
        self.count = count
        self.index = index
    }

    /// Fixed-length buckets of `seconds` starting at `start`
    public static func spans(of seconds: TimeInterval, count: Int, from start: Date) -> BucketSpec {
        BucketSpec(count: count) { d in
            // floor, not Int(): truncation would put just-before-start dates in bucket 0
            let i = Int(floor(d.timeIntervalSince(start) / seconds))
            return (0..<count).contains(i) ? i : nil
        }
    }

    /// 24 one-hour buckets from `start` (the default day view)
    public static func hours(from start: Date) -> BucketSpec {
        spans(of: 3600, count: 24, from: start)
    }
}

// MARK: - Claude pricing (per MTok; Claude API reference, cached 2026-06-24)

public struct Rates: Equatable {
    public let inPerM: Double
    public let outPerM: Double
    public init(inPerM: Double, outPerM: Double) { self.inPerM = inPerM; self.outPerM = outPerM }
}

public let opusFallbackRates = Rates(inPerM: 5, outPerM: 25)

public func claudeRates(for model: String, now: Date = Date()) -> Rates? {
    // Sonnet 5 intro pricing runs through 2026-08-31
    var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 1
    let introEnd = Calendar.current.date(from: comps) ?? .distantPast
    let sonnet5 = now < introEnd ? Rates(inPerM: 2, outPerM: 10) : Rates(inPerM: 3, outPerM: 15)

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

public func claudeCost(_ a: Agg, _ r: Rates) -> Double {
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

public let claudeProjectsRoot = home.appendingPathComponent(".claude/projects")
public let openCodeDBPath = home.appendingPathComponent(".local/share/opencode/opencode.db")
public let piSessionsRoot = home.appendingPathComponent(".pi/agent/sessions")

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

/// All .jsonl files with their mtimes; callers filter and take min as needed
func jsonlFilesWithDates(under root: URL) -> [(url: URL, mtime: Date)] {
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
    var out: [(URL, Date)] = []
    for case let url as URL in en where url.pathExtension == "jsonl" {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        out.append((url, mtime))
    }
    return out
}

// MARK: - Formatting

public func fmtTokens(_ n: Double) -> String {
    if n >= 10_000_000 { return String(format: "%.0fM", n / 1_000_000) }
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 100_000 { return String(format: "%.0fK", n / 1_000) }
    if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
    return String(format: "%.0f", n)
}

public func fmtMoney(_ d: Double) -> String { String(format: "$%.2f", d) }

// MARK: - Source scanners

public func scanClaudeCode(since dayStart: Date, root: URL = claudeProjectsRoot,
                           now: Date = Date(), buckets: BucketSpec? = nil) -> SourceStats {
    var s = SourceStats(name: "Claude Code")
    let spec = buckets ?? .hours(from: dayStart)
    s.buckets = [Double](repeating: 0, count: spec.count)
    guard fm.fileExists(atPath: root.path) else { return s }
    s.available = true

    let files = jsonlFilesWithDates(under: root)
    s.dataSince = files.map(\.mtime).min()

    // Streaming rewrites the same request multiple times; keep the last entry per request+message.
    var dedup: [String: (model: String, usage: [String: Any], date: Date)] = [:]
    for file in files.filter({ $0.mtime >= dayStart }).map(\.url) {
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
            dedup[key] = (model, usage, date)
        }
    }

    for (_, entry) in dedup {
        var e = Agg()
        let u = entry.usage
        e.input = num(u["input_tokens"])
        e.output = num(u["output_tokens"])
        e.cacheRead = num(u["cache_read_input_tokens"])
        if let cc = u["cache_creation"] as? [String: Any] {
            e.cacheWrite5m = num(cc["ephemeral_5m_input_tokens"])
            e.cacheWrite1h = num(cc["ephemeral_1h_input_tokens"])
        } else {
            e.cacheWrite5m = num(u["cache_creation_input_tokens"])
        }
        var a = s.perModel[entry.model] ?? Agg()
        a.add(e)
        s.perModel[entry.model] = a
        // Spend timeline: per-entry cost lands in the entry's bucket
        if let h = spec.index(entry.date) {
            let r = claudeRates(for: entry.model, now: now) ?? opusFallbackRates
            s.buckets[h] += claudeCost(e, r)
        }
    }

    for (model, var a) in s.perModel {
        if let r = claudeRates(for: model, now: now) {
            a.cost = claudeCost(a, r)
        } else {
            a.cost = claudeCost(a, opusFallbackRates)
            s.unknownPricing.insert(model)
        }
        s.perModel[model] = a
    }
    s.finishTotals()
    return s
}

public func scanOpenCode(since dayStart: Date, dbPath: URL = openCodeDBPath,
                         buckets: BucketSpec? = nil) -> SourceStats {
    var s = SourceStats(name: "OpenCode")
    let spec = buckets ?? .hours(from: dayStart)
    s.buckets = [Double](repeating: 0, count: spec.count)
    guard fm.fileExists(atPath: dbPath.path) else { return s }
    s.available = true

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return s
    }
    defer { sqlite3_close(db) }

    var minStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT MIN(time_created) FROM message", -1, &minStmt, nil) == SQLITE_OK,
       sqlite3_step(minStmt) == SQLITE_ROW {
        let ms = sqlite3_column_int64(minStmt, 0)
        if ms > 0 { s.dataSince = Date(timeIntervalSince1970: Double(ms) / 1000) }
    }
    sqlite3_finalize(minStmt)

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
        if let time = d["time"] as? [String: Any], num(time["created"]) > 0,
           let h = spec.index(Date(timeIntervalSince1970: num(time["created"]) / 1000)) {
            s.buckets[h] += num(d["cost"])
        }
    }
    s.finishTotals()
    return s
}

public func scanPi(since dayStart: Date, root: URL = piSessionsRoot,
                   buckets: BucketSpec? = nil) -> SourceStats {
    var s = SourceStats(name: "pi")
    let spec = buckets ?? .hours(from: dayStart)
    s.buckets = [Double](repeating: 0, count: spec.count)
    guard fm.fileExists(atPath: root.path) else { return s }
    s.available = true

    let files = jsonlFilesWithDates(under: root)
    s.dataSince = files.map(\.mtime).min()

    for file in files.filter({ $0.mtime >= dayStart }).map(\.url) {
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
                if let h = spec.index(date) {
                    s.buckets[h] += num(cost["total"])
                }
            }
            s.perModel[model] = a
        }
    }
    s.finishTotals()
    return s
}

// MARK: - Bar animation values

public struct BarValues: Equatable {
    public var cost = 0.0, input = 0.0, output = 0.0, hit = 0.0

    public init(cost: Double = 0, input: Double = 0, output: Double = 0, hit: Double = 0) {
        self.cost = cost; self.input = input; self.output = output; self.hit = hit
    }

    public static func lerp(_ a: BarValues, _ b: BarValues, _ t: Double) -> BarValues {
        BarValues(cost: a.cost + (b.cost - a.cost) * t,
                  input: a.input + (b.input - a.input) * t,
                  output: a.output + (b.output - a.output) * t,
                  hit: a.hit + (b.hit - a.hit) * t)
    }
}
