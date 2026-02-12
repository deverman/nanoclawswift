import Foundation
import Testing

@testable import CronEngineKit

private func makeISOFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

private func isoDate(_ text: String) -> Date {
    let formatter = makeISOFormatter()
    guard let date = formatter.date(from: text) else {
        preconditionFailure("Invalid test ISO8601 date: \(text)")
    }
    return date
}

private func isoString(_ date: Date) -> String {
    makeISOFormatter().string(from: date)
}

@Test
func testDailyCronNextRunUTC() throws {
    let engine = VixieCronEngine()
    let tz = TimeZone(secondsFromGMT: 0)!

    let nextSameDay = try engine.nextDate(
        after: isoDate("2026-02-12T07:59:00Z"),
        expression: "0 8 * * *",
        timeZone: tz
    )
    #expect(isoString(nextSameDay) == "2026-02-12T08:00:00Z")

    let nextFollowingDay = try engine.nextDate(
        after: isoDate("2026-02-12T08:00:00Z"),
        expression: "0 8 * * *",
        timeZone: tz
    )
    #expect(isoString(nextFollowingDay) == "2026-02-13T08:00:00Z")
}

@Test
func testStepRangeAndNamedWeekdays() throws {
    let engine = VixieCronEngine()
    let tz = TimeZone(secondsFromGMT: 0)!

    let next = try engine.nextDate(
        after: isoDate("2026-02-12T09:07:00Z"),
        expression: "*/15 9-17 * * MON-FRI",
        timeZone: tz
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tz
    let parts = calendar.dateComponents([.hour, .minute, .weekday], from: next)
    #expect(parts.hour.map({ 9...17 ~= $0 }) == true)
    #expect(parts.minute.map({ $0 % 15 == 0 }) == true)
    #expect(parts.weekday.map({ 2...6 ~= $0 }) == true) // Foundation Monday=2 ... Friday=6
}

@Test
func testLeapDayExpression() throws {
    let engine = VixieCronEngine(maxSearchYears: 10)
    let tz = TimeZone(secondsFromGMT: 0)!

    let next = try engine.nextDate(
        after: isoDate("2025-03-01T00:00:00Z"),
        expression: "0 0 29 FEB *",
        timeZone: tz
    )

    #expect(isoString(next) == "2028-02-29T00:00:00Z")
}

@Test
func testDayOfMonthDayOfWeekOrSemantics() throws {
    let engine = VixieCronEngine()
    let tz = TimeZone(secondsFromGMT: 0)!
    let start = isoDate("2026-02-01T00:00:00Z")

    let next = try engine.nextDate(
        after: start,
        expression: "0 9 13 * FRI",
        timeZone: tz
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tz
    let parts = calendar.dateComponents([.day, .weekday, .hour, .minute], from: next)
    let isThirteenth = parts.day == 13
    let isFriday = parts.weekday == 6 // Foundation Friday=6
    #expect(isThirteenth || isFriday)
    #expect(parts.hour == 9)
    #expect(parts.minute == 0)
}

@Test
func testQuestionMarkSupportInDayFields() throws {
    let engine = VixieCronEngine()
    let tz = TimeZone(secondsFromGMT: 0)!

    let next = try engine.nextDate(
        after: isoDate("2026-02-12T09:30:00Z"),
        expression: "0 8 ? * MON",
        timeZone: tz
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tz
    let parts = calendar.dateComponents([.weekday, .hour, .minute], from: next)
    #expect(parts.weekday == 2) // Monday
    #expect(parts.hour == 8)
    #expect(parts.minute == 0)
}

@Test
func testUnsupportedQuartzTokensRejected() {
    let engine = VixieCronEngine()
    let tz = TimeZone(secondsFromGMT: 0)!

    var didThrow = false
    do {
        _ = try engine.nextDate(
            after: isoDate("2026-02-12T00:00:00Z"),
            expression: "0 0 L * *",
            timeZone: tz
        )
    } catch {
        didThrow = true
    }

    #expect(didThrow == true)
}
