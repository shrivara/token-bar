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

// MARK: - Bundled model pricing (USD per MTok)

public struct Rates: Equatable {
    public let inPerM: Double
    public let outPerM: Double
    public let cacheReadPerM: Double
    public let cacheWritePerM: Double
    public let reasoningPerM: Double

    public init(inPerM: Double, outPerM: Double, cacheReadPerM: Double? = nil,
                cacheWritePerM: Double? = nil, reasoningPerM: Double? = nil) {
        self.inPerM = inPerM
        self.outPerM = outPerM
        self.cacheReadPerM = cacheReadPerM ?? inPerM * 0.1
        self.cacheWritePerM = cacheWritePerM ?? inPerM * 1.25
        self.reasoningPerM = reasoningPerM ?? outPerM
    }
}

public struct PricingCatalog: Decodable {
    public struct Provider: Decodable {
        let models: [String: Model]
    }

    public struct Model: Decodable {
        let input: Double
        let output: Double
        let reasoning: Double?
        let cacheRead: Double?
        let cacheWrite: Double?
        let tiers: [Tier]?

        enum CodingKeys: String, CodingKey {
            case input, output, reasoning, tiers
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    public struct Tier: Decodable {
        let input: Double
        let output: Double
        let reasoning: Double?
        let cacheRead: Double?
        let cacheWrite: Double?
        let tier: Threshold

        enum CodingKeys: String, CodingKey {
            case input, output, reasoning, tier
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    public struct Threshold: Decodable {
        let type: String
        let size: Double
    }

    let providers: [String: Provider]

    public static let bundled: PricingCatalog? = {
        guard let url = Bundle.module.url(forResource: "model-pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(PricingCatalog.self, from: data)
    }()

    func model(provider: String, id: String) -> Model? {
        providers[provider]?.models[id]
    }
}

private struct PricedUsage {
    let input: Double
    let output: Double
    let reasoning: Double
    let cacheRead: Double
    let cacheWrite: Double

    var context: Double { input + cacheRead + cacheWrite }
}

private func price(_ usage: PricedUsage, model: PricingCatalog.Model) -> Double? {
    let tier = model.tiers?
        .filter { $0.tier.type == "context" && usage.context > $0.tier.size }
        .max { $0.tier.size < $1.tier.size }

    let input = tier?.input ?? model.input
    let output = tier?.output ?? model.output
    let reasoning = tier?.reasoning ?? model.reasoning ?? output
    guard usage.cacheRead == 0 || (tier?.cacheRead ?? model.cacheRead) != nil,
          usage.cacheWrite == 0 || (tier?.cacheWrite ?? model.cacheWrite) != nil
    else { return nil }

    let inputCost = usage.input * input
    let outputCost = usage.output * output
    let reasoningCost = usage.reasoning * reasoning
    let cacheReadCost = usage.cacheRead * (tier?.cacheRead ?? model.cacheRead ?? 0)
    let cacheWriteCost = usage.cacheWrite * (tier?.cacheWrite ?? model.cacheWrite ?? 0)
    return (inputCost + outputCost + reasoningCost + cacheReadCost + cacheWriteCost) / 1_000_000
}

private func providerID(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "amazon bedrock", "amazon_bedrock", "aws-bedrock", "bedrock": return "amazon-bedrock"
    case "openai", "open ai", "open_ai": return "openai"
    default: return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private func modelKey(provider: String, model: String) -> String {
    "\(provider)/\(model)"
}

private func catalogPrice(_ usage: PricedUsage, provider: String, model: String,
                          catalog: PricingCatalog?) -> Double? {
    guard let model = catalog?.model(provider: providerID(provider), id: model) else { return nil }
    return price(usage, model: model)
}

public func claudeRates(for model: String, catalog: PricingCatalog? = .bundled) -> Rates? {
    guard let model = catalog?.model(provider: "anthropic", id: model) else { return nil }
    return Rates(inPerM: model.input, outPerM: model.output, cacheReadPerM: model.cacheRead,
                 cacheWritePerM: model.cacheWrite, reasoningPerM: model.reasoning)
}

public func claudeCost(_ a: Agg, _ r: Rates) -> Double {
    return (a.input * r.inPerM
        + a.output * r.outPerM
        + a.cacheRead * r.cacheReadPerM
        + a.cacheWrite5m * r.cacheWritePerM
        + a.cacheWrite1h * r.cacheWritePerM) / 1_000_000
}

// MARK: - Shared helpers

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser

public let claudeProjectsRoot = home.appendingPathComponent(".claude/projects")
public let codexSessionsRoot = home.appendingPathComponent(".codex/sessions")
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
                            buckets: BucketSpec? = nil, catalog: PricingCatalog? = .bundled) -> SourceStats {
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
        let usage = PricedUsage(input: e.input, output: e.output, reasoning: 0,
                                cacheRead: e.cacheRead, cacheWrite: e.cacheWrite)
        let catalogCost = catalogPrice(usage, provider: "anthropic", model: entry.model, catalog: catalog)
        // No pricing fallback: an uncatalogued model contributes $0 and is
        // flagged unknown (shown with a ~ marker) rather than guessed at.
        let cost = catalogCost ?? 0
        a.cost += cost
        s.perModel[entry.model] = a
        if catalogCost == nil {
            s.unknownPricing.insert(entry.model)
        }
        // Spend timeline: per-entry cost lands in the entry's bucket
        if let h = spec.index(entry.date) {
            s.buckets[h] += cost
        }
    }
    s.finishTotals()
    return s
}

public func scanCodex(since dayStart: Date, root: URL = codexSessionsRoot,
                      buckets: BucketSpec? = nil, catalog: PricingCatalog? = .bundled) -> SourceStats {
    var s = SourceStats(name: "Codex")
    let spec = buckets ?? .hours(from: dayStart)
    s.buckets = [Double](repeating: 0, count: spec.count)
    guard fm.fileExists(atPath: root.path) else { return s }
    s.available = true

    let files = jsonlFilesWithDates(under: root)
    s.dataSince = files.map(\.mtime).min()

    for file in files.filter({ $0.mtime >= dayStart }).map(\.url) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        var model = "unknown"
        var previousTotal: [String: Any]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = jsonObject(String(line)),
                  let ts = d["timestamp"] as? String,
                  let date = parseISO(ts)
            else { continue }
            let payload = d["payload"] as? [String: Any] ?? [:]
            if d["type"] as? String == "turn_context",
               let nextModel = payload["model"] as? String, !nextModel.isEmpty {
                model = nextModel
                continue
            }
            guard d["type"] as? String == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any]
            else { continue }

            // Newer Codex logs include the exact delta for this request. For older
            // logs, derive it from the session's cumulative counters.
            let usage: [String: Any]
            if let last = info["last_token_usage"] as? [String: Any] {
                usage = last
            } else {
                var delta: [String: Any] = [:]
                for key in ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"] {
                    delta[key] = max(0, num(total[key]) - num(previousTotal?[key]))
                }
                usage = delta
            }
            previousTotal = total
            guard date >= dayStart else { continue }

