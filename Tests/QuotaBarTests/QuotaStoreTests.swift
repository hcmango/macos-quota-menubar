import XCTest
@testable import QuotaBar

final class QuotaStoreTests: XCTestCase {
    @MainActor
    func testOnlyInstalledProvidersAreDisplayedAndRead() async {
        let combinations: [[QuotaProvider]] = [[], [.codex], [.grok], [.agy], [.codex, .grok, .agy]]
        for providers in combinations {
            var codexReads = 0
            var grokReads = 0
            var agyReads = 0
            let store = QuotaStore(automaticallyRefresh: false, detectProviders: { providers },
                                  readCodex: {
                codexReads += 1
                return QuotaSnapshot(weeklyUsedPercent: 10)
            }, readGrok: {
                grokReads += 1
                return GrokQuotaSnapshot(usedPercent: 20)
            }, readAgy: {
                agyReads += 1
                return AgyQuotaSnapshot(groups: [
                    AgyQuotaGroup(name: "Gemini Models", buckets: [
                        AgyQuotaBucket(id: "gemini-weekly", window: "weekly", remainingFraction: 0.75, resetAt: nil)
                    ])
                ], remainingCredits: 5)
            })
            XCTAssertEqual(store.installedProviders, providers)
            await store.refresh()
            XCTAssertEqual(codexReads, providers.contains(.codex) ? 1 : 0)
            XCTAssertEqual(grokReads, providers.contains(.grok) ? 1 : 0)
            XCTAssertEqual(agyReads, providers.contains(.agy) ? 1 : 0)
            XCTAssertEqual(store.snapshot.weeklyRemainingPercent, providers.contains(.codex) ? 90 : nil)
            XCTAssertEqual(store.grokSnapshot.remainingPercent, providers.contains(.grok) ? 80 : nil)
            XCTAssertEqual(store.agySnapshot.primaryWeeklyBucket?.remainingPercent, providers.contains(.agy) ? 75 : nil)
        }
    }

    @MainActor
    func testRefreshDetectsInstallationChangesAndClearsRemovedQuota() async {
        var providers: [QuotaProvider] = [.codex]
        let store = QuotaStore(automaticallyRefresh: false, detectProviders: { providers },
                              readCodex: { QuotaSnapshot(weeklyUsedPercent: 5) },
                              readGrok: { GrokQuotaSnapshot(usedPercent: 10) },
                              readAgy: {
            AgyQuotaSnapshot(groups: [
                AgyQuotaGroup(name: "Gemini Models", buckets: [
                    AgyQuotaBucket(id: "gemini-weekly", window: "weekly", remainingFraction: 0.85, resetAt: nil)
                ])
            ])
        })
        await store.refresh()
        providers = [.grok, .agy]
        await store.refresh()
        XCTAssertEqual(store.installedProviders, [.grok, .agy])
        XCTAssertNil(store.snapshot.weeklyRemainingPercent)
        XCTAssertEqual(store.grokSnapshot.remainingPercent, 90)
        XCTAssertEqual(store.agySnapshot.primaryWeeklyBucket?.remainingPercent, 85)
        providers = []
        await store.refresh()
        XCTAssertEqual(store.installedProviders, [])
        XCTAssertNil(store.grokSnapshot.remainingPercent)
        XCTAssertNil(store.agySnapshot.primaryWeeklyBucket)
    }

    @MainActor
    func testInFlightReadCannotRestoreAnUninstalledProvider() async {
        var providers: [QuotaProvider] = [.codex, .grok]
        var resumeCodex: CheckedContinuation<QuotaSnapshot, Never>?
        let started = expectation(description: "Codex waiting")
        let store = QuotaStore(automaticallyRefresh: false, detectProviders: { providers },
                              readCodex: {
            await withCheckedContinuation { continuation in
                resumeCodex = continuation
                started.fulfill()
            }
        }, readGrok: { GrokQuotaSnapshot(usedPercent: 10) })
        let firstRefresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        providers = [.grok]
        await store.refresh()
        resumeCodex?.resume(returning: QuotaSnapshot(weeklyUsedPercent: 3))
        await firstRefresh.value
        XCTAssertEqual(store.installedProviders, [.grok])
        XCTAssertNil(store.snapshot.weeklyRemainingPercent)
        XCTAssertEqual(store.grokSnapshot.remainingPercent, 90)
    }

