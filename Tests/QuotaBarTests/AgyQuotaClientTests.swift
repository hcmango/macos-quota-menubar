import XCTest
@testable import QuotaBar

final class AgyQuotaClientTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testParseUsageDecodesGeminiAndThirdPartyGroups() throws {
        let payload = #"""
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "window": "weekly",
                      "remaining_fraction": 0.9833783507347107,
                      "reset_time": "2026-12-01T02:35:15Z"
                    },
                    {
                      "id": "gemini-5h",
                      "window": "5h",
                      "remaining_fraction": 0.9699599742889404,
                      "reset_time": "2026-11-24T07:35:15.500Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "window": "weekly",
                      "remaining_fraction": 1,
                      "reset_time": "2026-12-01T03:17:23Z"
                    },
                    {
                      "id": "3p-5h",
                      "window": "5h",
                      "remaining_fraction": 0.15,
                      "reset_time": "2026-11-24T08:17:23Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """#

        let groups = try AgyQuotaClient.parseUsage(Data(payload.utf8))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].displayName, "Gemini")
        XCTAssertEqual(groups[0].weeklyBucket?.remainingPercent, 98)
        XCTAssertEqual(groups[0].fiveHourBucket?.remainingPercent, 97)
        XCTAssertNotNil(groups[0].weeklyBucket?.resetAt)
        XCTAssertNotNil(groups[0].fiveHourBucket?.resetAt)

        XCTAssertEqual(groups[1].displayName, "Claude/GPT")
        XCTAssertEqual(groups[1].weeklyBucket?.remainingPercent, 100)
        XCTAssertEqual(groups[1].fiveHourBucket?.remainingPercent, 15)

        let snapshot = AgyQuotaSnapshot(groups: groups, remainingCredits: 0)
        XCTAssertEqual(snapshot.primaryGroup?.displayName, "Gemini")
        XCTAssertEqual(snapshot.formattedCredits, "0")
        XCTAssertTrue(snapshot.menuTitle.contains("Agy Gemini 5H 97% | W 98%"))
        XCTAssertTrue(snapshot.menuTitle.contains("Claude/GPT 5H 15% | W 100%"))
        XCTAssertTrue(snapshot.menuTitle.contains("Credits 0"))
    }

    func testParseCreditsFormatsIntegerAndDecimalValues() throws {
        let intPayload = #"{"status":"SUCCESS","command":{"name":"credits","data":{"remaining_credits":250}}}"#
        let decimalPayload = #"{"status":"SUCCESS","command":{"name":"credits","data":{"remaining_credits":12.5}}}"#
        XCTAssertEqual(try AgyQuotaClient.parseCredits(Data(intPayload.utf8)), 250)
        XCTAssertEqual(try AgyQuotaClient.parseCredits(Data(decimalPayload.utf8)), 12.5)
        XCTAssertEqual(AgyQuotaSnapshot(remainingCredits: 250).formattedCredits, "250")
        XCTAssertEqual(AgyQuotaSnapshot(remainingCredits: 12.5).formattedCredits, "12.5")
    }

    func testParseUsageReportsErrorEnvelope() {
        let payload = #"{"status":"ERROR","error":"quota backend unavailable"}"#
        XCTAssertThrowsError(try AgyQuotaClient.parseUsage(Data(payload.utf8))) { error in
            XCTAssertEqual(error as? AgyQuotaError, .cliError("quota backend unavailable"))
        }
    }

    func testAgyPresentationUsesPrimaryGeminiPoolForDailyAndWeekly() {
        let now = date(6, hour: 12)
        let resetAt = date(11, hour: 20)
        let snapshot = AgyQuotaSnapshot(groups: [
            AgyQuotaGroup(name: "Claude and GPT models", buckets: [
                AgyQuotaBucket(id: "3p-weekly", window: "weekly", remainingFraction: 0.1, resetAt: resetAt)
            ]),
            AgyQuotaGroup(name: "Gemini Models", buckets: [
                AgyQuotaBucket(id: "gemini-5h", window: "5h", remainingFraction: 0.95, resetAt: date(6, hour: 17)),
                AgyQuotaBucket(id: "gemini-weekly", window: "weekly", remainingFraction: 0.70, resetAt: resetAt)
            ])
        ])

        let rows = QuotaStatusPresentation.agyRows(snapshot, at: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.badge), ["D", "W"])
        XCTAssertEqual(rows.map(\.value), ["90%", "70%"])
        XCTAssertEqual(rows.map(\.tint), [.green, .normal])
        XCTAssertTrue(rows[0].colorsValue)
        XCTAssertFalse(rows[1].colorsValue)
    }

    func testAgyPresentationHandlesFiveHourOnlyAndEmptySnapshots() {
        let fiveHourOnly = AgyQuotaSnapshot(groups: [
            AgyQuotaGroup(name: "Gemini Models", buckets: [
                AgyQuotaBucket(id: "gemini-5h", window: "5h", remainingFraction: 0.15, resetAt: nil)
            ])
        ])
        let hourlyRows = QuotaStatusPresentation.agyRows(fiveHourOnly)
        XCTAssertEqual(hourlyRows.map(\.badge), ["5H"])
        XCTAssertEqual(hourlyRows.map(\.value), ["15%"])
        XCTAssertEqual(hourlyRows.map(\.tint), [.red])

        let emptyRows = QuotaStatusPresentation.agyRows(.empty)
        XCTAssertEqual(emptyRows.map(\.badge), ["D", "W"])
        XCTAssertEqual(emptyRows.map(\.value), ["--", "--"])
    }

    func testRunAgyCommandAbortsImmediatelyWhenAuthenticationRequired() {
        let start = Date()
        XCTAssertThrowsError(try runAgyCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'Authentication required. Please visit the URL to log in:' >&2; sleep 5"],
            timeout: 5
        )) { error in
            XCTAssertEqual(error as? AgyQuotaError, .signedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRunAgyCommandReportsTimeout() {
        XCTAssertThrowsError(try runAgyCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2"],
            timeout: 0.15
        )) { error in
            guard case AgyQuotaError.timeout = error else {
                return XCTFail("Expected timeout error, got \(error)")
            }
        }
    }

    func testRunAgyCommandExtractsJSONErrorOnNonZeroExit() {
        XCTAssertThrowsError(try runAgyCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '%s\n' '{"status":"ERROR","error":"bad account"}'; exit 1"#],
            timeout: 2
        )) { error in
            XCTAssertEqual(error as? AgyQuotaError, .cliError("bad account"))
        }
    }

    func testRunAgyCommandStripsSSHSessionVariables() throws {
        let data = try runAgyCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '%s|%s|%s' "$SSH_CLIENT" "$SSH_CONNECTION" "$SSH_TTY""#],
            timeout: 2,
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "SSH_CLIENT": "1.2.3.4 1 2",
                "SSH_CONNECTION": "127.0.0.1 0 127.0.0.1 0",
                "SSH_TTY": "/dev/ttys001"
            ]
        )
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "||")
    }

    func testExecutableDiscoveryChecksLocalBinAndPath() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let localBin = tempHome.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let agy = localBin.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agy.path)

        let found = try agyExecutableURL(homeDirectory: tempHome, environment: ["PATH": ""])
        XCTAssertEqual(found.path, agy.path)
    }

    func testAgyPopoverPercentagesFormatToTwoDecimalPlaces() {
        let weekly = AgyQuotaBucket(id: "gemini-weekly", window: "weekly", remainingFraction: 0.9833783507347107, resetAt: nil)
        let fiveHour = AgyQuotaBucket(id: "gemini-5h", window: "5h", remainingFraction: 0.9699599742889404, resetAt: nil)
        let full = AgyQuotaBucket(id: "3p-weekly", window: "weekly", remainingFraction: 1, resetAt: nil)
        let empty = AgyQuotaBucket(id: "3p-5h", window: "5h", remainingFraction: -0.2, resetAt: nil)

        XCTAssertEqual(weekly.formattedRemainingPercent, "98.34%")
        XCTAssertEqual(fiveHour.formattedRemainingPercent, "97.00%")
        XCTAssertEqual(full.formattedRemainingPercent, "100.00%")
        XCTAssertEqual(empty.formattedRemainingPercent, "0.00%")

        let now = date(6, hour: 12)
        let resetAt = date(11, hour: 20)
        let exactDaily = DailyQuotaBudget.exactRemainingPercent(
            weeklyUsedPercent: weekly.usedPercent,
            resetAt: resetAt,
            at: now,
            calendar: calendar
        )
        XCTAssertNotNil(exactDaily)
        XCTAssertEqual(DailyQuotaBudget.formattedExactPercent(exactDaily!), "288.36%")
        XCTAssertEqual(DailyQuotaBudget.formattedExactPercent(-0.001), "0.00%")
        XCTAssertEqual(DailyQuotaBudget.formattedExactPercent(-12.346), "-12.35%")
    }
}