            let inputTotal = num(usage["input_tokens"])
            let cacheRead = num(usage["cached_input_tokens"])
            let outputTotal = num(usage["output_tokens"])
            let reasoning = num(usage["reasoning_output_tokens"])
            let input = max(0, inputTotal - cacheRead)
            let output = max(0, outputTotal - reasoning)
            let key = modelKey(provider: "openai", model: model)
            var a = s.perModel[key] ?? Agg()
            a.input += input
            a.cacheRead += cacheRead
            a.output += outputTotal
            let cost = catalogPrice(PricedUsage(input: input, output: output, reasoning: reasoning,
                                                cacheRead: cacheRead, cacheWrite: 0),
                                    provider: "openai", model: model, catalog: catalog) ?? 0
            a.cost += cost
            s.perModel[key] = a
            if catalog?.model(provider: "openai", id: model) == nil { s.unknownPricing.insert(key) }
            if let i = spec.index(date) { s.buckets[i] += cost }
        }
    }
    s.finishTotals()
    return s
}

public func scanOpenCode(since dayStart: Date, dbPath: URL = openCodeDBPath,
                          buckets: BucketSpec? = nil, catalog: PricingCatalog? = .bundled) -> SourceStats {
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
        let provider = providerID((d["providerID"] as? String) ?? "unknown")
        let model = (d["modelID"] as? String) ?? "unknown"
        let key = modelKey(provider: provider, model: model)
        var a = s.perModel[key] ?? Agg()
        let input = num(tokens["input"])
        let output = num(tokens["output"])
        let reasoning = num(tokens["reasoning"])
        a.input += input
        a.output += output + reasoning
        var cacheRead = 0.0
        var cacheWrite = 0.0
        if let cache = tokens["cache"] as? [String: Any] {
            cacheRead = num(cache["read"])
            cacheWrite = num(cache["write"])
            a.cacheRead += cacheRead
            a.cacheWrite5m += cacheWrite
        }
        let usage = PricedUsage(input: input, output: output, reasoning: reasoning,
                                cacheRead: cacheRead, cacheWrite: cacheWrite)
        let catalogCost = catalogPrice(usage, provider: provider, model: model, catalog: catalog)
        // No stored-cost fallback: uncatalogued models show $0 / unknown (~).
        let cost = catalogCost ?? 0
        a.cost += cost
        s.perModel[key] = a
        if catalogCost == nil {
            s.unknownPricing.insert(key)
        }
        if let time = d["time"] as? [String: Any], num(time["created"]) > 0,
           let h = spec.index(Date(timeIntervalSince1970: num(time["created"]) / 1000)) {
            s.buckets[h] += cost
        }
    }
    s.finishTotals()
    return s
}

public func scanPi(since dayStart: Date, root: URL = piSessionsRoot,
                   buckets: BucketSpec? = nil, catalog: PricingCatalog? = .bundled) -> SourceStats {
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
            let provider = providerID((msg["provider"] as? String) ?? "unknown")
            let model = (msg["model"] as? String) ?? "unknown"
            let key = modelKey(provider: provider, model: model)
            var a = s.perModel[key] ?? Agg()
            let input = num(usage["input"])
            let output = num(usage["output"])
            let cacheRead = num(usage["cacheRead"])
            let cacheWrite = num(usage["cacheWrite"])
            a.input += input
            a.output += output
            a.cacheRead += cacheRead
            a.cacheWrite5m += cacheWrite
            let catalogCost = catalogPrice(PricedUsage(input: input, output: output, reasoning: 0,
                                                        cacheRead: cacheRead, cacheWrite: cacheWrite),
                                           provider: provider, model: model, catalog: catalog)
            // No stored-cost fallback: uncatalogued models show $0 / unknown (~).
            let cost = catalogCost ?? 0
            a.cost += cost
            if let h = spec.index(date) {
                s.buckets[h] += cost
            }
            if catalogCost == nil { s.unknownPricing.insert(key) }
            s.perModel[key] = a
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
