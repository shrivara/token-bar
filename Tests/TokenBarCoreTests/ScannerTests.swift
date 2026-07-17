import SQLite3
import XCTest
@testable import TokenBarCore

/// Shared fixtures: a temp directory per test, and a fixed "day start" one hour
/// in the past so freshly written fixture files always pass the mtime filter.
class FixtureTestCase: XCTestCase {
    var tmp: URL!
    let dayStart = Date().addingTimeInterval(-3600)
    var inRange: String { iso(Date()) }
    var beforeRange: String { iso(Date().addingTimeInterval(-7200)) }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-bar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    func write(_ lines: [String], to relPath: String, mtime: Date? = nil) throws {
        let url = tmp.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime = mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Claude Code

final class ClaudeScannerTests: FixtureTestCase {
    /// A Claude Code JSONL assistant entry in the shape the real logs use.
    func entry(ts: String, req: String, msgId: String = "msg_1", model: String = "claude-fable-5",
               type: String = "assistant", input: Int = 0, output: Int = 0, cacheRead: Int = 0,
               cacheWriteTotal: Int = 0, write5m: Int? = nil, write1h: Int? = nil) -> String {
        var usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": cacheWriteTotal,
        ]
        if write5m != nil || write1h != nil {
            usage["cache_creation"] = ["ephemeral_5m_input_tokens": write5m ?? 0,
                                       "ephemeral_1h_input_tokens": write1h ?? 0]
        }
        let d: [String: Any] = [
            "type": type, "timestamp": ts, "requestId": req,
            "message": ["id": msgId, "model": model, "usage": usage],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    func testAggregatesAcrossFilesAndRequests() throws {
        try write([entry(ts: inRange, req: "r1", input: 100, output: 10)], to: "proj-a/s1.jsonl")
        try write([entry(ts: inRange, req: "r2", input: 200, output: 20)], to: "proj-b/s2.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp)
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.agg.input, 300)
        XCTAssertEqual(s.agg.output, 30)
    }

    func testDedupesStreamingRewritesKeepingLast() throws {
        // Streaming rewrites the same requestId+message id; only the last counts
        try write([
            entry(ts: inRange, req: "r1", msgId: "m1", input: 100, output: 5),
            entry(ts: inRange, req: "r1", msgId: "m1", input: 100, output: 50),
        ], to: "p/s.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp)
        XCTAssertEqual(s.agg.input, 100)
        XCTAssertEqual(s.agg.output, 50)
    }

    func testDistinctMessagesOfOneRequestBothCount() throws {
        try write([
            entry(ts: inRange, req: "r1", msgId: "m1", output: 10),
            entry(ts: inRange, req: "r1", msgId: "m2", output: 20),
        ], to: "p/s.jsonl")
        XCTAssertEqual(scanClaudeCode(since: dayStart, root: tmp).agg.output, 30)
    }

    func testFiltersEntriesBeforeDayStart() throws {
        try write([
            entry(ts: beforeRange, req: "old", input: 999),
            entry(ts: inRange, req: "new", input: 1),
        ], to: "p/s.jsonl")
        XCTAssertEqual(scanClaudeCode(since: dayStart, root: tmp).agg.input, 1)
    }

    func testSkipsFilesNotModifiedSinceDayStart() throws {
        try write([entry(ts: inRange, req: "r1", input: 500)], to: "p/stale.jsonl",
                  mtime: Date().addingTimeInterval(-7200))
        XCTAssertEqual(scanClaudeCode(since: dayStart, root: tmp).agg.input, 0)
    }

    func testSkipsSyntheticNonAssistantAndGarbage() throws {
        try write([
            entry(ts: inRange, req: "r1", model: "<synthetic>", input: 100),
            entry(ts: inRange, req: "r2", type: "user", input: 100),
            "not json at all {{{",
            "",
            entry(ts: inRange, req: "r3", input: 7),
        ], to: "p/s.jsonl")
        XCTAssertEqual(scanClaudeCode(since: dayStart, root: tmp).agg.input, 7)
    }

    func testCacheWriteSplitHonors5mAnd1h() throws {
        try write([entry(ts: inRange, req: "r1", write5m: 100, write1h: 200)], to: "p/s.jsonl")
        let a = scanClaudeCode(since: dayStart, root: tmp).agg
        XCTAssertEqual(a.cacheWrite5m, 100)
        XCTAssertEqual(a.cacheWrite1h, 200)
    }

    func testCacheWriteFallsBackTo5mWithoutBreakdown() throws {
        try write([entry(ts: inRange, req: "r1", cacheWriteTotal: 300)], to: "p/s.jsonl")
        let a = scanClaudeCode(since: dayStart, root: tmp).agg
        XCTAssertEqual(a.cacheWrite5m, 300)
        XCTAssertEqual(a.cacheWrite1h, 0)
    }

    func testCostComputedFromRates() throws {
        // 1M output tokens on fable-5 = $50
        try write([entry(ts: inRange, req: "r1", output: 1_000_000)], to: "p/s.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp)
        XCTAssertEqual(s.agg.cost, 50, accuracy: 1e-9)
        XCTAssertTrue(s.unknownPricing.isEmpty)
    }

    func testUnknownModelFallsBackToOpusAndIsMarked() throws {
        try write([entry(ts: inRange, req: "r1", model: "claude-zeta-7", output: 1_000_000)],
                  to: "p/s.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp)
        XCTAssertEqual(s.agg.cost, 25, accuracy: 1e-9)  // opus fallback output rate
        XCTAssertEqual(s.unknownPricing, ["claude-zeta-7"])
    }

    func testMissingCatalogFallsBackToOpus() throws {
        try write([entry(ts: inRange, req: "r1", output: 1_000_000)], to: "p/s.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp, catalog: nil)
        XCTAssertEqual(s.agg.cost, 25, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, ["claude-fable-5"])
    }

    func testMissingRootIsUnavailable() {
        let s = scanClaudeCode(since: dayStart, root: tmp.appendingPathComponent("nope"))
        XCTAssertFalse(s.available)
        XCTAssertEqual(s.agg, Agg())
    }
}

// MARK: - OpenCode

final class OpenCodeScannerTests: FixtureTestCase {
    var dbURL: URL { tmp.appendingPathComponent("opencode.db") }

    func makeDB(rows: [(timeCreated: Date, data: [String: Any])]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL,
                time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)
            """, nil, nil, nil)
        for (i, row) in rows.enumerated() {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES (?,?,?,?,?)", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            let ms = Int64(row.timeCreated.timeIntervalSince1970 * 1000)
            let json = String(data: try JSONSerialization.data(withJSONObject: row.data), encoding: .utf8)!
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT
            sqlite3_bind_text(stmt, 1, "msg_\(i)", -1, transient)
            sqlite3_bind_text(stmt, 2, "ses_1", -1, transient)
            sqlite3_bind_int64(stmt, 3, ms)
            sqlite3_bind_int64(stmt, 4, ms)
            sqlite3_bind_text(stmt, 5, json, -1, transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
    }

    func assistant(provider: String = "openai", model: String = "gpt-5", input: Int, output: Int, reasoning: Int = 0,
                    cacheRead: Int = 0, cacheWrite: Int = 0, cost: Double) -> [String: Any] {
        ["role": "assistant", "providerID": provider, "modelID": model, "cost": cost,
         "tokens": ["input": input, "output": output, "reasoning": reasoning,
                    "cache": ["read": cacheRead, "write": cacheWrite]]]
    }

    func testAggregatesAssistantRowsAndUsesStoredCostWhenCatalogCannotResolve() throws {
        try makeDB(rows: [
            (Date(), assistant(input: 100, output: 50, cost: 0.25)),
            (Date(), assistant(input: 200, output: 100, cost: 0.5)),
        ])
        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.agg.input, 300)
        XCTAssertEqual(s.agg.output, 150)
        XCTAssertEqual(s.agg.cost, 0.75, accuracy: 1e-9)
    }

    func testReasoningCountsAsOutput() throws {
        try makeDB(rows: [(Date(), assistant(input: 10, output: 20, reasoning: 30, cost: 0))])
        XCTAssertEqual(scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil).agg.output, 50)
    }

    func testCacheTokensMapped() throws {
        try makeDB(rows: [(Date(), assistant(input: 0, output: 0, cacheRead: 700, cacheWrite: 80, cost: 0))])
        let a = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil).agg
        XCTAssertEqual(a.cacheRead, 700)
        XCTAssertEqual(a.cacheWrite, 80)
    }

    func testExcludesUserRowsAndOldRows() throws {
        try makeDB(rows: [
            (Date(), ["role": "user", "tokens": ["input": 999]]),
            (Date().addingTimeInterval(-7200), assistant(input: 888, output: 0, cost: 9)),
            (Date(), assistant(input: 1, output: 1, cost: 0.1)),
        ])
        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(s.agg.input, 1)
        XCTAssertEqual(s.agg.cost, 0.1, accuracy: 1e-9)
    }

    func testGroupsByModel() throws {
        try makeDB(rows: [
            (Date(), assistant(model: "gpt-5", input: 1, output: 1, cost: 0.1)),
            (Date(), assistant(model: "big-pickle", input: 2, output: 2, cost: 0)),
        ])
        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(Set(s.perModel.keys), ["openai/gpt-5", "openai/big-pickle"])
    }

    func testNormalizesProviderBeforeGrouping() throws {
        try makeDB(rows: [
            (Date(), assistant(provider: "OpenAI", model: "gpt-5", input: 1, output: 1, cost: 0.1)),
            (Date(), assistant(provider: "open_ai", model: "gpt-5", input: 2, output: 2, cost: 0.2)),
        ])
        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(Set(s.perModel.keys), ["openai/gpt-5"])
        XCTAssertEqual(s.perModel["openai/gpt-5"]!.cost, 0.3, accuracy: 1e-9)
    }

    func testMissingDBIsUnavailable() {
        XCTAssertFalse(scanOpenCode(since: dayStart, dbPath: dbURL).available)
    }

    func testCatalogRepricesZeroStoredCostIncludingReasoningAndCache() throws {
        let json = """
        {"providers":{"openai":{"models":{"gpt-test":{"input":1,"output":2,"reasoning":3,"cache_read":0.1,"cache_write":1.25}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        try makeDB(rows: [
            (Date(), assistant(model: "gpt-test", input: 1_000_000, output: 1_000_000,
                                reasoning: 1_000_000, cacheRead: 1_000_000,
                                cacheWrite: 1_000_000, cost: 0)),
        ])

        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 7.35, accuracy: 1e-9)
        XCTAssertTrue(s.unknownPricing.isEmpty)
    }

    func testCatalogPreservesBedrockProviderAndModelIdentity() throws {
        let json = """
        {"providers":{"amazon-bedrock":{"models":{"us.anthropic.claude-sonnet-4-6":{"input":3,"output":15,"cache_read":0.3,"cache_write":3.75}}},"openai":{"models":{"us.anthropic.claude-sonnet-4-6":{"input":99,"output":99}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        try makeDB(rows: [
            (Date(), assistant(provider: "amazon-bedrock", model: "us.anthropic.claude-sonnet-4-6",
                                input: 1_000_000, output: 0, cost: 0)),
        ])

        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 3, accuracy: 1e-9)
        XCTAssertNotNil(s.perModel["amazon-bedrock/us.anthropic.claude-sonnet-4-6"])
    }

    func testCatalogSelectsContextTierPerMessage() throws {
        let json = """
        {"providers":{"openai":{"models":{"tiered":{"input":1,"output":1,"tiers":[{"input":2,"output":2,"tier":{"type":"context","size":10}}]}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        try makeDB(rows: [
            (Date(), assistant(model: "tiered", input: 1_000_000, output: 0, cost: 0)),
        ])

        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 2, accuracy: 1e-9)
    }
}

// MARK: - Codex

final class CodexScannerTests: FixtureTestCase {
    func line(ts: String, type: String, payload: [String: Any]) -> String {
        let d: [String: Any] = ["timestamp": ts, "type": type, "payload": payload]
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    func testAggregatesRequestDeltasAndSeparatesCachedAndReasoningTokens() throws {
        let catalogJSON = """
        {"providers":{"openai":{"models":{"gpt-test":{"input":2,"output":10,"reasoning":20,"cache_read":0.2}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        try write([
            line(ts: inRange, type: "turn_context", payload: ["model": "gpt-test"]),
            line(ts: inRange, type: "event_msg", payload: ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 1_000_000, "cached_input_tokens": 400_000,
                                      "output_tokens": 300_000, "reasoning_output_tokens": 100_000],
                "last_token_usage": ["input_tokens": 1_000_000, "cached_input_tokens": 400_000,
                                     "output_tokens": 300_000, "reasoning_output_tokens": 100_000],
            ]]),
        ], to: "2026/01/session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.agg.input, 600_000)
        XCTAssertEqual(s.agg.cacheRead, 400_000)
        XCTAssertEqual(s.agg.output, 300_000)
        XCTAssertEqual(s.agg.cost, 5.28, accuracy: 1e-9)
        XCTAssertEqual(s.buckets.reduce(0, +), s.agg.cost, accuracy: 1e-9)
        XCTAssertTrue(s.unknownPricing.isEmpty)
    }

    func testFallsBackToCumulativeDifferenceForOlderLogs() throws {
        try write([
            line(ts: inRange, type: "turn_context", payload: ["model": "gpt-test"]),
            line(ts: inRange, type: "event_msg", payload: ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 2],
            ]]),
            line(ts: inRange, type: "event_msg", payload: ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 25, "cached_input_tokens": 9, "output_tokens": 5],
            ]]),
        ], to: "session.jsonl")
        let s = scanCodex(since: dayStart, root: tmp, catalog: nil)
        XCTAssertEqual(s.agg.input, 16)
        XCTAssertEqual(s.agg.cacheRead, 9)
        XCTAssertEqual(s.agg.output, 5)
    }

    func testMissingRootIsUnavailable() {
        XCTAssertFalse(scanCodex(since: dayStart, root: tmp.appendingPathComponent("nope")).available)
    }
}

// MARK: - pi

final class PiScannerTests: FixtureTestCase {
    func entry(ts: String, role: String = "assistant", type: String = "message",
               model: String = "claude-sonnet-4-5", input: Int = 0, output: Int = 0,
               cacheRead: Int = 0, cacheWrite: Int = 0, cost: Double = 0) -> String {
        let d: [String: Any] = [
            "type": type, "id": UUID().uuidString, "timestamp": ts,
            "message": ["role": role, "model": model, "provider": "anthropic",
                        "usage": ["input": input, "output": output,
                                  "cacheRead": cacheRead, "cacheWrite": cacheWrite,
                                  "totalTokens": input + output,
                                  "cost": ["input": 0, "output": 0, "cacheRead": 0,
                                           "cacheWrite": 0, "total": cost]]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    func testAggregatesAssistantMessagesAndTrustsStoredCost() throws {
        try write([
            entry(ts: inRange, input: 100, output: 10, cacheRead: 500, cacheWrite: 50, cost: 0.2),
            entry(ts: inRange, input: 200, output: 20, cost: 0.3),
        ], to: "--proj--/s1.jsonl")
        let s = scanPi(since: dayStart, root: tmp, catalog: nil)
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.agg.input, 300)
        XCTAssertEqual(s.agg.output, 30)
        XCTAssertEqual(s.agg.cacheRead, 500)
        XCTAssertEqual(s.agg.cacheWrite, 50)
        XCTAssertEqual(s.agg.cost, 0.5, accuracy: 1e-9)
    }

    func testSkipsUserMessagesOtherEntryTypesAndOldTimestamps() throws {
        try write([
            entry(ts: inRange, role: "user", input: 999),
            entry(ts: inRange, type: "compaction", input: 999),
            entry(ts: beforeRange, input: 999),
            entry(ts: inRange, input: 5, cost: 0.1),
        ], to: "--proj--/s1.jsonl")
        let s = scanPi(since: dayStart, root: tmp, catalog: nil)
        XCTAssertEqual(s.agg.input, 5)
        XCTAssertEqual(s.agg.cost, 0.1, accuracy: 1e-9)
    }

    func testMissingRootIsUnavailable() {
        XCTAssertFalse(scanPi(since: dayStart, root: tmp.appendingPathComponent("nope")).available)
    }

    func testCatalogRepricesPiMessages() throws {
        let json = """
        {"providers":{"anthropic":{"models":{"claude-test":{"input":2,"output":10,"cache_read":0.2,"cache_write":2.5}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        try write([
            entry(ts: inRange, model: "claude-test", input: 1_000_000, output: 1_000_000,
                  cacheRead: 1_000_000, cacheWrite: 1_000_000, cost: 0),
        ], to: "--proj--/s1.jsonl")

        let s = scanPi(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 14.7, accuracy: 1e-9)
        XCTAssertTrue(s.unknownPricing.isEmpty)
    }
}

// MARK: - Hourly spend buckets

final class HourlyBucketTests: FixtureTestCase {
    func claudeLine(ts: String, req: String, output: Int) -> String {
        let d: [String: Any] = [
            "type": "assistant", "timestamp": ts, "requestId": req,
            "message": ["id": "m1", "model": "claude-fable-5",
                        "usage": ["input_tokens": 0, "output_tokens": output,
                                  "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    func testClaudeHourlyBucketsAndSumMatchesTotalCost() throws {
        try write([
            claudeLine(ts: inRange, req: "r1", output: 1_000_000),                            // bucket 1 (now)
            claudeLine(ts: iso(dayStart.addingTimeInterval(60)), req: "r2", output: 500_000), // bucket 0
        ], to: "p/s.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp)
        XCTAssertEqual(s.buckets.reduce(0, +), s.agg.cost, accuracy: 1e-9)
        XCTAssertEqual(s.buckets[0], 25, accuracy: 1e-9)  // 0.5M output at fable $50/M
        XCTAssertEqual(s.buckets[1], 50, accuracy: 1e-9)
    }

    func testOpenCodeHourlyUsesStoredCost() throws {
        let dbURL = tmp.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL,
                time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)
            """, nil, nil, nil)
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let data: [String: Any] = ["role": "assistant", "modelID": "gpt-5", "cost": 0.4,
                                   "tokens": ["input": 1, "output": 1],
                                   "time": ["created": ms]]
        let json = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES ('m1','s1',\(ms),\(ms),?)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, json, -1, transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(s.buckets.reduce(0, +), 0.4, accuracy: 1e-9)
        XCTAssertEqual(s.buckets[1], 0.4, accuracy: 1e-9)  // "now" is one hour after dayStart
    }

    func testPiHourlyUsesStoredCost() throws {
        let d: [String: Any] = [
            "type": "message", "id": "e1", "timestamp": inRange,
            "message": ["role": "assistant", "model": "claude-sonnet-4-5",
                        "usage": ["input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 0,
                                  "cost": ["total": 0.7]]],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
        try write([line], to: "--p--/s.jsonl")
        let s = scanPi(since: dayStart, root: tmp, catalog: nil)
        XCTAssertEqual(s.buckets.reduce(0, +), 0.7, accuracy: 1e-9)
        XCTAssertEqual(s.buckets[1], 0.7, accuracy: 1e-9)
    }
}

// MARK: - Custom bucket specs (week/month/year views)

final class BucketSpecTests: FixtureTestCase {
    func testDailyBucketsForWeekView() throws {
        let weekStart = Date().addingTimeInterval(-3 * 86_400)
        let spec = BucketSpec.spans(of: 86_400, count: 7, from: weekStart)
        // Mid-bucket timestamp: an on-the-boundary date can flip buckets after
        // millisecond-precision ISO serialization
        let midBucket3 = weekStart.addingTimeInterval(3 * 86_400 + 1800)
        let d: [String: Any] = [
            "type": "assistant", "timestamp": iso(midBucket3), "requestId": "r1",
            "message": ["id": "m1", "model": "claude-fable-5",
                        "usage": ["input_tokens": 0, "output_tokens": 1_000_000,
                                  "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]],
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
        try write([line], to: "p/s.jsonl")
        let s = scanClaudeCode(since: weekStart, root: tmp, buckets: spec)
        XCTAssertEqual(s.buckets.count, 7)
        XCTAssertEqual(s.buckets[3], 50, accuracy: 1e-9)  // "now" is day 3 of the window
        XCTAssertEqual(s.buckets.reduce(0, +), s.agg.cost, accuracy: 1e-9)
    }

    func testOutOfRangeDatesDropOutOfBuckets() {
        let spec = BucketSpec.spans(of: 3600, count: 24, from: Date())
        XCTAssertNil(spec.index(Date().addingTimeInterval(-10)))
        XCTAssertNil(spec.index(Date().addingTimeInterval(25 * 3600)))
        XCTAssertEqual(spec.index(Date().addingTimeInterval(3700)), 1)
    }
}

// MARK: - Data coverage (per source)

final class DataSinceTests: FixtureTestCase {
    func testNilWhenSourceHasNoFiles() {
        XCTAssertNil(scanClaudeCode(since: dayStart, root: tmp).dataSince)
    }

    func testOldestFileMtimeEvenOutsideScanPeriod() throws {
        let old = Date().addingTimeInterval(-40 * 86_400)
        try write(["{}"], to: "p/a.jsonl", mtime: old)  // prune boundary marker
        try write(["{}"], to: "p/b.jsonl")              // fresh
        let s = scanClaudeCode(since: dayStart, root: tmp)
        XCTAssertNotNil(s.dataSince)
        XCTAssertEqual(s.dataSince!.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 2)
    }

    func testOpenCodeUsesOldestRow() throws {
        let old = Date().addingTimeInterval(-100 * 86_400)
        let dbURL = tmp.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL,
                time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)
            """, nil, nil, nil)
        let ms = Int64(old.timeIntervalSince1970 * 1000)
        sqlite3_exec(db, "INSERT INTO message VALUES ('m1','s1',\(ms),\(ms),'{}')", nil, nil, nil)
        sqlite3_close(db)
        let s = scanOpenCode(since: dayStart, dbPath: dbURL)
        XCTAssertNotNil(s.dataSince)
        XCTAssertEqual(s.dataSince!.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 2)
    }
}
