import AppKit
import XCTest
@testable import QuotaBar

final class StatusRedesignTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return cal
    }

    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testCompactCountdownFormatsDaysHoursMinutesAndExpiry() {
        let now = date(6, hour: 12, minute: 0)
        XCTAssertEqual(QuotaCountdown.compactString(until: now.addingTimeInterval(2 * 86_400 + 5 * 3_600 + 12 * 60), at: now), "2天 5h")
        XCTAssertEqual(QuotaCountdown.compactString(until: now.addingTimeInterval(2 * 86_400), at: now), "2天")
        XCTAssertEqual(QuotaCountdown.compactString(until: now.addingTimeInterval(17 * 3_600 + 5 * 60), at: now), "17h 05m")
        XCTAssertEqual(QuotaCountdown.compactString(until: now.addingTimeInterval(3 * 3_600), at: now), "3h")
        XCTAssertEqual(QuotaCountdown.compactString(until: now.addingTimeInterval(42 * 60), at: now), "42m")
        XCTAssertEqual(QuotaCountdown.compactString(until: now.addingTimeInterval(35), at: now), "<1m")
        XCTAssertEqual(QuotaCountdown.compactString(until: now, at: now), "已重置")
        XCTAssertEqual(QuotaCountdown.compactString(until: now.addingTimeInterval(-10), at: now, expiredText: "已到期"), "已到期")
    }

    func testQuotaToneThreeTierThresholds() {
        XCTAssertEqual(QuotaTone.forRemainingPercent(51), .healthy)
        XCTAssertEqual(QuotaTone.forRemainingPercent(50), .caution)
        XCTAssertEqual(QuotaTone.forRemainingPercent(21), .caution)
        XCTAssertEqual(QuotaTone.forRemainingPercent(20), .critical)
        XCTAssertEqual(QuotaTone.forRemainingPercent(0), .critical)
        XCTAssertEqual(QuotaTone.forRemainingPercent(nil), .neutral)

        XCTAssertEqual(QuotaTone.forDailyBudget(51), .healthy)
        XCTAssertEqual(QuotaTone.forDailyBudget(50), .caution)
        XCTAssertEqual(QuotaTone.forDailyBudget(20), .caution)
        XCTAssertEqual(QuotaTone.forDailyBudget(19), .critical)
        XCTAssertEqual(QuotaTone.forDailyBudget(-50), .critical)
        XCTAssertEqual(QuotaTone.forDailyBudget(nil), .neutral)
    }

    func testDisplayModesRenderWithExpectedWidths() {
        let now = date(6, hour: 12)
        let reset = date(11, hour: 20)
        let groups = [
            QuotaStatusPresentation.codexGroup(
                QuotaSnapshot(weeklyUsedPercent: 30, weeklyResetAt: reset),
                at: now, calendar: calendar
            ),
            QuotaStatusPresentation.grokGroup(
                GrokQuotaSnapshot(usedPercent: 4, resetAt: reset),
                at: now, calendar: calendar
            ),
            QuotaStatusPresentation.agyGroup(
                AgyQuotaSnapshot(groups: [
                    AgyQuotaGroup(name: "Gemini", buckets: [
                        AgyQuotaBucket(id: "gemini-weekly", window: "weekly", remainingFraction: 0.2, resetAt: reset)
                    ])
                ]),
                at: now, calendar: calendar
            )
        ]

        let progressImage = QuotaStatusImageRenderer.render(groups: groups, mode: .progressBar)
        let dualImage = QuotaStatusImageRenderer.render(groups: groups, mode: .compactDual)

        XCTAssertGreaterThan(progressImage.size.width, 0)
        XCTAssertGreaterThan(dualImage.size.width, 0)
        XCTAssertLessThan(progressImage.size.width, 200)
        XCTAssertTrue(progressImage.isTemplate)
        XCTAssertTrue(dualImage.isTemplate)
    }

    func testDisplayModePersistsInUserDefaultsAndFallsBackFromRemovedValues() {
        let suiteName = "StatusRedesignTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(StatusBarDisplayMode.load(from: defaults), .progressBar)
        StatusBarDisplayMode.compactDual.save(to: defaults)
        XCTAssertEqual(StatusBarDisplayMode.load(from: defaults), .compactDual)

        defaults.set("summary", forKey: "QuotaBar.statusBarDisplayMode")
        XCTAssertEqual(StatusBarDisplayMode.load(from: defaults), .progressBar)
    }

    func testRelativeUpdateAndSyncTimeFormatters() {
        let now = date(6, hour: 12, minute: 30)
        XCTAssertEqual(DateFormatter.relativeUpdateLabel(for: nil, at: now), "尚未更新")
        XCTAssertEqual(DateFormatter.relativeUpdateLabel(for: now.addingTimeInterval(-20), at: now), "刚刚更新")
        XCTAssertEqual(DateFormatter.relativeUpdateLabel(for: now.addingTimeInterval(-180), at: now), "3 分钟前")
        XCTAssertEqual(DateFormatter.relativeUpdateLabel(for: now.addingTimeInterval(-7_200), at: now), "2 小时前")

        let sameDay = date(6, hour: 9, minute: 5)
        let prevDay = date(5, hour: 21, minute: 15)
        XCTAssertEqual(DateFormatter.syncDisplayString(for: sameDay, at: now, calendar: calendar), "09:05")
        XCTAssertEqual(DateFormatter.syncDisplayString(for: prevDay, at: now, calendar: calendar), "11月5日 21:15")
    }
}
