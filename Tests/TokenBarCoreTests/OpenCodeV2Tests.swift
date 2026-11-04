import SQLite3
import XCTest
@testable import TokenBarCore

final class OpenCodeV2Tests: FixtureTestCase {
    var dbURL: URL { tmp.appendingPathComponent("opencode.db") }

    func execute(_ sql: String, values: [String] = []) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func makeDB() throws {
        try execute("""
            CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text,
                directory text, title text, fork_session_id text, time_created integer)
            """)
        try execute("""
            CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL,
                type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL,
                time_updated integer NOT NULL, data text NOT NULL)
            """)
        try execute("INSERT INTO session_v2 VALUES ('main', NULL, NULL, 'V2 session', NULL, 0)")
    }

    func assistant(input: Int = 100, output: Int = 20, reasoning: Int = 3,
                   cacheRead: Int = 40, cacheWrite: Int = 5) -> [String: Any] {
        // V2 stores the discriminator in SQL and model identity in a nested object.
        ["model": ["providerID": "OpenAI", "id": "gpt-test", "variant": "high"],
         "cost": 999, "tokens": ["input": input, "output": output, "reasoning": reasoning,
                                  "cache": ["read": cacheRead, "write": cacheWrite]]]
    }

    func insert(_ data: [String: Any], type: String = "assistant",
                session: String = "main", date: Date? = nil) throws {
        let ms = Int64((date ?? dayStart.addingTimeInterval(10)).timeIntervalSince1970 * 1000)
        let json = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        try execute("INSERT INTO session_message VALUES (?, ?, ?, 0, \(ms), \(ms), ?)",
                    values: [UUID().uuidString, session, type, json])
    }

