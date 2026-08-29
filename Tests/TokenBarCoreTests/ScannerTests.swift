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
               cacheWriteTotal: Int = 0, write5m: Int? = nil, write1h: Int? = nil,
               sessionID: String? = nil, cwd: String? = nil, title: String? = nil) -> String {
        var usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": cacheWriteTotal,
        ]
        if write5m != nil || write1h != nil {
            usage["cache_creation"] = ["ephemeral_5m_input_tokens": write5m ?? 0,
                                       "ephemeral_1h_input_tokens": write1h ?? 0]
        }
        var d: [String: Any] = [
            "type": type, "timestamp": ts, "requestId": req,
            "message": ["id": msgId, "model": model, "usage": usage],
        ]
        if let sessionID { d["sessionId"] = sessionID }
        if let cwd { d["cwd"] = cwd }
        if let title { d["slug"] = title }
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

    func testUnknownModelCostsNothingAndIsMarked() throws {
        try write([entry(ts: inRange, req: "r1", model: "claude-zeta-7", output: 1_000_000)],
                  to: "p/s.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp)
        XCTAssertEqual(s.agg.cost, 0, accuracy: 1e-9)  // no pricing fallback
        XCTAssertEqual(s.unknownPricing, ["claude-zeta-7"])
    }

    func testMissingCatalogCostsNothingAndMarks() throws {
        try write([entry(ts: inRange, req: "r1", output: 1_000_000)], to: "p/s.jsonl")
        let s = scanClaudeCode(since: dayStart, root: tmp, catalog: nil)
        XCTAssertEqual(s.agg.cost, 0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, ["claude-fable-5"])
    }

    func testMissingRootIsUnavailable() {
        let s = scanClaudeCode(since: dayStart, root: tmp.appendingPathComponent("nope"))
        XCTAssertFalse(s.available)
        XCTAssertEqual(s.agg, Agg())
    }

    func testAttributesUsageToSessionAndGitProject() throws {
        let repo = tmp.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let linkedRepo = tmp.appendingPathComponent("repo-link")
        try FileManager.default.createSymbolicLink(at: linkedRepo, withDestinationURL: repo)
        let linkedNested = linkedRepo.appendingPathComponent("Sources/Feature")
        let alternateCase = linkedNested.path.uppercased()
        let recordedCWD = FileManager.default.fileExists(atPath: alternateCase)
            ? alternateCase : linkedNested.path
        let logs = tmp.appendingPathComponent("logs")
        try write([
            entry(ts: inRange, req: "r1", output: 10, sessionID: "claude-session",
                  cwd: recordedCWD, title: "bright-otter"),
            entry(ts: inRange, req: "r2", output: 20, sessionID: "claude-session",
                  cwd: recordedCWD, title: "bright-otter"),
        ], to: "logs/s.jsonl")

        let stats = scanClaudeCode(since: dayStart, root: logs, catalog: nil)
        let session = try XCTUnwrap(stats.sessions["claude-session"])
        XCTAssertEqual(session.projectPath, repo.path)
        XCTAssertEqual(session.title, "bright-otter")
        XCTAssertEqual(session.agg.output, 30)
        XCTAssertEqual(session.agg, stats.agg)
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

    func testAggregatesAssistantRowsAndCostsNothingWhenCatalogCannotResolve() throws {
        try makeDB(rows: [
            (Date(), assistant(input: 100, output: 50, cost: 0.25)),
            (Date(), assistant(input: 200, output: 100, cost: 0.5)),
        ])
        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.agg.input, 300)
        XCTAssertEqual(s.agg.output, 150)
        XCTAssertEqual(s.agg.cost, 0, accuracy: 1e-9)  // stored cost is not trusted
        XCTAssertEqual(s.unknownPricing, ["openai/gpt-5"])
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
        XCTAssertEqual(s.agg.cost, 0, accuracy: 1e-9)  // uncatalogued: no stored-cost fallback
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
        XCTAssertEqual(s.perModel["openai/gpt-5"]!.cost, 0, accuracy: 1e-9)  // uncatalogued
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

    func testCatalogUsesExactOpenCodeModePriceBeforeBaseFallback() throws {
        let json = """
        {"providers":{"openai":{"models":{"gpt-test":{"input":1,"output":7},"gpt-test-fast":{"input":2,"output":14}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        try makeDB(rows: [
            (Date(), assistant(model: "gpt-test-fast", input: 0, output: 1_000_000, cost: 0)),
        ])

        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 14, accuracy: 1e-9)
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

    func testAttributesUsageThroughSessionAndProjectTables() throws {
        let repo = tmp.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("apps/client")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        // Leave the recorded session directory deleted: project.worktree must
        // still preserve attribution to the repository.

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE project (id text PRIMARY KEY, worktree text)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE session (id text PRIMARY KEY, project_id text, directory text, title text)", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL,
                time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)
            """, nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO project VALUES ('project-1','\(repo.path)')", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO session VALUES ('opencode-session','project-1','\(nested.path)','Refactor UI')", nil, nil, nil)

        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let data = assistant(input: 90, output: 12, cost: 0)
        let json = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES ('m1','opencode-session',\(ms),\(ms),?)", -1,
                                          &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, json, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        let session = try XCTUnwrap(stats.sessions["opencode-session"])
        XCTAssertEqual(session.projectPath, repo.path)
        XCTAssertEqual(session.title, "Refactor UI")
        XCTAssertEqual(session.agg.input, 90)
        XCTAssertEqual(session.agg.output, 12)
        XCTAssertEqual(session.agg, stats.agg)
    }
}

