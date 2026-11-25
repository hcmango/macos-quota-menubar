import Foundation

enum DailyQuotaBudget {
    /// One daily budget is 1/7 of the weekly allowance. Unused daily budgets carry
    /// forward, so today's remainder can exceed 100% of a single daily budget
    /// or fall below zero when usage exceeds the budget allocated so far.
    static func exactRemainingPercent(
        weeklyUsedPercent: Double?, resetAt: Date?, at now: Date = Date(), calendar: Calendar = .current
    ) -> Double? {
        guard let used = weeklyUsedPercent, used.isFinite, used >= 0,
              let resetAt, resetAt > now else { return nil }
        let weekStart = resetAt.addingTimeInterval(-7 * 86_400)
        guard now >= weekStart else { return nil }
        let daysElapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: weekStart),
                                                   to: calendar.startOfDay(for: now)).day ?? 0
        // Release a share on the reset date and then at each local midnight,
        // with at most seven shares released before the next weekly reset.
        let allocatedDays = min(7, daysElapsed + 1)
        return Double(allocatedDays) * 100 - min(100, used) * 7
    }

    static func remainingPercent(
        weeklyUsedPercent: Double?, resetAt: Date?, at now: Date = Date(), calendar: Calendar = .current
    ) -> Int? {
        exactRemainingPercent(weeklyUsedPercent: weeklyUsedPercent, resetAt: resetAt, at: now, calendar: calendar)
            .map { Int($0.rounded()) }
    }

    static func formattedExactPercent(_ value: Double) -> String {
        let normalized = abs(value) < 0.005 ? 0 : value
        return String(format: "%.2f%%", normalized)
    }
}
