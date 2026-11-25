import AppKit
import SwiftUI

@MainActor
final class PopoverClock: ObservableObject {
    @Published var now = Date()
    @Published var resetCreditsTargetExpanded = false
    @Published var resetCreditsProgress: CGFloat = 0
    @Published var animatedDrawerHeight: CGFloat = 0
}

enum PopoverMotion {
    static let width: CGFloat = 320
    static let duration: TimeInterval = 0.22

    static func easeOutCubic(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        let inv = 1 - clamped
        return 1 - inv * inv * inv
    }

    static func pixelAligned(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct CollapsibleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

struct QuotaPopoverView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var clock: PopoverClock
    let onRefresh: () -> Void
    let onToggleResetCredits: (CGFloat) -> Void
    let onDrawerHeightMeasured: (CGFloat) -> Void
    let onContentHeightChange: (CGFloat) -> Void

    @State private var isResetCreditsHovered = false
    @State private var isRefreshHovered = false
    @State private var resetCreditsContentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            ForEach(Array(store.installedProviders.enumerated()), id: \.element) { index, provider in
                HairlineDivider()
                    .padding(.horizontal, 16)

                providerSection(for: provider)
                    .padding(.horizontal, 16)
                    .padding(.top, 13)
                    .padding(.bottom, index == store.installedProviders.count - 1 ? 14 : 13)
            }
        }
        .frame(width: PopoverMotion.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentHeightKey.self, value: PopoverMotion.pixelAligned(proxy.size.height))
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            guard height > 0 else { return }
            onContentHeightChange(height)
        }
        .frame(
            minWidth: PopoverMotion.width,
            maxWidth: PopoverMotion.width,
            maxHeight: .infinity,
            alignment: .top
        )
    }

    @ViewBuilder
    private func providerSection(for provider: QuotaProvider) -> some View {
        switch provider {
        case .codex:
            codexSection
        case .grok:
            grokSection
        case .agy:
            agySection
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Text("额度概览")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Text(DateFormatter.relativeUpdateLabel(for: store.lastUpdatedAt, at: clock.now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(action: onRefresh) {
                HStack(spacing: 3) {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.75)
                            .frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    Text("刷新")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(isRefreshHovered ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isRefreshHovered && !store.isRefreshing ? 0.06 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -6)
            .disabled(store.isRefreshing)
            .onHover { hovering in
                isRefreshHovered = hovering
            }
        }
    }

    // MARK: - Codex Section

    private var codexSection: some View {
        let snapshot = store.snapshot
        let daily = DailyQuotaBudget.remainingPercent(
            weeklyUsedPercent: snapshot.weeklyUsedPercent.map(Double.init),
            resetAt: snapshot.weeklyResetAt,
            at: clock.now
        )

        return VStack(alignment: .leading, spacing: 10) {
            ProviderSectionHeader(provider: .codex) {
                if snapshot.weeklyUsedPercent != nil || snapshot.weeklyResetAt != nil {
                    DailyBudgetBadge(percent: daily)
                }
            }

            VStack(spacing: 9) {
                ForEach(snapshot.displayRows, id: \.badge) { row in
                    let deadline = row.badge == "W" ? snapshot.weeklyResetAt : snapshot.fiveHourResetAt
                    let title = row.badge == "W" ? "周额度" : "5H 窗口"
                    QuotaMetricRow(
                        title: title,
                        remainingPercent: row.remainingPercent,
                        valueText: row.value,
                        deadline: deadline,
                        fallbackResetText: row.resetValue,
                        now: clock.now
                    )
                }
            }

            codexResetCreditsSection(snapshot.bankResets)
                .padding(.top, 1)

            if let errorMessage = snapshot.errorMessage {
                ErrorNotice(message: errorMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func codexResetCreditsSection(_ resets: RateLimitResetCreditsSummary?) -> some View {
        if let resets {
            let credits = resets.availableCredits(at: clock.now)
            let canExpand = !credits.isEmpty || resets.availableCount > 0
            let nearestExpiring = credits.first(where: { $0.expiresAt != nil })
            let nearestIsUrgent = nearestExpiring?.expiresWithinThreeDays(at: clock.now) ?? false

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard canExpand, resetCreditsContentHeight > 0 else { return }
                    onToggleResetCredits(resetCreditsContentHeight)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)

                        Text(resets.availableCount > 0 ? "重置卡 · \(resets.availableCount) 次可用" : "重置卡 · 暂无可用")
                            .font(.system(size: 11))
                            .foregroundStyle(resets.availableCount > 0 ? Color.primary.opacity(0.85) : Color.secondary)

                        Spacer()

                        if let nearest = nearestExpiring, let expiresAt = nearest.expiresAt {
                            let countdown = QuotaCountdown.compactString(
                                until: Date(timeIntervalSince1970: expiresAt),
                                at: clock.now,
                                expiredText: "已到期"
                            )
                            Text("最近 \(countdown) 后到期")
                                .font(.system(size: 10.5, weight: nearestIsUrgent ? .medium : .regular))
                                .foregroundStyle(nearestIsUrgent ? Color(nsColor: .systemRed) : .secondary)
                                .monospacedDigit()
                        }

                        if canExpand {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(Double(clock.resetCreditsProgress) * 90))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(canExpand && isResetCreditsHovered ? 0.05 : 0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
                .onHover { hovering in
                    isResetCreditsHovered = hovering
                }

                if canExpand {
                    resetCreditsDrawer(resets: resets, credits: credits)
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("重置卡")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("暂未获取")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetCreditsDrawer(resets: RateLimitResetCreditsSummary, credits: [RateLimitResetCredit]) -> some View {
        let progress = clock.resetCreditsProgress
        let drawerContent = VStack(alignment: .leading, spacing: 4) {
            if credits.count > 5 {
                ScrollView {
                    resetCreditRows(credits: credits)
                }
                .frame(height: 120)
            } else {
                resetCreditRows(credits: credits)
            }

            if resets.availableCount > credits.count {
                Text("另 \(resets.availableCount - credits.count) 次未提供到期明细")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.top, 8)
        .padding(.leading, 16)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: CollapsibleHeightKey.self, value: PopoverMotion.pixelAligned(proxy.size.height))
            }
        )

        return drawerContent
            .opacity(Double(progress))
            .offset(y: -4 * (1 - progress))
            .frame(height: clock.animatedDrawerHeight, alignment: .top)
            .clipped()
            .allowsHitTesting(clock.resetCreditsTargetExpanded && progress > 0.9)
            .onPreferenceChange(CollapsibleHeightKey.self) { height in
                if height > 0, abs(height - resetCreditsContentHeight) > 0.5 {
                    resetCreditsContentHeight = height
                    onDrawerHeightMeasured(height)
                }
            }
    }

    private func resetCreditRows(credits: [RateLimitResetCredit]) -> some View {
        VStack(spacing: 4) {
            ForEach(credits, id: \.id) { credit in
                let isUrgent = credit.expiresWithinThreeDays(at: clock.now)
                let countdown: String = {
                    guard let expiresAt = credit.expiresAt else { return "长期有效" }
                    return QuotaCountdown.compactString(
                        until: Date(timeIntervalSince1970: expiresAt),
                        at: clock.now,
                        expiredText: "已到期"
                    )
                }()

                HStack {
                    Text(credit.expirationValue)
                        .font(.system(size: 11))
                        .foregroundStyle(isUrgent ? Color(nsColor: .systemRed) : Color.primary.opacity(0.85))
                        .monospacedDigit()
                    Spacer()
                    Text(countdown)
                        .font(.system(size: 11, weight: isUrgent ? .medium : .regular))
                        .foregroundStyle(isUrgent ? Color(nsColor: .systemRed) : .secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Grok Section

    private var grokSection: some View {
        let grok = store.grokSnapshot
        let daily: Int? = grok.isTrial ? nil : DailyQuotaBudget.remainingPercent(
            weeklyUsedPercent: grok.usedPercent,
            resetAt: grok.resetAt,
            at: clock.now
        )

        return VStack(alignment: .leading, spacing: 10) {
            ProviderSectionHeader(provider: .grok) {
                if grok.isTrial {
                    StatusChip(text: "试用", foreground: .secondary, background: Color.primary.opacity(0.06))
                } else {
                    DailyBudgetBadge(percent: daily)
                }
            }

            QuotaMetricRow(
                title: grok.isTrial ? "试用额度" : "周额度",
                remainingPercent: grok.remainingPercent,
                valueText: grok.displayRow.value,
                deadline: grok.resetAt,
                fallbackResetText: grok.displayRow.resetValue,
                now: clock.now
            )

            HStack {
                let syncText = grok.updatedAt.map {
                    "缓存同步于 \(DateFormatter.syncDisplayString(for: $0, at: clock.now))"
                } ?? "尚未同步缓存"
                Text(syncText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if grok.errorMessage == nil, grok.remainingPercent != nil {
                    Text("有效")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = grok.errorMessage {
                ErrorNotice(message: errorMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Agy Section

    private var agySection: some View {
        let agy = store.agySnapshot
        let daily = DailyQuotaBudget.exactRemainingPercent(
            weeklyUsedPercent: agy.primaryWeeklyBucket?.usedPercent,
            resetAt: agy.primaryWeeklyBucket?.resetAt,
            at: clock.now
        )

        return VStack(alignment: .leading, spacing: 10) {
            ProviderSectionHeader(provider: .agy) {
                HStack(spacing: 8) {
                    if let credits = agy.formattedCredits {
                        Text("\(credits) Cr")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    DailyBudgetBadge(exactPercent: daily)
                }
            }

            if agy.groups.isEmpty {
                VStack(spacing: 9) {
                    QuotaMetricRow(title: "5H 窗口", remainingPercent: nil, valueText: "--",
                                   deadline: nil, fallbackResetText: "--", now: clock.now)
                    QuotaMetricRow(title: "周额度", remainingPercent: nil, valueText: "--",
                                   deadline: nil, fallbackResetText: "--", now: clock.now)
                }
            } else if agy.groups.count == 1, let onlyGroup = agy.groups.first {
                VStack(spacing: 9) {
                    if let fiveHour = onlyGroup.fiveHourBucket {
                        QuotaMetricRow(
                            title: "\(onlyGroup.displayName) 5H",
                            remainingPercent: fiveHour.remainingPercent,
                            exactRemainingPercent: fiveHour.exactRemainingPercent,
                            valueText: fiveHour.formattedRemainingPercent,
                            deadline: fiveHour.resetAt,
                            fallbackResetText: fiveHour.resetValue,
                            now: clock.now
                        )
                    }
                    if let weekly = onlyGroup.weeklyBucket {
                        QuotaMetricRow(
                            title: "\(onlyGroup.displayName) 周额度",
                            remainingPercent: weekly.remainingPercent,
                            exactRemainingPercent: weekly.exactRemainingPercent,
                            valueText: weekly.formattedRemainingPercent,
                            deadline: weekly.resetAt,
                            fallbackResetText: weekly.resetValue,
                            now: clock.now
                        )
                    }
                }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16, alignment: .top),
                        GridItem(.flexible(), spacing: 16, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(agy.groups, id: \.name) { group in
                        AgyPoolColumn(group: group, now: clock.now)
                    }
                }
            }

            if agy.formattedCredits == nil && agy.errorMessage == nil {
                HStack {
                    Text("AI Credits")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("暂未获取")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = agy.errorMessage {
                ErrorNotice(message: errorMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reusable Components

private struct HairlineDivider: View {
    var opacity: Double = 0.1

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity))
            .frame(height: 0.5)
    }
}

private struct ProviderSectionHeader<Trailing: View>: View {
    let provider: QuotaProvider
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: provider.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(provider.displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            trailing
        }
    }
}

private struct DailyBudgetBadge: View {
    let tone: QuotaTone
    let valueText: String

    init(percent: Int?) {
        self.tone = QuotaTone.forDailyBudget(percent)
        self.valueText = percent.map { "今日 \($0)%" } ?? "今日 --"
    }

    init(exactPercent: Double?) {
        self.tone = QuotaTone.forDailyBudget(exactPercent.map { Int($0.rounded()) })
        self.valueText = exactPercent.map { "今日 \(DailyQuotaBudget.formattedExactPercent($0))" } ?? "今日 --"
    }

    var body: some View {
        StatusChip(text: valueText, foreground: tone.swiftUIColor, background: tone.chipBackground)
    }
}

private struct StatusChip: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(background, in: Capsule())
    }
}

private struct QuotaMetricRow: View {
    let title: String
    let remainingPercent: Int?
    var exactRemainingPercent: Double? = nil
    let valueText: String
    let deadline: Date?
    let fallbackResetText: String
    let now: Date

    var body: some View {
        let tone = QuotaTone.forRemainingPercent(remainingPercent)
        let resetLabel: String = {
            if let deadline {
                let compact = QuotaCountdown.compactString(until: deadline, at: now)
                return compact == "已重置" ? "已重置" : "\(compact) 后重置"
            }
            return fallbackResetText == "--" ? "--" : fallbackResetText
        }()

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(valueText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tone == .critical ? Color(nsColor: .systemRed) : .primary)
                    .monospacedDigit()
                Spacer()
                Text(resetLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            QuotaProgressBar(
                remainingPercent: exactRemainingPercent ?? remainingPercent.map(Double.init),
                height: 3.5
            )
        }
        .help(deadline.map { "重置时间：\(DateFormatter.quotaHour.string(from: $0))" } ?? "")
    }
}

private struct AgyPoolColumn: View {
    let group: AgyQuotaGroup
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)

            if let fiveHour = group.fiveHourBucket {
                miniBucketRow(prefix: "5H", bucket: fiveHour)
            }
            if let weekly = group.weeklyBucket {
                miniBucketRow(prefix: "周", bucket: weekly)
            }
            if group.fiveHourBucket == nil && group.weeklyBucket == nil {
                Text("--")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func miniBucketRow(prefix: String, bucket: AgyQuotaBucket) -> some View {
        let tone = QuotaTone.forRemainingPercent(bucket.remainingPercent)
        let resetText = bucket.resetAt.map { QuotaCountdown.compactString(until: $0, at: now) } ?? "--"
        let valueColor: Color = {
            switch tone {
            case .critical: return Color(nsColor: .systemRed)
            case .caution: return Color(nsColor: .systemOrange)
            case .healthy, .neutral: return .primary
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(prefix)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)

                Text(bucket.formattedRemainingPercent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                Text(resetText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            QuotaProgressBar(remainingPercent: bucket.exactRemainingPercent, height: 3)
        }
        .help(bucket.resetAt.map { "\(group.displayName) \(prefix) 重置时间：\(DateFormatter.quotaHour.string(from: $0))" } ?? "")
    }
}

private struct QuotaProgressBar: View {
    let remainingPercent: Double?
    let height: CGFloat

    init(remainingPercent: Int?, height: CGFloat) {
        self.remainingPercent = remainingPercent.map(Double.init)
        self.height = height
    }

    init(remainingPercent: Double?, height: CGFloat) {
        self.remainingPercent = remainingPercent
        self.height = height
    }

    var body: some View {
        let tone = QuotaTone.forRemainingPercent(remainingPercent.map { Int($0.rounded()) })
        let ratio = remainingPercent.map { CGFloat(min(100, max(0, $0))) / 100.0 } ?? 0

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                if remainingPercent != nil, ratio > 0 {
                    Capsule()
                        .fill(tone.barColor)
                        .frame(width: max(height, proxy.size.width * ratio))
                }
            }
        }
        .frame(height: height)
    }
}

private struct ErrorNotice: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension QuotaTone {
    var swiftUIColor: Color {
        switch self {
        case .healthy: return Color(nsColor: .systemGreen)
        case .caution: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        case .neutral: return .secondary
        }
    }

    var barColor: Color {
        switch self {
        case .healthy: return Color(nsColor: .systemGreen)
        case .caution: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        case .neutral: return .secondary.opacity(0.4)
        }
    }

    var chipBackground: Color {
        switch self {
        case .healthy: return Color(nsColor: .systemGreen).opacity(0.12)
        case .caution: return Color(nsColor: .systemOrange).opacity(0.12)
        case .critical: return Color(nsColor: .systemRed).opacity(0.14)
        case .neutral: return Color.primary.opacity(0.06)
        }
    }
}
