import SQLite3
import XCTest
@testable import TokenBarCore

final class RemoteMachineTests: FixtureTestCase {
    func cache(_ machine: RemoteMachine? = nil) throws -> RemoteUsageCache {
        try RemoteUsageCache(machine: machine ?? RemoteMachine(host: "test-host"),
                             cacheDirectory: tmp.appendingPathComponent("cache"))
    }

    func collect(into cache: RemoteUsageCache) throws -> [[String: Any]] {
        let manifest = cache.root.appendingPathComponent("manifest.json")
        let known = (try? Data(contentsOf: manifest)) ?? Data("{}".utf8)
        let output = tmp.appendingPathComponent("transfer.jsonl")
        try RemoteUsageCache.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                 arguments: ["HOME=\(tmp.appendingPathComponent("home").path)",
                                             "python3", "-c", RemoteUsageCache.collector],
                                 input: known, output: output, timeout: 15)
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        let records = try lines.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        try cache.applyTransfer(at: output)
        return records
    }

    func transfer(_ records: [[String: Any]], into cache: RemoteUsageCache) throws {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        let output = tmp.appendingPathComponent("manual-transfer.jsonl")
        try data.write(to: output)
        try cache.applyTransfer(at: output)
    }

    func record(path: String, content: String? = "example", stamp: String = "1") -> [String: Any] {
        var record: [String: Any] = ["path": path, "stamp": stamp,
                                     "mtime": Date().timeIntervalSince1970]
        if let content { record["content"] = Data(content.utf8).base64EncodedString() }
        return record
    }

    func claudeEntry(input: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(inRange)","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":\(input),"output_tokens":10}}}
        """
    }

    func testAcceptsSSHConfigAliasesUsersAndIPv6() throws {
        for host in ["work-server", "user@mac.local", "user@192.168.1.2", "user@2001:db8::1", "[::1]"] {
            XCTAssertEqual(try RemoteMachine(host: host).host, host)
        }
        let machine = try RemoteMachine(host: "my-host")
        XCTAssertEqual(try JSONDecoder().decode(RemoteMachine.self, from: JSONEncoder().encode(machine)), machine)
    }

    func testRejectsOptionsShellCommandsAndWhitespace() {
        for host in ["", "-oProxyCommand=evil", "host;touch", "$(whoami)", "host name", "host\nname", "host/path", "host'", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try RemoteMachine(host: host), host)
        }
    }

    func testCollectorFeedsExistingScannerAndPreservesModificationDate() throws {
        let cache = try cache()
        let oldDate = Date().addingTimeInterval(-7200)
        try write([claudeEntry(input: 999)], to: "home/.claude/projects/p/old.jsonl", mtime: oldDate)
        try write([claudeEntry(input: 123)], to: "home/.claude/projects/p/current.jsonl")
        let records = try collect(into: cache)
        XCTAssertEqual(records.count, 3)
        let sources = cache.scan(since: dayStart, buckets: .hours(from: dayStart))
        XCTAssertEqual(sources.map(\.name), ["Claude Code", "Codex", "OpenCode", "pi"])
        XCTAssertEqual(sources[0].agg.input, 123)
        XCTAssertEqual(sources[0].agg.output, 10)
        XCTAssertEqual(sources[0].buckets.reduce(0, +), sources[0].agg.cost, accuracy: 1e-9)
        XCTAssertFalse(sources[1].available)
        let mirrored = cache.root.appendingPathComponent("claude/p/old.jsonl")
        let modified = try XCTUnwrap(mirrored.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertEqual(modified.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 0.001)
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
    }

    func testIncrementalRefreshUpdatesChangedFilesAndRemovesDeletedHistory() throws {
        let cache = try cache()
        try write([claudeEntry(input: 123)], to: "home/.claude/projects/p/session.jsonl")
        _ = try collect(into: cache)
        let unchanged = try collect(into: cache)
        XCTAssertNil(unchanged[0]["content"])
        try write([claudeEntry(input: 4567)], to: "home/.claude/projects/p/session.jsonl")
        let changed = try collect(into: cache)
        XCTAssertNotNil(changed[0]["content"])
        XCTAssertEqual(cache.scan(since: dayStart, buckets: nil)[0].agg.input, 4567)
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("home/.claude/projects/p/session.jsonl"))
        _ = try collect(into: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("claude/p/session.jsonl").path))
        XCTAssertEqual(cache.scan(since: dayStart, buckets: nil)[0].agg.input, 0)
    }

    func testSQLiteSnapshotIncludesCommittedWALAndUpdates() throws {
        let cache = try cache()
        let directory = tmp.appendingPathComponent("home/.local/share/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("opencode.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);", nil, nil, nil), SQLITE_OK)
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let json = #"{"role":"assistant","providerID":"openai","modelID":"gpt-5","tokens":{"input":200,"output":30}}"#
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES ('m1','s1',\(ms),'\(json)')", nil, nil, nil), SQLITE_OK)
        _ = try collect(into: cache)
        XCTAssertEqual(cache.scan(since: dayStart, buckets: nil)[2].agg.input, 200)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO message VALUES ('m2','s2',\(ms),'\(json)')", nil, nil, nil), SQLITE_OK)
        _ = try collect(into: cache)
        XCTAssertEqual(cache.scan(since: dayStart, buckets: nil)[2].agg.input, 400)
    }

    func testCacheIsolationPersistenceAndRemoval() throws {
        let machine = try RemoteMachine(host: "first")
        let first = try cache(machine)
        let second = try cache()
        try transfer([record(path: "claude/p/s.jsonl"), ["complete": true]], into: first)
        XCTAssertNotEqual(first.root, second.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.root.appendingPathComponent("claude/p/s.jsonl").path))
        let reloaded = try cache(machine)
        XCTAssertNotNil(reloaded.lastUpdated)
        try transfer([record(path: "claude/p/s.jsonl", content: nil), ["complete": true]], into: reloaded)
        try first.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.root.path))
    }

    func testRejectsTraversalAndUnexpectedFiles() throws {
        let cache = try cache()
        for path in ["../escape.jsonl", "/claude/a.jsonl", "claude/../escape.jsonl", "claude//a.jsonl", "claude/./a.jsonl", "claude/a\\b.jsonl", "claude/a.txt", "opencode.db-wal", "other/a.jsonl"] {
            XCTAssertThrowsError(try transfer([record(path: path), ["complete": true]], into: cache), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("escape.jsonl").path))
    }

    func testIncompleteTransferDoesNotPrunePreviousHistory() throws {
        let cache = try cache()
        try transfer([record(path: "claude/p/s.jsonl"), ["complete": true]], into: cache)
        let manifest = try Data(contentsOf: cache.root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try transfer([], into: cache))
        XCTAssertThrowsError(try transfer([record(path: "claude/p/s.jsonl", content: "changed", stamp: "2")], into: cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("claude/p/s.jsonl").path))
        XCTAssertEqual(try String(contentsOf: cache.root.appendingPathComponent("claude/p/s.jsonl")), "example")
        XCTAssertEqual(try Data(contentsOf: cache.root.appendingPathComponent("manifest.json")), manifest)
    }

    func testRejectsMissingUnchangedFileBadBase64AndDuplicateRecords() throws {
        let cache = try cache()
        XCTAssertThrowsError(try transfer([record(path: "pi/s.jsonl", content: nil), ["complete": true]], into: cache))
        var invalid = record(path: "pi/s.jsonl")
        invalid["content"] = "not base64!"
        XCTAssertThrowsError(try transfer([invalid, ["complete": true]], into: cache))
        let valid = record(path: "pi/s.jsonl")
        XCTAssertThrowsError(try transfer([valid, valid, ["complete": true]], into: cache))
    }

    func testCollectorSkipsSymlinksAndOtherFiles() throws {
        let cache = try cache()
        try write(["secret"], to: "outside/secret.jsonl")
        try write(["ignored"], to: "home/.claude/projects/p/notes.txt")
        let root = tmp.appendingPathComponent("home/.claude/projects")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"),
                                                   withDestinationURL: tmp.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("secret.jsonl"),
                                                   withDestinationURL: tmp.appendingPathComponent("outside/secret.jsonl"))
        XCTAssertEqual(try collect(into: cache).count, 1)
    }

    func testProcessTimeoutAndFailureAreReported() throws {
        let output = tmp.appendingPathComponent("output")
        let start = Date()
        XCTAssertThrowsError(try RemoteUsageCache.run(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], input: Data(), output: output, timeout: 0.05)) {
            XCTAssertTrue($0.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertThrowsError(try RemoteUsageCache.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'Permission denied' >&2; exit 255"],
            input: Data(), output: output, timeout: 5)) {
            XCTAssertTrue($0.localizedDescription.contains("Permission denied"))
        }
    }
}
