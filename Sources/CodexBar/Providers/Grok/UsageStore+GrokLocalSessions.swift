import CodexBarCore
import Foundation

extension UsageStore {
    func grokLocalTokenSnapshot(
        from providerSnapshot: UsageSnapshot?,
        historyDays: Int) -> CostUsageTokenSnapshot?
    {
        let published = providerSnapshot?.costUsage ?? (providerSnapshot == nil ? self.tokenSnapshots[.grok] : nil)
        guard let published else { return nil }
        let days = max(1, historyDays)
        guard published.historyDays != days else { return published }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: published.updatedAt)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let firstDay = Self.grokLocalDayKey(for: start, calendar: calendar),
              let lastDay = Self.grokLocalDayKey(for: today, calendar: calendar)
        else { return nil }
        let daily = published.daily.filter { $0.date >= firstDay && $0.date <= lastDay }
        guard !daily.isEmpty else { return nil }
        let tokens = daily.compactMap(\.totalTokens)
        let requests = daily.compactMap(\.requestCount)
        // Tokens and requests are recomputed from the retained days, so the cost has to be too. Copying the
        // published total would render the full 365-day amount beside a 30-day token count.
        let costs = daily.compactMap(\.costUSD)

        return CostUsageTokenSnapshot(
            sessionTokens: published.sessionTokens,
            sessionCostUSD: published.sessionCostUSD,
            sessionRequests: published.sessionRequests,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            last30DaysRequests: requests.isEmpty ? nil : requests.reduce(0, +),
            currencyCode: published.currencyCode,
            historyDays: days,
            historyCoverageIsEstablished: published.historyCoverageIsEstablished && published.historyDays >= days,
            historyLabel: published.historyLabel,
            meteredCostUSD: published.meteredCostUSD,
            costProvenance: Self.grokWindowProvenance(published: published.costProvenance, daily: daily),
            credentialScopeFingerprint: published.credentialScopeFingerprint,
            daily: daily,
            projects: published.projects,
            sessions: published.sessions,
            hourly: published.hourly,
            updatedAt: published.updatedAt)
    }

    func loadGrokLocalTokenSnapshot(historyDays: Int) async throws -> CostUsageTokenSnapshot? {
        let summary = try await GrokLocalSessionScanner.summarizeOffMainThread(
            env: self.environmentBase,
            lookbackDays: historyDays)
        return summary.toCostUsageTokenSnapshot(historyDays: historyDays)
    }

    /// The disclosure has to describe the days this window kept. Grok's scanner counts a CLI-recorded turn
    /// as priced and a public-card fallback as estimated, so the retained rows say which sources survived;
    /// a window that kept no priced rows claims nothing.
    private static func grokWindowProvenance(
        published: CostProvenance,
        daily: [CostUsageDailyReport.Entry]) -> CostProvenance
    {
        var counts = CostUsageCoverageCounts()
        for entry in daily {
            counts.merge(entry.coverageCounts)
        }
        guard daily.contains(where: { $0.costUSD != nil }) else { return .unknown }
        switch (counts.priced > 0, counts.estimated > 0) {
        case (true, true): return .mixed
        case (true, false): return .vendorMetered
        case (false, true): return .listPriceEstimate
        case (false, false): return published
        }
    }

    private static func grokLocalDayKey(for date: Date, calendar: Calendar) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
