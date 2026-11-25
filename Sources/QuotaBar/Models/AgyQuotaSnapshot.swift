import Foundation

struct AgyQuotaBucket: Equatable {
    let id: String
    let window: String
    let remainingFraction: Double
    let resetAt: Date?

    var clampedRemainingFraction: Double {
        min(1, max(0, remainingFraction))
    }

    var usedPercent: Double {
        (1 - clampedRemainingFraction) * 100
    }

    var exactRemainingPercent: Double {
        clampedRemainingFraction * 100
    }

    var remainingPercent: Int {
        Int(exactRemainingPercent.rounded())
    }

    var formattedRemainingPercent: String {
        String(format: "%.2f%%", exactRemainingPercent)
    }

    var isWeekly: Bool {
        window.lowercased() == "weekly" || id.lowercased().hasSuffix("-weekly")
    }

    var isFiveHour: Bool {
        window.lowercased() == "5h" || id.lowercased().hasSuffix("-5h")
    }

    var resetValue: String {
        resetAt.map { DateFormatter.quotaHour.string(from: $0) } ?? "--"
    }
}

struct AgyQuotaGroup: Equatable {
    let name: String
    let buckets: [AgyQuotaBucket]

    var isGemini: Bool {
        name.localizedCaseInsensitiveContains("gemini")
            || buckets.contains { $0.id.lowercased().hasPrefix("gemini") }
    }

    var displayName: String {
        if isGemini { return "Gemini" }
        if name.localizedCaseInsensitiveContains("claude")
            || name.localizedCaseInsensitiveContains("gpt")
            || buckets.contains(where: { $0.id.lowercased().hasPrefix("3p") }) {
            return "Claude/GPT"
        }
        return name
    }

    var weeklyBucket: AgyQuotaBucket? {
        buckets.first(where: \.isWeekly)
    }

    var fiveHourBucket: AgyQuotaBucket? {
        buckets.first(where: \.isFiveHour)
    }

    var tooltipSummary: String {
        var parts: [String] = []
        if let fiveHour = fiveHourBucket {
            parts.append("5H \(fiveHour.remainingPercent)%")
        }
        if let weekly = weeklyBucket {
            parts.append("W \(weekly.remainingPercent)%")
        }
        if parts.isEmpty {
            parts.append("--")
        }
        return "\(displayName) \(parts.joined(separator: " | "))"
    }
}

struct AgyQuotaSnapshot: Equatable {
    var groups: [AgyQuotaGroup] = []
    var remainingCredits: Double? = nil
    var errorMessage: String? = nil

    static let empty = AgyQuotaSnapshot()

    var primaryGroup: AgyQuotaGroup? {
        groups.first(where: \.isGemini) ?? groups.first
    }

    var primaryWeeklyBucket: AgyQuotaBucket? {
        primaryGroup?.weeklyBucket
    }

    var primaryFiveHourBucket: AgyQuotaBucket? {
        primaryGroup?.fiveHourBucket
    }

    var displayRows: [QuotaDisplayRow] {
        guard let primary = primaryGroup else {
            return [
                QuotaDisplayRow(badge: "5H", value: "--", remainingPercent: nil, resetLabel: "Agy 5H", resetValue: "--"),
                QuotaDisplayRow(badge: "W", value: "--", remainingPercent: nil, resetLabel: "Agy 周额度", resetValue: "--")
            ]
        }

        var rows: [QuotaDisplayRow] = []
        if let fiveHour = primary.fiveHourBucket {
            rows.append(QuotaDisplayRow(
                badge: "5H",
                value: "\(fiveHour.remainingPercent)%",
                remainingPercent: fiveHour.remainingPercent,
                resetLabel: "Agy \(primary.displayName) 5H",
                resetValue: fiveHour.resetValue
            ))
        }
        if let weekly = primary.weeklyBucket {
            rows.append(QuotaDisplayRow(
                badge: "W",
                value: "\(weekly.remainingPercent)%",
                remainingPercent: weekly.remainingPercent,
                resetLabel: "Agy \(primary.displayName) 周额度",
                resetValue: weekly.resetValue
            ))
        }

        if rows.isEmpty {
            return [
                QuotaDisplayRow(badge: "5H", value: "--", remainingPercent: nil, resetLabel: "Agy 5H", resetValue: "--"),
                QuotaDisplayRow(badge: "W", value: "--", remainingPercent: nil, resetLabel: "Agy 周额度", resetValue: "--")
            ]
        }

        return rows
    }

    var formattedCredits: String? {
        guard let remainingCredits, remainingCredits.isFinite else { return nil }
        let rounded = remainingCredits.rounded()
        if abs(remainingCredits - rounded) < 0.0001 {
            return String(Int64(rounded))
        }
        return String(format: "%.2f", remainingCredits)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    var menuTitle: String {
        let base: String
        if groups.isEmpty {
            base = "Agy 5H -- | W --"
        } else {
            base = "Agy " + groups.map(\.tooltipSummary).joined(separator: " · ")
        }
        var parts = [base]
        if let credits = formattedCredits {
            parts.append("Credits \(credits)")
        }
        if let errorMessage {
            parts.append(errorMessage)
        }
        return parts.joined(separator: " · ")
    }
}
