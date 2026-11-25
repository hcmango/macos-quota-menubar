import Foundation

extension DateFormatter {
    static let bankResetExpiration: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static let quotaHour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static let quotaTimeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func syncDisplayString(for date: Date, at now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return quotaTimeOnly.string(from: date)
        }
        return quotaHour.string(from: date)
    }

    static func relativeUpdateLabel(for date: Date?, at now: Date = Date()) -> String {
        guard let date else { return "尚未更新" }
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 45 {
            return "刚刚更新"
        }
        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return "\(minutes) 分钟前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) 小时前"
        }
        return quotaHour.string(from: date)
    }
}

/// Shared minute-precision countdown for quota windows and reset credits.
enum QuotaCountdown {
    static func string(until deadline: Date, at now: Date = Date()) -> String {
        let totalMinutes = Int(max(0, deadline.timeIntervalSince(now)) / 60)
        let days = totalMinutes / 1_440
        let hours = totalMinutes % 1_440 / 60
        let minutes = totalMinutes % 60
        return String(format: "%d天 %02d:%02d", days, hours, minutes)
    }

    /// Human-friendly compact countdown without leading "0天" noise.
    static func compactString(until deadline: Date, at now: Date = Date(), expiredText: String = "已重置") -> String {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return expiredText }
        if remaining < 60 {
            return "<1m"
        }
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)天 \(hours)h" : "\(days)天"
        }
        if hours > 0 {
            return minutes > 0 ? String(format: "%dh %02dm", hours, minutes) : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
