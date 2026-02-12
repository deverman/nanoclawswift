import Foundation

public protocol CronEngine: Sendable {
    func validate(expression: String) throws
    func nextDate(after date: Date, expression: String, timeZone: TimeZone) throws -> Date
}

public enum CronEngineError: Error, LocalizedError, Sendable {
    case invalidExpression(String)
    case noFutureDateFound(expression: String, yearsSearched: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidExpression(reason):
            return "Invalid cron expression: \(reason)"
        case let .noFutureDateFound(expression, yearsSearched):
            return "No future date found for \"\(expression)\" within \(yearsSearched) years"
        }
    }
}

public struct VixieCronEngine: CronEngine {
    public let maxSearchYears: Int

    public init(maxSearchYears: Int = 10) {
        self.maxSearchYears = max(1, maxSearchYears)
    }

    public func validate(expression: String) throws {
        _ = try CronSchedule(expression: expression)
    }

    public func nextDate(after date: Date, expression: String, timeZone: TimeZone = .current) throws -> Date {
        let schedule = try CronSchedule(expression: expression)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone

        guard let deadline = calendar.date(byAdding: .year, value: maxSearchYears, to: date),
              var cursor = roundUpToNextMinute(after: date, calendar: calendar) else {
            throw CronEngineError.invalidExpression("Could not initialize schedule cursor")
        }

        while cursor <= deadline {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: cursor)
            guard let year = parts.year,
                  let month = parts.month,
                  let day = parts.day,
                  let hour = parts.hour,
                  let minute = parts.minute,
                  let weekdayRaw = parts.weekday else {
                cursor = calendar.date(byAdding: .minute, value: 1, to: cursor) ?? cursor.addingTimeInterval(60)
                continue
            }

            if !schedule.month.contains(month) {
                cursor = advanceToNextAllowedMonth(
                    from: cursor,
                    year: year,
                    month: month,
                    schedule: schedule,
                    calendar: calendar
                )
                continue
            }

            let weekday = normalizeWeekday(weekdayRaw)
            if !schedule.matchesDay(day: day, weekday: weekday) {
                cursor = startOfNextDay(from: cursor, calendar: calendar)
                continue
            }

            if !schedule.hour.contains(hour) {
                cursor = advanceToNextAllowedHour(
                    from: cursor,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    schedule: schedule,
                    calendar: calendar
                )
                continue
            }

            if !schedule.minute.contains(minute) {
                cursor = advanceToNextAllowedMinute(
                    from: cursor,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute,
                    schedule: schedule,
                    calendar: calendar
                )
                continue
            }

            return cursor
        }

        throw CronEngineError.noFutureDateFound(expression: expression, yearsSearched: maxSearchYears)
    }
}

private struct CronSchedule: Sendable {
    let minute: FieldConstraint
    let hour: FieldConstraint
    let dayOfMonth: FieldConstraint
    let month: FieldConstraint
    let dayOfWeek: FieldConstraint
    let dayOfMonthIsWildcard: Bool
    let dayOfWeekIsWildcard: Bool

    init(expression: String) throws {
        let normalizedExpression = try Self.normalizeExpression(expression)
        let tokens = normalizedExpression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count == 5 else {
            throw CronEngineError.invalidExpression(
                "expected 5 fields (minute hour day-of-month month day-of-week), got \(tokens.count)"
            )
        }

        let minuteSpec = FieldSpec.minute
        let hourSpec = FieldSpec.hour
        let dayOfMonthSpec = FieldSpec.dayOfMonth
        let monthSpec = FieldSpec.month
        let dayOfWeekSpec = FieldSpec.dayOfWeek

        minute = try parseField(tokens[0], spec: minuteSpec)
        hour = try parseField(tokens[1], spec: hourSpec)
        dayOfMonth = try parseField(tokens[2], spec: dayOfMonthSpec)
        month = try parseField(tokens[3], spec: monthSpec)
        dayOfWeek = try parseField(tokens[4], spec: dayOfWeekSpec)
        dayOfMonthIsWildcard = isWildcardToken(tokens[2], supportsQuestionMark: true)
        dayOfWeekIsWildcard = isWildcardToken(tokens[4], supportsQuestionMark: true)
    }

    func matchesDay(day: Int, weekday: Int) -> Bool {
        let domMatch = dayOfMonth.contains(day)
        let dowMatch = dayOfWeek.contains(weekday)

        if dayOfMonthIsWildcard && dayOfWeekIsWildcard {
            return true
        }
        if dayOfMonthIsWildcard {
            return dowMatch
        }
        if dayOfWeekIsWildcard {
            return domMatch
        }
        return domMatch || dowMatch
    }

    private static func normalizeExpression(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CronEngineError.invalidExpression("empty expression")
        }

