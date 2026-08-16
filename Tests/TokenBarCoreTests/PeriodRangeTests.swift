import XCTest
@testable import TokenBarCore

final class PeriodRangeTests: XCTestCase {
    private func calendar(timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = timeZone
        cal.firstWeekday = 2  // Monday
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0,
                      in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testCalendarRangesStartAtCalendarBoundaries() {
        let cal = calendar()
        let now = date(2025, 8, 16, hour: 12, in: cal)

        XCTAssertEqual(UsagePeriod.day.start(cal: cal, now: now, rangeStyle: .calendar),
                       date(2025, 8, 16, in: cal))
        XCTAssertEqual(UsagePeriod.week.start(cal: cal, now: now, rangeStyle: .calendar),
                       date(2025, 8, 11, in: cal))
        XCTAssertEqual(UsagePeriod.month.start(cal: cal, now: now, rangeStyle: .calendar),
                       date(2025, 8, 1, in: cal))
        XCTAssertEqual(UsagePeriod.year.start(cal: cal, now: now, rangeStyle: .calendar),
                       date(2025, 1, 1, in: cal))

        let monthStart = UsagePeriod.month.start(cal: cal, now: now, rangeStyle: .calendar)
        let monthSpec = UsagePeriod.month.bucketSpec(start: monthStart, cal: cal, now: now,
                                                     rangeStyle: .calendar)
        XCTAssertEqual(monthSpec.count, 31)
    }

    func testRelativeRangesCoverSevenDaysThirtyDaysAndTwelveMonths() {
        let cal = calendar()
        let now = date(2025, 8, 16, hour: 12, in: cal)

        let expected: [(UsagePeriod, Date, Int)] = [
            (.day, date(2025, 8, 16, in: cal), 24),
            (.week, date(2025, 8, 10, in: cal), 7),
            (.month, date(2025, 7, 18, in: cal), 30),
            (.year, date(2024, 9, 1, in: cal), 12),
        ]
        for (period, start, count) in expected {
            XCTAssertEqual(period.start(cal: cal, now: now, rangeStyle: .relative), start)
            XCTAssertEqual(period.bucketSpec(start: start, cal: cal, now: now,
                                             rangeStyle: .relative).count, count)
        }
    }

    func testRelativeBucketsIncludeEndpointsAndRejectOutsideDates() {
        let cal = calendar()
        let now = date(2025, 8, 16, hour: 12, in: cal)

        let weekStart = UsagePeriod.week.start(cal: cal, now: now, rangeStyle: .relative)
        let week = UsagePeriod.week.bucketSpec(start: weekStart, cal: cal, now: now,
                                                rangeStyle: .relative)
        XCTAssertEqual(week.index(weekStart), 0)
        XCTAssertEqual(week.index(date(2025, 8, 16, hour: 23, in: cal)), 6)
        XCTAssertNil(week.index(date(2025, 8, 9, hour: 23, in: cal)))
        XCTAssertNil(week.index(date(2025, 8, 17, in: cal)))

        let monthStart = UsagePeriod.month.start(cal: cal, now: now, rangeStyle: .relative)
        let month = UsagePeriod.month.bucketSpec(start: monthStart, cal: cal, now: now,
                                                  rangeStyle: .relative)
        XCTAssertEqual(month.index(date(2025, 8, 16, hour: 23, in: cal)), 29)
        XCTAssertNil(month.index(date(2025, 8, 17, in: cal)))

        let yearStart = UsagePeriod.year.start(cal: cal, now: now, rangeStyle: .relative)
        let year = UsagePeriod.year.bucketSpec(start: yearStart, cal: cal, now: now,
                                                rangeStyle: .relative)
        XCTAssertEqual(year.index(date(2025, 8, 31, hour: 23, in: cal)), 11)
        XCTAssertNil(year.index(date(2025, 9, 1, in: cal)))
    }

    func testRelativeDayArithmeticStaysAtMidnightAcrossDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let cal = calendar(timeZone: zone)
        let now = date(2025, 3, 12, hour: 12, in: cal)
        let start = UsagePeriod.week.start(cal: cal, now: now, rangeStyle: .relative)

        XCTAssertEqual(start, date(2025, 3, 6, in: cal))
        let spec = UsagePeriod.week.bucketSpec(start: start, cal: cal, now: now,
                                               rangeStyle: .relative)
        XCTAssertEqual(spec.index(now), 6)
    }
}