// MARK: - Codex

final class CodexScannerTests: FixtureTestCase {
    func line(ts: String, type: String, payload: [String: Any]) -> String {
        let d: [String: Any] = ["timestamp": ts, "type": type, "payload": payload]
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    func request(model: String, input: Int = 0, output: Int = 1_000_000) -> [String] {
        let usage = ["input_tokens": input, "cached_input_tokens": 0,
                     "output_tokens": output, "reasoning_output_tokens": 0]
        return [
            line(ts: inRange, type: "turn_context", payload: ["model": model]),
            line(ts: inRange, type: "event_msg", payload: ["type": "token_count", "info": [
                "total_token_usage": usage, "last_token_usage": usage,
            ]]),
        ]
    }

    func testAggregatesRequestDeltasAndSeparatesCacheAndReasoningTokens() throws {
        let catalogJSON = """
        {"providers":{"openai":{"models":{"gpt-test":{"input":2,"output":10,"reasoning":20,"cache_read":0.2,"cache_write":4}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        try write([
            line(ts: inRange, type: "turn_context", payload: ["model": "gpt-test"]),
            line(ts: inRange, type: "event_msg", payload: ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 1_000_000, "cached_input_tokens": 400_000,
                                      "cache_write_input_tokens": 100_000,
                                      "output_tokens": 300_000, "reasoning_output_tokens": 100_000],
                "last_token_usage": ["input_tokens": 1_000_000, "cached_input_tokens": 400_000,
                                     "cache_write_input_tokens": 100_000,
                                     "output_tokens": 300_000, "reasoning_output_tokens": 100_000],
            ]]),
        ], to: "2026/01/session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertTrue(s.available)
        XCTAssertEqual(s.agg.input, 500_000)
        XCTAssertEqual(s.agg.cacheRead, 400_000)
        XCTAssertEqual(s.agg.cacheWrite, 100_000)
        XCTAssertEqual(s.agg.output, 300_000)
        XCTAssertEqual(s.agg.cost, 5.48, accuracy: 1e-9)
        XCTAssertEqual(s.buckets.reduce(0, +), s.agg.cost, accuracy: 1e-9)
        XCTAssertTrue(s.unknownPricing.isEmpty)
    }

    func testFallsBackToCumulativeDifferenceForOlderLogs() throws {
        try write([
            line(ts: inRange, type: "turn_context", payload: ["model": "gpt-test"]),
            line(ts: inRange, type: "event_msg", payload: ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 10, "cached_input_tokens": 4,
                                      "cache_write_input_tokens": 2, "output_tokens": 2],
            ]]),
            line(ts: inRange, type: "event_msg", payload: ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 25, "cached_input_tokens": 9,
                                      "cache_write_input_tokens": 5, "output_tokens": 5],
            ]]),
        ], to: "session.jsonl")
        let s = scanCodex(since: dayStart, root: tmp, catalog: nil)
        XCTAssertEqual(s.agg.input, 11)
        XCTAssertEqual(s.agg.cacheRead, 9)
        XCTAssertEqual(s.agg.cacheWrite, 5)
        XCTAssertEqual(s.agg.output, 5)
    }

    func testNamespacedModelsFallBackToCanonicalSuffixAndAreMarkedApproximate() throws {
        let catalogJSON = """
        {"providers":{"openai":{"models":{"gpt-5.6-sol":{"input":5,"output":30},"gpt-5.6-terra":{"input":2,"output":12}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        let sol = "openai/global.openai.gpt-5.6-sol"
        let terra = "openai/global.openai.gpt-5.6-terra"
        try write(request(model: sol) + request(model: terra), to: "session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        let solKey = "openai/\(sol)"
        let terraKey = "openai/\(terra)"
        XCTAssertEqual(s.perModel[solKey]?.cost ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(s.perModel[terraKey]?.cost ?? -1, 12, accuracy: 1e-9)
        XCTAssertEqual(s.agg.cost, 42, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, Set([solKey, terraKey]))
    }

    func testExactModelMatchWinsOverItsStrippedSuffix() throws {
        let catalogJSON = """
        {"providers":{"openai":{"models":{"openai/global.openai.gpt-exact":{"input":1,"output":7},"gpt-exact":{"input":1,"output":99}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        let model = "openai/global.openai.gpt-exact"
        try write(request(model: model), to: "session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 7, accuracy: 1e-9)
        XCTAssertTrue(s.unknownPricing.isEmpty)
    }

    func testTrailingModelModeFallsBackToBaseAndIsMarkedApproximate() throws {
        let catalogJSON = """
        {"providers":{"openai":{"models":{"gpt-test":{"input":1,"output":7}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        let model = "gpt-test-fast"
        try write(request(model: model), to: "session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 7, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, ["openai/\(model)"])
    }

    func testModelFallbackKeepsClosestModeWhileRemovingQualifiers() throws {
        let catalogJSON = """
        {"providers":{"openai":{"models":{"gpt-test-fast":{"input":1,"output":7},"gpt-test":{"input":1,"output":99}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        let model = "router/gpt-test-fast-preview"
        try write(request(model: model), to: "session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 7, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, ["openai/\(model)"])
    }

    func testModelFallbackUsesLongestAvailableSuffix() throws {
        let catalogJSON = """
        {"providers":{"openai":{"models":{"global.openai.gpt-test":{"input":1,"output":7},"gpt-test":{"input":1,"output":99}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        let model = "router/global.openai.gpt-test"
        try write(request(model: model), to: "session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 7, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, ["openai/\(model)"])
    }

    func testModelFallbackDoesNotSearchUnrelatedProviders() throws {
        let catalogJSON = """
        {"providers":{"amazon-bedrock":{"models":{"gpt-test":{"input":1,"output":99}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(catalogJSON.utf8))
        let model = "router/global.openai.gpt-test"
        try write(request(model: model), to: "session.jsonl")

        let s = scanCodex(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, ["openai/\(model)"])
    }

    func testMissingRootIsUnavailable() {
        XCTAssertFalse(scanCodex(since: dayStart, root: tmp.appendingPathComponent("nope")).available)
    }

    func testAttributesUsageFromSessionMetadata() throws {
        let repo = tmp.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("Packages/App")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let logs = tmp.appendingPathComponent("logs")
        let metadata = line(ts: inRange, type: "session_meta",
                            payload: ["session_id": "codex-session", "cwd": nested.path,
                                      "title": "Fix the build"])
        try write([metadata] + request(model: "gpt-test", input: 40, output: 50),
                  to: "logs/session.jsonl")

        let stats = scanCodex(since: dayStart, root: logs, catalog: nil)
        let session = try XCTUnwrap(stats.sessions["codex-session"])
        XCTAssertEqual(session.projectPath, repo.path)
        XCTAssertEqual(session.title, "Fix the build")
        XCTAssertEqual(session.agg.input, 40)
        XCTAssertEqual(session.agg.output, 50)
        XCTAssertEqual(session.agg, stats.agg)
    }
}

// MARK: - pi

final class PiScannerTests: FixtureTestCase {
    func entry(ts: String, role: String = "assistant", type: String = "message",
               provider: String = "anthropic", model: String = "claude-sonnet-4-5",
               input: Int = 0, output: Int = 0, cacheRead: Int = 0,
               cacheWrite: Int = 0, cost: Double = 0) -> String {
        let d: [String: Any] = [
            "type": type, "id": UUID().uuidString, "timestamp": ts,
            "message": ["role": role, "model": model, "provider": provider,
                        "usage": ["input": input, "output": output,
                                  "cacheRead": cacheRead, "cacheWrite": cacheWrite,
                                  "totalTokens": input + output,
                                  "cost": ["input": 0, "output": 0, "cacheRead": 0,
                                           "cacheWrite": 0, "total": cost]]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
    }

    func testAggregatesAssistantMessagesAndCostsNothingWhenUncatalogued() throws {
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
        XCTAssertEqual(s.agg.cost, 0, accuracy: 1e-9)  // stored cost is not trusted
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
        XCTAssertEqual(s.agg.cost, 0, accuracy: 1e-9)  // uncatalogued: no stored-cost fallback
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

    func testQualifiedProviderFallsBackToBaseProviderPrices() throws {
        let json = """
        {"providers":{"anthropic":{"models":{"claude-test":{"input":2,"output":10}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        let providers = ["anthropic-custom/plan", "anthropic_custom", "anthropic/plan"]
        try write(providers.map {
            entry(ts: inRange, provider: $0, model: "claude-test",
                  input: 1_000_000, output: 1_000_000)
        }, to: "--proj--/s1.jsonl")

        let s = scanPi(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 36, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, Set(providers.map { "\($0)/claude-test" }))
    }

    func testQualifiedProviderAndNamespacedModelFallbacksCompose() throws {
        let json = """
        {"providers":{"anthropic":{"models":{"claude-test":{"input":2,"output":10}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        let provider = "anthropic-custom/plan"
        let model = "gateway/v1.anthropic.claude-test"
        try write([
            entry(ts: inRange, provider: provider, model: model,
                  input: 1_000_000, output: 1_000_000),
        ], to: "--proj--/s1.jsonl")

        let s = scanPi(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 12, accuracy: 1e-9)
        XCTAssertEqual(s.unknownPricing, ["\(provider)/\(model)"])
    }

    func testBedrockMantleUsesAmazonBedrockCatalogPrices() throws {
        let json = """
        {"providers":{"amazon-bedrock":{"models":{"openai.gpt-5.6-sol":{"input":5.5,"output":33}}}}}
        """
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data(json.utf8))
        try write([
            entry(ts: inRange, provider: "bedrock-mantle", model: "openai.gpt-5.6-sol",
                  output: 1_000_000),
        ], to: "--proj--/s1.jsonl")

        let s = scanPi(since: dayStart, root: tmp, catalog: catalog)
        XCTAssertEqual(s.agg.cost, 33, accuracy: 1e-9)
        XCTAssertNotNil(s.perModel["amazon-bedrock/openai.gpt-5.6-sol"])
        XCTAssertTrue(s.unknownPricing.isEmpty)
    }

    func testAttributesUsageFromSessionHeader() throws {
        let repo = tmp.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("Tools")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let header: [String: Any] = ["type": "session", "id": "pi-session",
                                     "cwd": nested.path, "title": "Ship attribution",
                                     "timestamp": inRange, "version": 3]
        let headerLine = String(data: try JSONSerialization.data(withJSONObject: header),
                                encoding: .utf8)!
        let logs = tmp.appendingPathComponent("logs")
        try write([headerLine, entry(ts: inRange, input: 70, output: 8)],
                  to: "logs/session.jsonl")

        let stats = scanPi(since: dayStart, root: logs, catalog: nil)
        let session = try XCTUnwrap(stats.sessions["pi-session"])
        XCTAssertEqual(session.projectPath, repo.path)
        XCTAssertEqual(session.title, "Ship attribution")
        XCTAssertEqual(session.agg.input, 70)
        XCTAssertEqual(session.agg.output, 8)
        XCTAssertEqual(session.agg, stats.agg)
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

    func testOpenCodeHourlyBucketGetsCatalogCost() throws {
        let dbURL = tmp.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL,
                time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)
            """, nil, nil, nil)
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        // 1M input tokens at $0.4/M = $0.40, priced from the catalog (not stored cost)
        let data: [String: Any] = ["role": "assistant", "providerID": "openai", "modelID": "gpt-5",
                                   "cost": 99,  // stored cost is ignored
                                   "tokens": ["input": 1_000_000, "output": 0],
                                   "time": ["created": ms]]
        let json = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES ('m1','s1',\(ms),\(ms),?)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, json, -1, transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data("""
        {"providers":{"openai":{"models":{"gpt-5":{"input":0.4,"output":0}}}}}
        """.utf8))
        let s = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: catalog)
        XCTAssertEqual(s.buckets.reduce(0, +), 0.4, accuracy: 1e-9)
        XCTAssertEqual(s.buckets[1], 0.4, accuracy: 1e-9)  // "now" is one hour after dayStart
    }

    func testPiHourlyBucketGetsCatalogCost() throws {
        let d: [String: Any] = [
            "type": "message", "id": "e1", "timestamp": inRange,
            "message": ["role": "assistant", "model": "claude-sonnet-4-5", "provider": "anthropic",
                        "usage": ["input": 1_000_000, "output": 0, "cacheRead": 0, "cacheWrite": 0,
                                  "cost": ["total": 99]]],  // stored cost is ignored
        ]
        let line = String(data: try JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
        try write([line], to: "--p--/s.jsonl")
        // 1M input tokens at $0.7/M = $0.70, priced from the catalog
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data("""
        {"providers":{"anthropic":{"models":{"claude-sonnet-4-5":{"input":0.7,"output":0}}}}}
        """.utf8))
        let s = scanPi(since: dayStart, root: tmp, catalog: catalog)
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
