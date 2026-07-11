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
    /// Spend per hour of the day (24 buckets from dayStart)
    public var hourly = [Double](repeating: 0, count: 24)

    public init(name: String) { self.name = name }

    mutating func finishTotals() {
        for (_, a) in perModel { agg.add(a) }
    }
}

func hourIndex(_ date: Date, since dayStart: Date) -> Int? {
    let h = Int(date.timeIntervalSince(dayStart) / 3600)
    return (0..<24).contains(h) ? h : nil
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

func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [URL] {
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
    var out: [URL] = []
    for case let url as URL in en where url.pathExtension == "jsonl" {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if mtime >= cutoff { out.append(url) }
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
                           now: Date = Date()) -> SourceStats {
    var s = SourceStats(name: "Claude Code")
    guard fm.fileExists(atPath: root.path) else { return s }
    s.available = true

    // Streaming rewrites the same request multiple times; keep the last entry per request+message.
    var dedup: [String: (model: String, usage: [String: Any], date: Date)] = [:]
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
        // Hourly spend: per-entry cost lands in the entry's hour bucket
        if let h = hourIndex(entry.date, since: dayStart) {
            let r = claudeRates(for: entry.model, now: now) ?? opusFallbackRates
            s.hourly[h] += claudeCost(e, r)
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

public func scanOpenCode(since dayStart: Date, dbPath: URL = openCodeDBPath) -> SourceStats {
    var s = SourceStats(name: "OpenCode")
    guard fm.fileExists(atPath: dbPath.path) else { return s }
    s.available = true

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
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
        if let time = d["time"] as? [String: Any], num(time["created"]) > 0,
           let h = hourIndex(Date(timeIntervalSince1970: num(time["created"]) / 1000), since: dayStart) {
            s.hourly[h] += num(d["cost"])
        }
    }
    s.finishTotals()
    return s
}

public func scanPi(since dayStart: Date, root: URL = piSessionsRoot) -> SourceStats {
    var s = SourceStats(name: "pi")
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
                if let h = hourIndex(date, since: dayStart) {
                    s.hourly[h] += num(cost["total"])
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
