import Foundation
import Darwin

public struct RemoteMachine: Codable, Equatable {
    public let id: UUID
    public let host: String

    public init(host: String, id: UUID = UUID()) throws {
        // Accept SSH config aliases and user@host, never SSH flags or commands.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._@:%[]")
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw RemoteUsageError.message("Enter an SSH config alias or user@hostname. Configure ports and keys in ~/.ssh/config.")
        }
        self.id = id
        self.host = host
    }
}

enum RemoteUsageError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Mirrors only supported history files. Use from the serial scan queue, not the UI thread.
public final class RemoteUsageCache {
    public let root: URL
    public private(set) var lastUpdated: Date?
    private var stamps: [String: String] = [:]

    public init(machine: RemoteMachine, cacheDirectory: URL? = nil) throws {
        let fm = FileManager.default
        let base = cacheDirectory ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Bar/Remote Machines", isDirectory: true)
        root = base.appendingPathComponent(machine.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            stamps = saved.filter { Self.validPath($0.key) && fm.fileExists(atPath: root.appendingPathComponent($0.key).path) }
            lastUpdated = try? root.appendingPathComponent("manifest.json")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    public func sync(from machine: RemoteMachine) throws {
        // Validate decoded preferences too, since Codable does not call our initializer.
        _ = try RemoteMachine(host: machine.host)
        let command = "python3 -c '" + Self.collector.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let arguments = ["-T", "-C", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                         "-oConnectTimeout=10", "-oConnectionAttempts=1",
                         "-oServerAliveInterval=10", "-oServerAliveCountMax=2",
                         machine.host, command]
        let request = try JSONEncoder().encode(stamps)
        let output = root.appendingPathComponent("transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        try Self.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments,
                     input: request, output: output, timeout: 120)
        try applyTransfer(at: output)
        lastUpdated = Date()
    }

    public func scan(since start: Date, buckets: BucketSpec?) -> [SourceStats] {
        [scanClaudeCode(since: start, root: root.appendingPathComponent("claude"), buckets: buckets),
         scanCodex(since: start, root: root.appendingPathComponent("codex"), buckets: buckets),
         scanOpenCode(since: start, dbPath: root.appendingPathComponent("opencode.db"), buckets: buckets),
         scanPi(since: start, root: root.appendingPathComponent("pi"), buckets: buckets)]
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: root)
    }

    static func validPath(_ path: String) -> Bool {
        if path == "opencode.db" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && ["claude", "codex", "pi"].contains(String(parts[0]))
            && path.hasSuffix(".jsonl") && !path.contains("\\") && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private struct Record: Decodable {
        var path: String?
        var stamp: String?
        var mtime: Double?
        var content: String?
        var complete: Bool?
    }

    // JSONL keeps peak memory bounded to one history file rather than the entire archive.
    func applyTransfer(at output: URL) throws {
        let fm = FileManager.default
        let handle = try FileHandle(forReadingFrom: output)
        defer { try? handle.close() }
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var pending = Data()
        var next: [String: String] = [:]
        var changed: [String] = []
        var complete = false
        func apply(_ line: Data) throws {
            guard !complete else { throw RemoteUsageError.message("Unexpected data after the SSH snapshot.") }
            let record = try JSONDecoder().decode(Record.self, from: line)
            if record.complete == true {
                complete = true
                return
            }
            guard let path = record.path, Self.validPath(path), let stamp = record.stamp,
                  let mtime = record.mtime, mtime.isFinite, next[path] == nil else {
                throw RemoteUsageError.message("Invalid file in the SSH snapshot.")
            }
            let destination = root.appendingPathComponent(path)
            if let encoded = record.content {
                guard let data = Data(base64Encoded: encoded) else {
                    throw RemoteUsageError.message("Invalid file contents in the SSH snapshot.")
                }
                let staged = staging.appendingPathComponent(path)
                try fm.createDirectory(at: staged.deletingLastPathComponent(),
                                       withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: staged)
                try fm.setAttributes([.posixPermissions: 0o600,
                                      .modificationDate: Date(timeIntervalSince1970: mtime)],
                                     ofItemAtPath: staged.path)
                changed.append(path)
            } else if stamps[path] != stamp || !fm.fileExists(atPath: destination.path) {
                throw RemoteUsageError.message("The SSH snapshot is missing a history file. Try refreshing again.")
            }
            next[path] = stamp
        }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 10) {
                pending.append(chunk[start..<newline])
                try apply(pending)
                pending.removeAll(keepingCapacity: true)
                start = chunk.index(after: newline)
            }
            pending.append(chunk[start...])
        }
        guard pending.isEmpty, complete else {
            throw RemoteUsageError.message("The SSH snapshot was incomplete. Previous totals have been kept.")
        }
        // Do not publish changed files until the complete snapshot has been validated.
        for path in changed {
            let destination = root.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard rename(staging.appendingPathComponent(path).path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        for path in stamps.keys where next[path] == nil {
            let url = root.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        stamps = next
    }

    // File-backed I/O avoids pipe deadlocks with large histories or SSH diagnostics.
    static func run(executable: URL, arguments: [String], input: Data, output: URL,
                    timeout: TimeInterval) throws {
        let fm = FileManager.default
        let request = output.appendingPathExtension("request")
        let errors = output.appendingPathExtension("stderr")
        defer {
            try? fm.removeItem(at: request)
            try? fm.removeItem(at: errors)
        }
        try input.write(to: request, options: .atomic)
        fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdin = try FileHandle(forReadingFrom: request)
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            throw RemoteUsageError.message("SSH refresh timed out. Check the host and try again.")
        }
        guard process.terminationStatus == 0 else {
            let data = try Data(contentsOf: errors)
            let detail = String(decoding: data.prefix(2000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteUsageError.message(detail.isEmpty ? "SSH refresh failed." : detail)
        }
    }

    // Python's SQLite backup API includes committed WAL transactions. Copying only
    // opencode.db can silently miss the newest usage or produce an inconsistent DB.
    static let collector = #"""
    import base64, json, os, pathlib, sqlite3, sys, tempfile
    known = json.load(sys.stdin)
    home = pathlib.Path.home()
    def emit(path, stamp, mtime, data=None):
        row = {"path": path, "stamp": stamp, "mtime": mtime}
        if data is not None:
            row["content"] = base64.b64encode(data).decode("ascii")
        print(json.dumps(row), flush=True)
    def signature(path):
        stat = path.stat()
        return str(stat.st_mtime_ns) + ":" + str(stat.st_size)
    roots = [("claude", home / ".claude/projects"),
             ("codex", home / ".codex/sessions"),
             ("pi", home / ".pi/agent/sessions")]
    for prefix, root in roots:
        if not root.exists():
            continue
        def walk_error(error):
            raise error
        for directory, dirs, files in os.walk(str(root), onerror=walk_error):
            dirs[:] = [d for d in dirs if not pathlib.Path(directory, d).is_symlink()]
            for name in sorted(files):
                file = pathlib.Path(directory, name)
                if file.suffix != ".jsonl" or file.is_symlink():
                    continue
                path = prefix + "/" + file.relative_to(root).as_posix()
                try:
                    stamp = signature(file)
                    mtime = file.stat().st_mtime
                    data = file.read_bytes() if known.get(path) != stamp else None
                except FileNotFoundError:
                    continue
                emit(path, stamp, mtime, data)
    db = home / ".local/share/opencode/opencode.db"
    if db.is_file():
        wal = pathlib.Path(str(db) + "-wal")
        stamp = signature(db) + (":" + signature(wal) if wal.exists() else "")
        data = None
        if known.get("opencode.db") != stamp:
            with tempfile.TemporaryDirectory(prefix="token-bar-") as temp:
                snapshot = pathlib.Path(temp) / "snapshot.db"
                source = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=10)
                target = sqlite3.connect(str(snapshot))
                try:
                    source.backup(target)
                    target.execute("PRAGMA journal_mode=DELETE")
                finally:
                    target.close()
                    source.close()
                data = snapshot.read_bytes()
        emit("opencode.db", stamp, db.stat().st_mtime, data)
    print(json.dumps({"complete": True}), flush=True)
    """#
}
