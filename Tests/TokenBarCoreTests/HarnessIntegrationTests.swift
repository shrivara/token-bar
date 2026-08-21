import XCTest
@testable import TokenBarCore

private func integrationURL(runVariable: String, pathVariable: String,
                            isDirectory: Bool = true) throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    guard environment[runVariable] == "1" else {
        throw XCTSkip("Run with Scripts/test-harness-integration.sh")
    }
    let path = try XCTUnwrap(environment[pathVariable])
    return URL(fileURLWithPath: path, isDirectory: isDirectory)
}

final class ClaudeCodeIntegrationTests: XCTestCase {
    func testScansSessionGeneratedByCurrentClaudeCodeCLI() throws {
        let root = try integrationURL(runVariable: "RUN_CLAUDE_CODE_INTEGRATION",
                                      pathVariable: "CLAUDE_CODE_INTEGRATION_PROJECTS")
        let stats = scanClaudeCode(since: Date().addingTimeInterval(-3600),
                                   root: root, catalog: nil)
        let model = try XCTUnwrap(stats.perModel["claude-token-bar-integration"])

        XCTAssertTrue(stats.available)
        XCTAssertEqual(stats.perModel.count, 1)
        XCTAssertEqual(model.input, 1_000, accuracy: 1e-9)
        XCTAssertEqual(model.cacheRead, 234, accuracy: 1e-9)
        XCTAssertEqual(model.cacheWrite, 111, accuracy: 1e-9)
        XCTAssertEqual(model.output, 345, accuracy: 1e-9)
        XCTAssertEqual(stats.agg, model)
    }
}

final class CodexIntegrationTests: XCTestCase {
    func testScansSessionGeneratedByCurrentCodexCLI() throws {
        let root = try integrationURL(runVariable: "RUN_CODEX_INTEGRATION",
                                      pathVariable: "CODEX_INTEGRATION_SESSIONS")
        let stats = scanCodex(since: Date().addingTimeInterval(-3600),
                              root: root, catalog: nil)
        let model = try XCTUnwrap(stats.perModel["openai/gpt-token-bar-integration"])

        XCTAssertTrue(stats.available)
        XCTAssertEqual(stats.perModel.count, 1)
        // Codex reports cache reads/writes as slices of its 1,234 input tokens.
        XCTAssertEqual(model.input, 889, accuracy: 1e-9)
        XCTAssertEqual(model.cacheRead, 234, accuracy: 1e-9)
        XCTAssertEqual(model.cacheWrite, 111, accuracy: 1e-9)
        // Codex's output count includes 45 reasoning tokens.
        XCTAssertEqual(model.output, 345, accuracy: 1e-9)
        XCTAssertEqual(stats.agg, model)
    }
}

final class OpenCodeIntegrationTests: XCTestCase {
    func testScansDatabaseGeneratedByCurrentOpenCodeCLI() throws {
        let db = try integrationURL(runVariable: "RUN_OPENCODE_INTEGRATION",
                                    pathVariable: "OPENCODE_INTEGRATION_DB",
                                    isDirectory: false)
        let stats = scanOpenCode(since: Date().addingTimeInterval(-3600),
                                 dbPath: db, catalog: nil)
        let model = try XCTUnwrap(stats.perModel["token-bar-mock/gpt-token-bar-integration"])

        XCTAssertTrue(stats.available)
        XCTAssertEqual(stats.perModel.count, 1)
        XCTAssertEqual(model.input, 1_000, accuracy: 1e-9)
        XCTAssertEqual(model.cacheRead, 234, accuracy: 1e-9)
        XCTAssertEqual(model.cacheWrite, 0, accuracy: 1e-9)
        XCTAssertEqual(model.output, 345, accuracy: 1e-9)
        XCTAssertEqual(stats.agg, model)
    }
}

final class PiIntegrationTests: XCTestCase {
    func testScansSessionGeneratedByCurrentPiCLI() throws {
        let root = try integrationURL(runVariable: "RUN_PI_INTEGRATION",
                                      pathVariable: "PI_INTEGRATION_SESSIONS")
        let stats = scanPi(since: Date().addingTimeInterval(-3600),
                           root: root, catalog: nil)
        let model = try XCTUnwrap(stats.perModel["token-bar-mock/gpt-token-bar-integration"])

        XCTAssertTrue(stats.available)
        XCTAssertEqual(stats.perModel.count, 1)
        XCTAssertEqual(model.input, 1_000, accuracy: 1e-9)
        XCTAssertEqual(model.cacheRead, 234, accuracy: 1e-9)
        XCTAssertEqual(model.cacheWrite, 0, accuracy: 1e-9)
        XCTAssertEqual(model.output, 345, accuracy: 1e-9)
        XCTAssertEqual(stats.agg, model)
    }
}
