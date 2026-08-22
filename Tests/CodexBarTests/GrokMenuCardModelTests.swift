import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct GrokMenuCardModelTests {
    @Test
    func `weekly CLI quota shows projection and pace marker`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == "7% in deficit")
        #expect(metric.detailRightText == "Runs out in 3d")
        #expect(metric.pacePercent != nil)
        #expect(metric.paceOnTop == false)
    }

    @Test
    func `weekly web quota infers projection from reset date`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == "7% in deficit")
        #expect(metric.detailRightText == "Runs out in 3d")
        #expect(metric.pacePercent != nil)
        #expect(metric.paceOnTop == false)
    }

    @Test
    func `weekly web quota beyond default duration does not show projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(8 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `monthly quota does not show weekly projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: 30 * 24 * 60,
                resetsAt: now.addingTimeInterval(20 * 24 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Monthly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `weekly web quota near reset keeps its label without projection`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil))

        let metric = try #require(model.metrics.first { $0.id == "primary" })
        #expect(metric.title == "Weekly")
        #expect(metric.detailLeftText == nil)
        #expect(metric.detailRightText == nil)
        #expect(metric.pacePercent == nil)
    }

    @Test
    func `weekly web quota near reset keeps its label in the detail menu`() throws {
        let suite = "GrokMenuCardModelTests-detail-menu"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 50,
                    windowMinutes: nil,
                    resetsAt: now.addingTimeInterval(2 * 3600),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: now,
                identity: nil),
            provider: .grok)

        let descriptor = MenuDescriptor.build(
            provider: .grok,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains(where: { $0.hasPrefix("Weekly:") }))
        #expect(!lines.contains(where: { $0.hasPrefix("Credits:") }))
    }

    @Test
    func `inline dashboard shows today period and local logs disclaimer`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.grok])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-14",
                    inputTokens: 100,
                    outputTokens: 50,
                    totalTokens: 150,
                    costUSD: 0.12,
                    modelsUsed: ["grok-code-fast-1"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "grok-code-fast-1",
                            costUSD: 0.12,
                            totalTokens: 150),
                    ]),
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: ["grok-code-fast-1"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "grok-code-fast-1",
                            costUSD: 0.25,
                            totalTokens: 275),
                    ]),
            ],
            updatedAt: now)

        let model = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            UsageMenuCardView.Model.make(.init(
                provider: .grok,
                metadata: metadata,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 10,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: now),
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: tokenSnapshot,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: true,
                costSummaryInlineEnabled: true,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))
        }

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.first { $0.title == "Today" }?.value == "$0.25")
        #expect(dashboard.kpis.first { $0.title == "30d cost" }?.value == "$0.37")
        #expect(dashboard.detailLines.contains("Estimated from local Grok CLI logs · not a subscription bill"))
    }

    @Test
    func `global cost summary style can disable inline dashboard`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.grok])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-14",
                    inputTokens: 100,
                    outputTokens: 50,
                    totalTokens: 150,
                    costUSD: 0.12,
                    modelsUsed: ["grok-code-fast-1"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "grok-code-fast-1",
                            costUSD: 0.12,
                            totalTokens: 150),
                    ]),
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: ["grok-code-fast-1"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "grok-code-fast-1",
                            costUSD: 0.25,
                            totalTokens: 275),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .grok,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 10,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard == nil)
    }

    private static func model(now: Date, window: RateWindow) throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[.grok])
        let snapshot = UsageSnapshot(
            primary: window,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)
        return UsageMenuCardView.Model.make(.init(
            provider: .grok,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }
}