    func testV2OnlyDatabaseRepricesTokensAndFillsBuckets() throws {
        try makeDB()
        try insert(assistant(input: 1_000_000, output: 1_000_000, reasoning: 1_000_000,
                             cacheRead: 1_000_000, cacheWrite: 1_000_000))
        let catalog = try JSONDecoder().decode(PricingCatalog.self, from: Data("""
            {"providers":{"openai":{"models":{"gpt-test":{"input":1,"output":2,"reasoning":3,"cache_read":0.1,"cache_write":1.25}}}}}
            """.utf8))
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: catalog)
        XCTAssertTrue(stats.available)
        XCTAssertEqual(stats.agg.input, 1_000_000)
        XCTAssertEqual(stats.agg.output, 2_000_000)
        XCTAssertEqual(stats.agg.cacheRead, 1_000_000)
        XCTAssertEqual(stats.agg.cacheWrite, 1_000_000)
        XCTAssertEqual(stats.agg.cost, 7.35, accuracy: 1e-9)
        XCTAssertEqual(stats.buckets[0], 7.35, accuracy: 1e-9)
        XCTAssertEqual(Set(stats.perModel.keys), ["openai/gpt-test"])
        XCTAssertTrue(stats.unknownPricing.isEmpty)
        XCTAssertEqual(stats.sessions["main"]?.title, "V2 session")
        XCTAssertEqual(try XCTUnwrap(stats.dataSince).timeIntervalSince1970,
                       dayStart.addingTimeInterval(10).timeIntervalSince1970, accuracy: 0.001)
    }

    func testV2FiltersTypesOldRowsAndMissingTokens() throws {
        try makeDB()
        try insert(assistant(input: 999), type: "user")
        try insert(assistant(input: 999), type: "system")
        try insert(assistant(input: 999), date: dayStart.addingTimeInterval(-1))
        try insert(["model": ["providerID": "openai", "id": "gpt-test"]])
        try insert(assistant(input: 7))
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(stats.agg.input, 7)
        XCTAssertEqual(stats.agg.output, 23)
        XCTAssertEqual(stats.agg.cost, 0)
        XCTAssertEqual(stats.unknownPricing, ["openai/gpt-test"])
    }

    func testCombinesV1AndV2HistoryWithSeparateAttribution() throws {
        try makeDB()
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try execute("CREATE TABLE project (id text PRIMARY KEY, worktree text)")
        try execute("INSERT INTO project VALUES ('project', ?)", values: [repo.path])
        try execute("UPDATE session_v2 SET project_id = 'project', directory = ?",
                    values: [repo.appendingPathComponent("deleted-subdir").path])
        try execute("CREATE TABLE session (id text PRIMARY KEY, directory text, title text)")
        try execute("INSERT INTO session VALUES ('legacy', ?, 'V1 session')", values: [repo.path])
        try execute("CREATE TABLE message (id text PRIMARY KEY, session_id text, time_created integer, data text)")
        let legacy = """
            {"role":"assistant","providerID":"openai","modelID":"gpt-test","tokens":{"input":11,"output":2}}
            """
        let ms = Int64(dayStart.addingTimeInterval(5).timeIntervalSince1970 * 1000)
        try execute("INSERT INTO message VALUES ('old', 'legacy', \(ms), ?)", values: [legacy])
        try insert(assistant(input: 7))
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(stats.agg.input, 18)
        XCTAssertEqual(stats.agg.output, 25)
        XCTAssertEqual(stats.sessions.count, 2)
        XCTAssertEqual(stats.sessions["legacy"]?.title, "V1 session")
        XCTAssertEqual(stats.sessions["main"]?.title, "V2 session")
        XCTAssertEqual(stats.sessions["main"]?.projectPath, repo.path)
        XCTAssertEqual(stats.sessions["legacy"]?.projectPath, repo.path)
        XCTAssertEqual(try XCTUnwrap(stats.dataSince).timeIntervalSince1970,
                       Double(ms) / 1000, accuracy: 0.001)
    }

    func testForkSkipsCopiedHistoryButCountsNewUsageAtBoundary() throws {
        try makeDB()
        let forkDate = dayStart.addingTimeInterval(20)
        let ms = Int64(forkDate.timeIntervalSince1970 * 1000)
        try execute("INSERT INTO session_v2 VALUES ('fork', NULL, NULL, 'Fork', 'main', \(ms))")
        try insert(assistant(input: 100))
        try insert(assistant(input: 100), session: "fork")
        try insert(assistant(input: 5), session: "fork", date: forkDate)
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(stats.agg.input, 105)
        XCTAssertEqual(stats.sessions["fork"]?.agg.input, 5)
        XCTAssertEqual(stats.sessions["main"]?.agg.input, 100)
    }

    func testCompactionIncludesRecordedUsageWithoutCountingOtherEvents() throws {
        try makeDB()
        var completed = assistant(input: 8)
        completed["status"] = "completed"
        try insert(completed, type: "compaction")
        try insert(["status": "failed", "tokens": ["input": 2]], type: "compaction")
        try insert(["status": "running"], type: "compaction")
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(stats.agg.input, 10)
        XCTAssertEqual(stats.perModel["openai/gpt-test"]?.input, 8)
        XCTAssertEqual(stats.perModel["unknown/unknown"]?.input, 2)
    }

    func testMigratedSessionsUseV2WithoutDoubleCountingRetainedV1Rows() throws {
        try makeDB()
        try execute("CREATE TABLE message (id text PRIMARY KEY, session_id text, time_created integer, data text)")
        let legacy = """
            {"role":"assistant","providerID":"openai","modelID":"gpt-test","tokens":{"input":100}}
            """
        let ms = Int64(dayStart.addingTimeInterval(10).timeIntervalSince1970 * 1000)
        try execute("INSERT INTO message VALUES ('old-summary', 'main', \(ms), ?)", values: [legacy])
        try execute("INSERT INTO message VALUES ('unmigrated', 'legacy', \(ms), ?)", values: [legacy])
        // Migration can fold a V1 summary into a V2 compaction with a different ID.
        var migrated = assistant(input: 100, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0)
        migrated["status"] = "completed"
        try insert(migrated, type: "compaction")
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertEqual(stats.agg.input, 200)
        XCTAssertEqual(stats.sessions["main"]?.agg.input, 100)
        XCTAssertEqual(stats.sessions["legacy"]?.agg.input, 100)
    }

    func testV1WithPlaceholderMessageTableStillReadsLegacyUsage() throws {
        try makeDB()
        try execute("DROP TABLE session_v2")
        try execute("CREATE TABLE session (id text PRIMARY KEY, directory text, title text)")
        try execute("INSERT INTO session VALUES ('legacy', ?, 'V1 session')", values: [tmp.path])
        try execute("CREATE TABLE message (id text PRIMARY KEY, session_id text, time_created integer, data text)")
        let legacy = """
            {"role":"assistant","providerID":"openai","modelID":"gpt-test","tokens":{"input":1000,"output":300,"reasoning":45,"cache":{"read":234}}}
            """
        let ms = Int64(dayStart.addingTimeInterval(10).timeIntervalSince1970 * 1000)
        try execute("INSERT INTO message VALUES ('old', 'legacy', \(ms), ?)", values: [legacy])
        // OpenCode 1.19.3 has session_message, but no session_v2 or V2 usage.
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL, catalog: nil)
        XCTAssertTrue(stats.available)
        XCTAssertEqual(stats.perModel["openai/gpt-test"]?.input, 1000)
        XCTAssertEqual(stats.agg.output, 345)
        XCTAssertEqual(stats.agg.cacheRead, 234)
        XCTAssertEqual(stats.sessions["legacy"]?.title, "V1 session")
    }

    func testEmptyV2DatabaseHasNoDataSince() throws {
        try makeDB()
        let stats = scanOpenCode(since: dayStart, dbPath: dbURL)
        XCTAssertTrue(stats.available)
        XCTAssertEqual(stats.agg.input, 0)
        XCTAssertNil(stats.dataSince)
    }
}
