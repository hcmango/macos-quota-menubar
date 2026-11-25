import Foundation

enum QuotaTone: Equatable {
    case healthy
    case caution
    case critical
    case neutral

    static func forRemainingPercent(_ percent: Int?) -> QuotaTone {
        guard let percent else { return .neutral }
        if percent <= 20 { return .critical }
        if percent <= 50 { return .caution }
        return .healthy
    }

    static func forDailyBudget(_ percent: Int?) -> QuotaTone {
        guard let percent else { return .neutral }
        if percent < 20 { return .critical }
        if percent <= 50 { return .caution }
        return .healthy
    }
}

enum StatusBarDisplayMode: String, CaseIterable, Identifiable {
    case progressBar
    case compactDual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .progressBar: return "进度条"
        case .compactDual: return "双行极简"
        }
    }

    private static let defaultsKey = "QuotaBar.statusBarDisplayMode"

    static func load(from defaults: UserDefaults = .standard) -> StatusBarDisplayMode {
        guard let raw = defaults.string(forKey: defaultsKey),
              let mode = StatusBarDisplayMode(rawValue: raw) else {
            return .progressBar
        }
        return mode
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum QuotaStatusPresentation {
    static func codexRows(_ snapshot: QuotaSnapshot, at now: Date = Date(), calendar: Calendar = .current) -> [StatusRenderRow] {
        guard let weekly = snapshot.displayRows.first(where: { $0.badge == "W" }) else {
            return snapshot.displayRows.map(quotaRow)
        }
        let daily = DailyQuotaBudget.remainingPercent(weeklyUsedPercent: snapshot.weeklyUsedPercent.map(Double.init),
                                                      resetAt: snapshot.weeklyResetAt, at: now, calendar: calendar)
        return [dailyRow(daily), quotaRow(weekly)]
    }

    static func grokRows(_ snapshot: GrokQuotaSnapshot, at now: Date = Date(), calendar: Calendar = .current) -> [StatusRenderRow] {
        guard !snapshot.isTrial else { return [quotaRow(snapshot.displayRow)] }
        let daily = DailyQuotaBudget.remainingPercent(weeklyUsedPercent: snapshot.usedPercent,
                                                      resetAt: snapshot.resetAt, at: now, calendar: calendar)
        return [dailyRow(daily), quotaRow(snapshot.displayRow)]
    }

    static func agyRows(_ snapshot: AgyQuotaSnapshot, at now: Date = Date(), calendar: Calendar = .current) -> [StatusRenderRow] {
        guard let weekly = snapshot.displayRows.first(where: { $0.badge == "W" }) else {
            return snapshot.displayRows.map(quotaRow)
        }
        let daily = DailyQuotaBudget.remainingPercent(
            weeklyUsedPercent: snapshot.primaryWeeklyBucket?.usedPercent,
            resetAt: snapshot.primaryWeeklyBucket?.resetAt,
            at: now,
            calendar: calendar
        )
        return [dailyRow(daily), quotaRow(weekly)]
    }

    static func codexGroup(_ snapshot: QuotaSnapshot, at now: Date = Date(), calendar: Calendar = .current) -> StatusRenderGroup {
        let rows = codexRows(snapshot, at: now, calendar: calendar)
        let daily = DailyQuotaBudget.remainingPercent(
            weeklyUsedPercent: snapshot.weeklyUsedPercent.map(Double.init),
            resetAt: snapshot.weeklyResetAt,
            at: now,
            calendar: calendar
        )
        let barPercent = snapshot.weeklyRemainingPercent ?? snapshot.fiveHourRemainingPercent
        let primaryRow = rows.first
        return StatusRenderGroup(
            provider: .codex,
            rows: rows,
            primaryText: primaryRow?.value ?? "--",
            primaryTint: primaryRow?.tint ?? .normal,
            barProgress: barPercent.map { Double(min(100, max(0, $0))) / 100.0 },
            barTone: QuotaTone.forRemainingPercent(barPercent),
            hasError: snapshot.errorMessage != nil,
            primaryNumericPercent: daily ?? barPercent
        )
    }

    static func grokGroup(_ snapshot: GrokQuotaSnapshot, at now: Date = Date(), calendar: Calendar = .current) -> StatusRenderGroup {
        let rows = grokRows(snapshot, at: now, calendar: calendar)
        let daily: Int? = snapshot.isTrial ? nil : DailyQuotaBudget.remainingPercent(
            weeklyUsedPercent: snapshot.usedPercent,
            resetAt: snapshot.resetAt,
            at: now,
            calendar: calendar
        )
        let remaining = snapshot.remainingPercent
        let primaryRow = rows.first
        return StatusRenderGroup(
            provider: .grok,
            rows: rows,
            primaryText: primaryRow?.value ?? "--",
            primaryTint: primaryRow?.tint ?? .normal,
            barProgress: remaining.map { Double(min(100, max(0, $0))) / 100.0 },
            barTone: QuotaTone.forRemainingPercent(remaining),
            hasError: snapshot.errorMessage != nil,
            primaryNumericPercent: daily ?? remaining
        )
    }

    static func agyGroup(_ snapshot: AgyQuotaSnapshot, at now: Date = Date(), calendar: Calendar = .current) -> StatusRenderGroup {
        let rows = agyRows(snapshot, at: now, calendar: calendar)
        let daily = DailyQuotaBudget.remainingPercent(
            weeklyUsedPercent: snapshot.primaryWeeklyBucket?.usedPercent,
            resetAt: snapshot.primaryWeeklyBucket?.resetAt,
            at: now,
            calendar: calendar
        )
        let primaryBarPercent = snapshot.primaryWeeklyBucket?.remainingPercent ?? snapshot.primaryFiveHourBucket?.remainingPercent
        let primaryRow = rows.first
        return StatusRenderGroup(
            provider: .agy,
            rows: rows,
            primaryText: primaryRow?.value ?? "--",
            primaryTint: primaryRow?.tint ?? .normal,
            barProgress: primaryBarPercent.map { Double(min(100, max(0, $0))) / 100.0 },
            barTone: QuotaTone.forRemainingPercent(primaryBarPercent),
            hasError: snapshot.errorMessage != nil,
            primaryNumericPercent: daily ?? primaryBarPercent
        )
    }

    private static func quotaRow(_ row: QuotaDisplayRow) -> StatusRenderRow {
        StatusRenderRow(badge: row.badge, value: row.value,
                        tint: row.remainingPercent.map { $0 <= 20 ? .red : .normal } ?? .normal)
    }

    private static func dailyRow(_ remaining: Int?) -> StatusRenderRow {
        StatusRenderRow(badge: "D", value: remaining.map { "\($0)%" } ?? "--",
                        tint: .daily(remaining), colorsValue: true)
    }
}