        let macros: [String: String] = [
            "@yearly": "0 0 1 1 *",
            "@annually": "0 0 1 1 *",
            "@monthly": "0 0 1 * *",
            "@weekly": "0 0 * * 0",
            "@daily": "0 0 * * *",
            "@midnight": "0 0 * * *",
            "@hourly": "0 * * * *"
        ]

        if trimmed.hasPrefix("@") {
            let key = trimmed.lowercased()
            guard let expanded = macros[key] else {
                throw CronEngineError.invalidExpression("unsupported macro \(trimmed)")
            }
            return expanded
        }
        return trimmed
    }
}

private struct FieldConstraint: Sendable {
    let values: [Int]
    private let valueSet: Set<Int>

    init(values: Set<Int>) throws {
        guard !values.isEmpty else {
            throw CronEngineError.invalidExpression("field resolved to empty value set")
        }
        self.values = values.sorted()
        self.valueSet = values
    }

    var first: Int { values[0] }

    func contains(_ value: Int) -> Bool {
        valueSet.contains(value)
    }

    func nextOrSame(after value: Int) -> Int? {
        values.first(where: { $0 >= value })
    }
}

private struct FieldSpec: Sendable {
    let label: String
    let min: Int
    let max: Int
    let names: [String: Int]
    let supportsQuestionMark: Bool
    let isDayOfWeek: Bool

    static let minute = FieldSpec(
        label: "minute",
        min: 0,
        max: 59,
        names: [:],
        supportsQuestionMark: false,
        isDayOfWeek: false
    )

    static let hour = FieldSpec(
        label: "hour",
        min: 0,
        max: 23,
        names: [:],
        supportsQuestionMark: false,
        isDayOfWeek: false
    )

    static let dayOfMonth = FieldSpec(
        label: "day-of-month",
        min: 1,
        max: 31,
        names: [:],
        supportsQuestionMark: true,
        isDayOfWeek: false
    )

    static let month = FieldSpec(
        label: "month",
        min: 1,
        max: 12,
        names: [
            "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
            "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12
        ],
        supportsQuestionMark: false,
        isDayOfWeek: false
    )

    static let dayOfWeek = FieldSpec(
        label: "day-of-week",
        min: 0,
        max: 6,
        names: [
            "SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6
        ],
        supportsQuestionMark: true,
        isDayOfWeek: true
    )
}

private func isWildcardToken(_ token: String, supportsQuestionMark: Bool) -> Bool {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "*" {
        return true
    }
    return supportsQuestionMark && trimmed == "?"
}

private func parseField(_ token: String, spec: FieldSpec) throws -> FieldConstraint {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if trimmed.isEmpty {
        throw CronEngineError.invalidExpression("empty \(spec.label) field")
    }

    if isWildcardToken(trimmed, supportsQuestionMark: spec.supportsQuestionMark) {
        return try FieldConstraint(values: Set(spec.min...spec.max))
    }

    let rawParts = trimmed.split(separator: ",").map(String.init)
    guard !rawParts.isEmpty else {
        throw CronEngineError.invalidExpression("invalid \(spec.label) field")
    }

    var values = Set<Int>()
    for rawPart in rawParts {
        try values.formUnion(parsePart(rawPart, spec: spec))
    }
    return try FieldConstraint(values: values)
}

private func parsePart(_ token: String, spec: FieldSpec) throws -> Set<Int> {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if trimmed.isEmpty {
        throw CronEngineError.invalidExpression("empty token in \(spec.label)")
    }

    if trimmed.contains("L") || trimmed.contains("W") || trimmed.contains("#") {
        throw CronEngineError.invalidExpression("unsupported token \"\(trimmed)\" in \(spec.label)")
    }

    if isWildcardToken(trimmed, supportsQuestionMark: spec.supportsQuestionMark) {
        return Set(spec.min...spec.max)
    }

    if trimmed.contains("/") {
        let split = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard split.count == 2 else {
            throw CronEngineError.invalidExpression("invalid step token \"\(trimmed)\" in \(spec.label)")
        }
        let base = split[0]
        guard let step = Int(split[1]), step > 0 else {
            throw CronEngineError.invalidExpression("invalid step value in \(spec.label): \(split[1])")
        }

        let bounds: (Int, Int)
        if isWildcardToken(base, supportsQuestionMark: spec.supportsQuestionMark) {
            bounds = (spec.min, spec.max)
        } else if base.contains("-") {
            bounds = try parseRange(base, spec: spec)
        } else {
            let start = try parseSingleValue(base, spec: spec)
            bounds = (start, spec.max)
        }

        var values = Set<Int>()
        var current = bounds.0
        while current <= bounds.1 {
            values.insert(normalizeValue(current, spec: spec))
            current += step
        }
        return values
    }

    if trimmed.contains("-") {
        let (start, end) = try parseRange(trimmed, spec: spec)
        return Set((start...end).map { normalizeValue($0, spec: spec) })
    }

    let value = try parseSingleValue(trimmed, spec: spec)
    return [normalizeValue(value, spec: spec)]
}

