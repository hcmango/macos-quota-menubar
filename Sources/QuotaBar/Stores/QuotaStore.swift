import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    nonisolated static let refreshInterval: Duration = .seconds(180)

    private let readCodex: () async throws -> QuotaSnapshot
    private let readGrok: () async throws -> GrokQuotaSnapshot
    private let readAgy: () async throws -> AgyQuotaSnapshot
    private let detectProviders: () -> [QuotaProvider]

    @Published private(set) var installedProviders: [QuotaProvider]
    @Published var snapshot: QuotaSnapshot = .empty
    @Published var grokSnapshot: GrokQuotaSnapshot = .empty
    @Published var agySnapshot: AgyQuotaSnapshot = .empty
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var isRefreshing = false

    private var isRefreshingCodex = false
    private var isRefreshingGrok = false
    private var isRefreshingAgy = false

    init(
        automaticallyRefresh: Bool = true,
        refreshInterval: Duration = QuotaStore.refreshInterval,
        detectProviders: @escaping () -> [QuotaProvider] = QuotaProviderDetector.installedProviders,
        readCodex: @escaping () async throws -> QuotaSnapshot = { try await CodexAppServerClient().readQuota() },
        readGrok: @escaping () async throws -> GrokQuotaSnapshot = {
            try await Task.detached { try GrokQuotaCacheClient().readQuota() }.value
        },
        readAgy: @escaping () async throws -> AgyQuotaSnapshot = { try await AgyQuotaClient().readQuota() }
    ) {
        self.readCodex = readCodex
        self.readGrok = readGrok
        self.readAgy = readAgy
        self.detectProviders = detectProviders
        installedProviders = detectProviders()
        guard automaticallyRefresh else { return }
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: refreshInterval)
            }
        }
    }

    func refresh() async {
        let providers = detectProviders()
        if providers != installedProviders {
            installedProviders = providers
            if !providers.contains(.codex) { snapshot = .empty }
            if !providers.contains(.grok) { grokSnapshot = .empty }
            if !providers.contains(.agy) { agySnapshot = .empty }
        }
        isRefreshing = true
        defer {
            updateRefreshingFlag()
            if !installedProviders.isEmpty {
                lastUpdatedAt = Date()
            }
        }
        async let codex: Void = refreshCodex()
        async let grok: Void = refreshGrok()
        async let agy: Void = refreshAgy()
        _ = await (codex, grok, agy)
    }

    private func updateRefreshingFlag() {
        isRefreshing = isRefreshingCodex || isRefreshingGrok || isRefreshingAgy
    }

    private func refreshCodex() async {
        guard installedProviders.contains(.codex), !isRefreshingCodex else {
            return
        }

        isRefreshingCodex = true
        updateRefreshingFlag()
        defer {
            isRefreshingCodex = false
            updateRefreshingFlag()
        }

        do {
            let result = try await readCodex()
            guard installedProviders.contains(.codex) else { return }
            snapshot = result
        } catch {
            guard installedProviders.contains(.codex) else { return }
            snapshot = QuotaSnapshot(
                errorMessage: error.localizedDescription
            )
        }
    }

    private func refreshGrok() async {
        guard installedProviders.contains(.grok), !isRefreshingGrok else { return }
        isRefreshingGrok = true
        updateRefreshingFlag()
        defer {
            isRefreshingGrok = false
            updateRefreshingFlag()
        }
        do {
            let result = try await readGrok()
            guard installedProviders.contains(.grok) else { return }
            grokSnapshot = result
        } catch {
            guard installedProviders.contains(.grok) else { return }
            grokSnapshot = GrokQuotaSnapshot(errorMessage: error.localizedDescription)
        }
    }

    private func refreshAgy() async {
        guard installedProviders.contains(.agy), !isRefreshingAgy else { return }
        isRefreshingAgy = true
        updateRefreshingFlag()
        defer {
            isRefreshingAgy = false
            updateRefreshingFlag()
        }
        do {
            let result = try await readAgy()
            guard installedProviders.contains(.agy) else { return }
            agySnapshot = result
        } catch {
            guard installedProviders.contains(.agy) else { return }
            agySnapshot = AgyQuotaSnapshot(errorMessage: error.localizedDescription)
        }
    }
}