    @MainActor
    func testCodexFailureDoesNotHideGrokQuota() async {
        let store = QuotaStore(automaticallyRefresh: false,
                              detectProviders: { [.codex, .grok] },
                              readCodex: { throw CodexAppServerError.timeout(nil) },
                              readGrok: { GrokQuotaSnapshot(usedPercent: 12) })
        await store.refresh()
        XCTAssertNotNil(store.snapshot.errorMessage)
        XCTAssertEqual(store.grokSnapshot.remainingPercent, 88)
    }

    @MainActor
    func testGrokFailureClearsItsOldQuotaAndPreservesCodex() async {
        let store = QuotaStore(automaticallyRefresh: false,
                              detectProviders: { [.codex, .grok] },
                              readCodex: { QuotaSnapshot(weeklyUsedPercent: 5) },
                              readGrok: { throw GrokQuotaCacheError.expired })
        store.grokSnapshot = GrokQuotaSnapshot(usedPercent: 20)
        await store.refresh()
        XCTAssertEqual(store.snapshot.weeklyRemainingPercent, 95)
        XCTAssertNil(store.grokSnapshot.remainingPercent)
        XCTAssertNotNil(store.grokSnapshot.errorMessage)
    }

    @MainActor
    func testGrokPublishesWhileCodexIsStillWaiting() async {
        var resumeCodex: CheckedContinuation<QuotaSnapshot, Never>?
        let codexStarted = expectation(description: "Codex read started")
        let grokPublished = expectation(description: "Grok published")
        let store = QuotaStore(automaticallyRefresh: false,
                              detectProviders: { [.codex, .grok] },
                              readCodex: {
            await withCheckedContinuation { continuation in
                resumeCodex = continuation
                codexStarted.fulfill()
            }
        }, readGrok: { GrokQuotaSnapshot(usedPercent: 10) })
        let subscription = store.$grokSnapshot.dropFirst().sink { snapshot in
            if snapshot.remainingPercent == 90 { grokPublished.fulfill() }
        }
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [codexStarted, grokPublished], timeout: 2)
        XCTAssertNil(store.snapshot.weeklyUsedPercent)
        resumeCodex?.resume(returning: QuotaSnapshot(weeklyUsedPercent: 3))
        await refresh.value
        subscription.cancel()
        XCTAssertEqual(store.snapshot.weeklyRemainingPercent, 97)
    }

    @MainActor
    func testAgyFailureClearsItsOldQuotaAndPreservesCodexAndGrok() async {
        let store = QuotaStore(automaticallyRefresh: false,
                              detectProviders: { [.codex, .grok, .agy] },
                              readCodex: { QuotaSnapshot(weeklyUsedPercent: 5) },
                              readGrok: { GrokQuotaSnapshot(usedPercent: 10) },
                              readAgy: { throw AgyQuotaError.signedOut })
        store.agySnapshot = AgyQuotaSnapshot(groups: [
            AgyQuotaGroup(name: "Gemini Models", buckets: [
                AgyQuotaBucket(id: "gemini-weekly", window: "weekly", remainingFraction: 0.9, resetAt: nil)
            ])
        ], remainingCredits: 10)
        await store.refresh()
        XCTAssertEqual(store.snapshot.weeklyRemainingPercent, 95)
        XCTAssertEqual(store.grokSnapshot.remainingPercent, 90)
        XCTAssertNil(store.agySnapshot.primaryWeeklyBucket)
        XCTAssertEqual(store.agySnapshot.errorMessage, AgyQuotaError.signedOut.errorDescription)
    }

    @MainActor
    func testDefaultRefreshIntervalIsThreeMinutes() {
        XCTAssertEqual(QuotaStore.refreshInterval, .seconds(180))
    }
}
