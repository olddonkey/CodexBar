import Foundation

/// Window narrowing lives beside the snapshot type; it is split out to keep `CostUsageModels.swift`
/// within the repository's file-length limit.
extension CostUsageTokenSnapshot {
    /// Reprojects this snapshot from its retained daily rows into a smaller rolling window.
    public func narrowed(toHistoryDays requestedDays: Int, calendar: Calendar = .current) -> Self {
        let days = min(max(1, requestedDays), max(1, self.historyDays))
        let today = calendar.startOfDay(for: self.updatedAt)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let startKey = CostUsageLocalDay.key(from: start, calendar: calendar)
        let endKey = CostUsageLocalDay.key(from: today, calendar: calendar)
        let entries = self.daily.filter { entry in
            guard let dayKey = Self.localDayKey(for: entry.date, calendar: calendar) else { return false }
            return dayKey >= startKey && dayKey <= endKey
        }
        let derived = CostUsageFetcher.tokenSnapshot(
            from: CostUsageDailyReport(data: entries, summary: nil),
            now: self.updatedAt,
            historyDays: days,
            useCurrentLocalDayForSession: true,
            calendar: calendar,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished,
            meteredCostUSD: days == self.historyDays ? self.meteredCostUSD : nil,
            costProvenance: Self.narrowedProvenance(
                snapshot: self.costProvenance,
                entries: entries,
                includesMetered: days == self.historyDays && self.meteredCostUSD != nil),
            credentialScopeFingerprint: self.credentialScopeFingerprint,
            historyLabel: self.historyLabel,
            projects: self.projects,
            sessions: self.sessions,
            updatedAt: self.updatedAt)
        let sessionRequests: Int? = if let current = Self.entry(
            in: entries,
            forLocalDayContaining: self.updatedAt,
            calendar: calendar)
        {
            current.requestCount
        } else if !entries.isEmpty || self.historyCoverageIsEstablished {
            0
        } else {
            nil
        }
        let allEntriesCarryRequests = !entries.isEmpty && entries.allSatisfy { $0.requestCount != nil }
        let totalRequests: Int? = if allEntriesCarryRequests {
            CostUsageDailyReport.completeCountSum(entries.map(\.requestCount))
        } else if self.historyCoverageIsEstablished, entries.isEmpty {
            0
        } else {
            nil
        }
        return Self(
            sessionTokens: derived.sessionTokens,
            sessionCostUSD: derived.sessionCostUSD,
            sessionRequests: sessionRequests,
            last30DaysTokens: derived.last30DaysTokens,
            last30DaysCostUSD: derived.last30DaysCostUSD,
            last30DaysRequests: totalRequests,
            currencyCode: self.currencyCode,
            historyDays: days,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished,
            historyLabel: self.historyLabel,
            meteredCostUSD: derived.meteredCostUSD,
            costProvenance: Self.narrowedProvenance(
                snapshot: self.costProvenance,
                entries: entries,
                includesMetered: derived.meteredCostUSD != nil),
            credentialScopeFingerprint: self.credentialScopeFingerprint,
            daily: entries,
            projects: self.projects,
            sessions: self.sessions,
            hourly: self.hourly,
            updatedAt: self.updatedAt)
    }

    /// A narrowed window can exclude every priced row it inherited its disclosure from, so the derived
    /// snapshot must describe the rows it kept. This is the same narrowing the window summary applies; it
    /// deliberately does not re-derive which *kind* of cost the surviving rows carry, because per-row
    /// coverage counts mean different things to different providers.
    private static func narrowedProvenance(
        snapshot: CostProvenance,
        entries: [CostUsageDailyReport.Entry],
        includesMetered: Bool) -> CostProvenance
    {
        CostProvenance.forWindow(
            snapshot: snapshot,
            hasWindowCosts: entries.contains { $0.costUSD != nil },
            includesMetered: includesMetered)
    }
}
