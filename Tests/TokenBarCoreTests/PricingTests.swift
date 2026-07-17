import XCTest
@testable import TokenBarCore

final class PricingTests: XCTestCase {
    func testBundledCatalogResolvesExactClaudeModels() {
        XCTAssertEqual(claudeRates(for: "claude-fable-5"), Rates(inPerM: 10, outPerM: 50))
        XCTAssertEqual(claudeRates(for: "claude-opus-4-6"), Rates(inPerM: 5, outPerM: 25))
        XCTAssertEqual(claudeRates(for: "claude-sonnet-4-6"),
                       Rates(inPerM: 3, outPerM: 15, cacheReadPerM: 0.3, cacheWritePerM: 3.75))
        XCTAssertEqual(claudeRates(for: "claude-haiku-4-5-20251001"), Rates(inPerM: 1, outPerM: 5))
    }

    func testUnknownModelsReturnNil() {
        XCTAssertNil(claudeRates(for: "gpt-5"))
        XCTAssertNil(claudeRates(for: "claude-zeta-7"))
        XCTAssertNil(claudeRates(for: ""))
    }

    func testCostMathUsesExplicitCacheRates() {
        // 1M of each bucket at fable rates:
        // input 10 + output 50 + cacheRead 1 + each cache write 12.5
        let a = Agg(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                    cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        let cost = claudeCost(a, Rates(inPerM: 10, outPerM: 50, cacheReadPerM: 1, cacheWritePerM: 12.5))
        XCTAssertEqual(cost, 10 + 50 + 1 + 12.5 + 12.5, accuracy: 1e-9)
    }

    func testZeroUsageCostsNothing() {
        XCTAssertEqual(claudeCost(Agg(), Rates(inPerM: 10, outPerM: 50)), 0)
    }
}

final class AggTests: XCTestCase {
    func testHitRate() {
        let a = Agg(input: 100, cacheRead: 800, cacheWrite5m: 50, cacheWrite1h: 50)
        XCTAssertEqual(a.hitRate, 0.8, accuracy: 1e-9)
    }

    func testHitRateZeroDenominator() {
        XCTAssertEqual(Agg().hitRate, 0)
        XCTAssertEqual(Agg(output: 500).hitRate, 0)  // output doesn't count toward context
    }

    func testAddSumsEveryField() {
        var a = Agg(input: 1, output: 2, cacheRead: 3, cacheWrite5m: 4, cacheWrite1h: 5, cost: 6)
        a.add(Agg(input: 10, output: 20, cacheRead: 30, cacheWrite5m: 40, cacheWrite1h: 50, cost: 60))
        XCTAssertEqual(a, Agg(input: 11, output: 22, cacheRead: 33, cacheWrite5m: 44, cacheWrite1h: 55, cost: 66))
    }

    func testBarValuesLerp() {
        let a = BarValues(cost: 0, input: 100, output: 0, hit: 0.5)
        let b = BarValues(cost: 10, input: 200, output: 50, hit: 1.0)
        XCTAssertEqual(BarValues.lerp(a, b, 0), a)
        XCTAssertEqual(BarValues.lerp(a, b, 1), b)
        let mid = BarValues.lerp(a, b, 0.5)
        XCTAssertEqual(mid.cost, 5, accuracy: 1e-9)
        XCTAssertEqual(mid.input, 150, accuracy: 1e-9)
        XCTAssertEqual(mid.hit, 0.75, accuracy: 1e-9)
    }
}

final class FormattingTests: XCTestCase {
    func testTokenFormattingBoundaries() {
        XCTAssertEqual(fmtTokens(0), "0")
        XCTAssertEqual(fmtTokens(999), "999")
        XCTAssertEqual(fmtTokens(1_000), "1.0K")
        XCTAssertEqual(fmtTokens(48_300), "48.3K")
        XCTAssertEqual(fmtTokens(100_000), "100K")
        XCTAssertEqual(fmtTokens(250_400), "250K")
        XCTAssertEqual(fmtTokens(1_000_000), "1.0M")
        XCTAssertEqual(fmtTokens(2_560_000), "2.6M")
        XCTAssertEqual(fmtTokens(10_000_000), "10M")
        XCTAssertEqual(fmtTokens(19_483_884), "19M")
    }

    func testMoneyFormatting() {
        XCTAssertEqual(fmtMoney(0), "$0.00")
        XCTAssertEqual(fmtMoney(4.821), "$4.82")
        XCTAssertEqual(fmtMoney(89.199), "$89.20")
        XCTAssertEqual(fmtMoney(1234.5), "$1234.50")
    }
}