private func parseRange(_ token: String, spec: FieldSpec) throws -> (Int, Int) {
    let split = token.split(separator: "-", maxSplits: 1).map(String.init)
    guard split.count == 2 else {
        throw CronEngineError.invalidExpression("invalid range token \"\(token)\" in \(spec.label)")
    }
    let start = try parseSingleValue(split[0], spec: spec)
    let end = try parseSingleValue(split[1], spec: spec)
    guard start <= end else {
        throw CronEngineError.invalidExpression("range start must be <= end in \(spec.label): \(token)")
    }
    return (start, end)
}

private func parseSingleValue(_ token: String, spec: FieldSpec) throws -> Int {
    let upper = token.uppercased()
    let parsed: Int
    if let mapped = spec.names[upper] {
        parsed = mapped
    } else if let intValue = Int(upper) {
        parsed = intValue
    } else {
        throw CronEngineError.invalidExpression("invalid value \"\(token)\" in \(spec.label)")
    }

    if spec.isDayOfWeek && parsed == 7 {
        return 0
    }
    guard parsed >= spec.min && parsed <= spec.max else {
        throw CronEngineError.invalidExpression("value \(parsed) out of bounds for \(spec.label) (\(spec.min)-\(spec.max))")
    }
    return parsed
}

private func normalizeValue(_ value: Int, spec: FieldSpec) -> Int {
    if spec.isDayOfWeek, value == 7 {
        return 0
    }
    return value
}

private func roundUpToNextMinute(after date: Date, calendar: Calendar) -> Date? {
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.second = 0
    components.nanosecond = 0
    guard var candidate = calendar.date(from: components) else {
        return nil
    }
    if candidate <= date {
        candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate.addingTimeInterval(60)
    }
    return candidate
}

private func normalizeWeekday(_ calendarWeekday: Int) -> Int {
    // Foundation: Sunday=1 ... Saturday=7
    // Cron: Sunday=0 ... Saturday=6
    (calendarWeekday + 6) % 7
}

private func startOfNextDay(from date: Date, calendar: Calendar) -> Date {
    let startOfDay = calendar.startOfDay(for: date)
    return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(86_400)
}

private func advanceToNextAllowedMonth(
    from date: Date,
    year: Int,
    month: Int,
    schedule: CronSchedule,
    calendar: Calendar
) -> Date {
    if let nextMonth = schedule.month.nextOrSame(after: month + 1),
       let candidate = makeDate(
        year: year,
        month: nextMonth,
        day: 1,
        hour: 0,
        minute: 0,
        after: date,
        calendar: calendar
       ) {
        return candidate
    }

    let nextYear = year + 1
    return makeDate(
        year: nextYear,
        month: schedule.month.first,
        day: 1,
        hour: 0,
        minute: 0,
        after: date,
        calendar: calendar
    ) ?? date.addingTimeInterval(86_400)
}

private func advanceToNextAllowedHour(
    from date: Date,
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    schedule: CronSchedule,
    calendar: Calendar
) -> Date {
    if let nextHour = schedule.hour.nextOrSame(after: hour + 1),
       let candidate = makeDate(
        year: year,
        month: month,
        day: day,
        hour: nextHour,
        minute: 0,
        after: date,
        calendar: calendar
       ) {
        return candidate
    }

    return startOfNextDay(from: date, calendar: calendar)
}

private func advanceToNextAllowedMinute(
    from date: Date,
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    schedule: CronSchedule,
    calendar: Calendar
) -> Date {
    if let nextMinute = schedule.minute.nextOrSame(after: minute + 1),
       let candidate = makeDate(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: nextMinute,
        after: date,
        calendar: calendar
       ) {
        return candidate
    }

    if let nextHour = schedule.hour.nextOrSame(after: hour + 1),
       let candidate = makeDate(
        year: year,
        month: month,
        day: day,
        hour: nextHour,
        minute: schedule.minute.first,
        after: date,
        calendar: calendar
       ) {
        return candidate
    }

    return startOfNextDay(from: date, calendar: calendar)
}

private func makeDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    after reference: Date,
    calendar: Calendar
) -> Date? {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    components.nanosecond = 0

    if let direct = calendar.date(from: components) {
        return direct
    }

    return calendar.nextDate(
        after: reference,
        matching: components,
        matchingPolicy: .nextTime,
        repeatedTimePolicy: .first,
        direction: .forward
    )
}
