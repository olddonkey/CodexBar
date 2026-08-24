import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `grok live menu consumers use published local fallback without remote snapshot`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.selectedMenuProvider = .grok
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both

        let metadata = try #require(ProviderRegistry.shared.metadata[.grok])
        settings.setProviderEnabled(provider: .grok, metadata: metadata, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        let formatter = DateFormatter()
        formatter.calendar = settings.costUsageBucketCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = settings.costUsageBucketCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 77,
            sessionCostUSD: 0.07,
            last30DaysTokens: 77,
            last30DaysCostUSD: 0.07,
            daily: [
                CostUsageDailyReport.Entry(
                    date: formatter.string(from: now),
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 77,
                    costUSD: 0.07,
                    modelsUsed: ["grok-4"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now), provider: .grok)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let model = try #require(controller.menuCardModel(for: .grok))
        #expect(model.tokenUsage?.monthLine.contains("77") == true)
        let historySnapshot = try #require(controller.tokenSnapshotForCostHistorySubmenu(provider: .grok))
        #expect(historySnapshot.last30DaysTokens == 77)
        #expect(controller.makeCostHistorySubmenu(provider: .grok) != nil)
    }

    @Test
    func `grok override card does not inherit published local fallback`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true

        let metadata = try #require(ProviderRegistry.shared.metadata[.grok])
        settings.setProviderEnabled(provider: .grok, metadata: metadata, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_777_344_000)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 77,
            sessionCostUSD: 0.07,
            last30DaysTokens: 77,
            last30DaysCostUSD: 0.07,
            daily: [],
            updatedAt: now), provider: .grok)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let model = try #require(controller.menuCardModel(
            for: .grok,
            snapshotOverride: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            forceOverrideCard: true))
        #expect(model.tokenUsage == nil)
    }
}
