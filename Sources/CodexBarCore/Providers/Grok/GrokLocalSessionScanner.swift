import Foundation

/// One local-calendar day of Grok session-token activity.
public struct GrokLocalDailyBucket: Sendable, Equatable {
    public let date: String
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let sessionCount: Int
    public let requestCount: Int
    public let costUSD: Double?
    public let models: [String]
    public let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]
    public let unpricedRequestCount: Int
    public let estimatedRequestCount: Int

    public init(
        date: String,
        inputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int,
        sessionCount: Int,
        requestCount: Int? = nil,
        costUSD: Double? = nil,
        models: [String],
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown] = [],
        unpricedRequestCount: Int = 0,
        estimatedRequestCount: Int = 0)
    {
        self.date = date
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.sessionCount = sessionCount
        self.requestCount = requestCount ?? sessionCount
        self.costUSD = costUSD
        self.models = models
        self.modelBreakdowns = modelBreakdowns
        self.unpricedRequestCount = unpricedRequestCount
        self.estimatedRequestCount = estimatedRequestCount
    }
}

/// Aggregated stats from local `~/.grok/sessions/**/updates.jsonl` files.
/// `signals.json` is metadata-only fallback when a session has no completed turns.
public struct GrokLocalSessionSummary: Sendable {
    public let sessionCount: Int
    public let totalTokens: Int
    public let lastSessionAt: Date?
    public let primaryModel: String?
    public let models: [String]
    public let daily: [GrokLocalDailyBucket]
    public let scannedAt: Date
    public let historyCoverageIsEstablished: Bool

    public init(
        sessionCount: Int,
        totalTokens: Int,
        lastSessionAt: Date?,
        primaryModel: String?,
        models: [String],
        daily: [GrokLocalDailyBucket] = [],
        scannedAt: Date = .init(),
        historyCoverageIsEstablished: Bool = true)
    {
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.lastSessionAt = lastSessionAt
        self.primaryModel = primaryModel
        self.models = models
        self.daily = daily
        self.scannedAt = scannedAt
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
    }

    /// Local tokens priced at public API list rates; this is an estimate, not a Grok bill.
    public func toCostUsageTokenSnapshot(historyDays: Int) -> CostUsageTokenSnapshot? {
        let entries = self.daily.map { bucket in
            CostUsageDailyReport.Entry(
                date: bucket.date,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                cacheCreationTokens: bucket.cacheCreationTokens,
                reasoningTokens: bucket.reasoningTokens,
                totalTokens: bucket.totalTokens,
                requestCount: bucket.requestCount,
                costUSD: bucket.costUSD,
                modelsUsed: bucket.models.isEmpty ? nil : bucket.models,
                modelBreakdowns: bucket.modelBreakdowns.isEmpty ? nil : bucket.modelBreakdowns,
                unpricedRequestCount: bucket.unpricedRequestCount > 0 ? bucket.unpricedRequestCount : nil,
                unmeteredRequestCount: nil,
                estimatedRequestCount: bucket.estimatedRequestCount > 0 ? bucket.estimatedRequestCount : nil)
        }
        guard !entries.isEmpty else { return nil }
        let todayKey = GrokLocalSessionScanner.dayKey(for: self.scannedAt, calendar: .current)
        let today = todayKey.flatMap { key in self.daily.first { $0.date == key } }
        let pricedDays = self.daily.compactMap(\.costUSD)
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            sessionRequests: today?.requestCount,
            last30DaysTokens: self.totalTokens,
            last30DaysCostUSD: pricedDays.isEmpty ? nil : pricedDays.reduce(0, +),
            last30DaysRequests: self.daily.reduce(0) { $0 + $1.requestCount },
            historyDays: historyDays,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished,
            costProvenance: .listPriceEstimate,
            daily: entries,
            updatedAt: self.scannedAt)
    }
}

struct GrokLocalSessionParseCacheMetrics: Sendable, Equatable {
    let fileDecodeCount: Int
    let jsonDecodeCount: Int
}

struct GrokLocalSessionScanLimits: Sendable, Equatable {
    static let production = Self(
        maximumFileBytes: 64 * 1024 * 1024,
        maximumLineBytes: 1024 * 1024,
        maximumTurnsPerFile: 20000,
        maximumSessions: 256,
        maximumDiscoveryEntries: 4096,
        maximumTotalBytes: 256 * 1024 * 1024,
        maximumTotalTurns: 100_000)

    let maximumFileBytes: Int64
    let maximumLineBytes: Int
    let maximumTurnsPerFile: Int
    let maximumSessions: Int
    let maximumDiscoveryEntries: Int
    let maximumTotalBytes: Int64
    let maximumTotalTurns: Int

    init(
        maximumFileBytes: Int64,
        maximumLineBytes: Int,
        maximumTurnsPerFile: Int,
        maximumSessions: Int = 256,
        maximumDiscoveryEntries: Int = 4096,
        maximumTotalBytes: Int64 = 256 * 1024 * 1024,
        maximumTotalTurns: Int = 100_000)
    {
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumTurnsPerFile = max(1, maximumTurnsPerFile)
        self.maximumSessions = max(1, maximumSessions)
        self.maximumDiscoveryEntries = max(1, maximumDiscoveryEntries)
        self.maximumTotalBytes = max(1, maximumTotalBytes)
        self.maximumTotalTurns = max(1, maximumTotalTurns)
    }

    func limitingFileBytes(to maximumFileBytes: Int64) -> Self {
        Self(
            maximumFileBytes: min(self.maximumFileBytes, maximumFileBytes),
            maximumLineBytes: self.maximumLineBytes,
            maximumTurnsPerFile: self.maximumTurnsPerFile,
            maximumSessions: self.maximumSessions,
            maximumDiscoveryEntries: self.maximumDiscoveryEntries,
            maximumTotalBytes: self.maximumTotalBytes,
            maximumTotalTurns: self.maximumTotalTurns)
    }
}

private struct GrokParsedTokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cachedReadTokens: Int
    let cacheCreationTokens: Int
    let reasoningTokens: Int
    let modelCalls: Int?
}

private struct GrokParsedTurn: Sendable {
    let timestamp: Date
    let usage: GrokParsedTokenUsage
    let modelUsage: [String: GrokParsedTokenUsage]
}

private struct GrokParsedTurnBatch: Sendable {
    let turns: [GrokParsedTurn]
    let historyCoverageIsEstablished: Bool
}

private struct GrokTurnDecodeResult: Sendable {
    let batch: GrokParsedTurnBatch
    let jsonDecodeCount: Int
    let cacheable: Bool
}

private final class GrokLocalSessionParseCache: @unchecked Sendable {
    private struct Identity: Equatable {
        let size: Int
        let mtimeIntervalSince1970: TimeInterval
        let limits: GrokLocalSessionScanLimits
    }

    private struct Entry {
        let identity: Identity
        let batch: GrokParsedTurnBatch
        var accessOrdinal: UInt64
    }

    private static let maximumEntries = 64
    private static let maximumCachedTurns = 50000
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var fileDecodeCount = 0
    private var jsonDecodeCount = 0
    private var fileDecodeCountByPath: [String: Int] = [:]
    private var jsonDecodeCountByPath: [String: Int] = [:]
    private var accessOrdinal: UInt64 = 0

    func turns(
        path: String,
        size: Int,
        mtimeIntervalSince1970: TimeInterval,
        limits: GrokLocalSessionScanLimits,
        decode: () -> GrokTurnDecodeResult) -> GrokParsedTurnBatch
    {
        let identity = Identity(
            size: size,
            mtimeIntervalSince1970: mtimeIntervalSince1970,
            limits: limits)
        self.lock.lock()
        let observedIdentity = self.entries[path]?.identity
        if var entry = self.entries[path], entry.identity == identity {
            entry.accessOrdinal = self.nextAccessOrdinal()
            self.entries[path] = entry
            self.lock.unlock()
            return entry.batch
        }
        self.lock.unlock()

        let decoded = decode()
        self.lock.lock()
        defer { self.lock.unlock() }
        self.fileDecodeCount += 1
        self.jsonDecodeCount += decoded.jsonDecodeCount
        let metricsPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.fileDecodeCountByPath[metricsPath, default: 0] += 1
        self.jsonDecodeCountByPath[metricsPath, default: 0] += decoded.jsonDecodeCount
        guard decoded.cacheable else { return decoded.batch }
        if var entry = self.entries[path], entry.identity == identity {
            entry.accessOrdinal = self.nextAccessOrdinal()
            self.entries[path] = entry
            return entry.batch
        }
        if self.entries[path]?.identity != observedIdentity {
            // A concurrent scan cached a different file identity, or evicted this one, while decoding.
            return decoded.batch
        }
        self.entries[path] = Entry(
            identity: identity,
            batch: decoded.batch,
            accessOrdinal: self.nextAccessOrdinal())
        self.trimToLimits()
        return decoded.batch
    }

    func retainEntries(at visitedPaths: Set<String>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries = self.entries.filter { visitedPaths.contains($0.key) }
        self.trimToLimits()
    }

    func entryCount() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries.count
    }

    func cachedTurnCount() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries.values.reduce(0) { $0 + $1.batch.turns.count }
    }

    func metrics() -> GrokLocalSessionParseCacheMetrics {
        self.lock.lock()
        defer { self.lock.unlock() }
        return GrokLocalSessionParseCacheMetrics(
            fileDecodeCount: self.fileDecodeCount,
            jsonDecodeCount: self.jsonDecodeCount)
    }

    func metrics(pathPrefix: String) -> GrokLocalSessionParseCacheMetrics {
        self.lock.lock()
        defer { self.lock.unlock() }
        let resolvedPrefix = URL(fileURLWithPath: pathPrefix).resolvingSymlinksInPath().path
        let descendantPrefix = resolvedPrefix.hasSuffix("/") ? resolvedPrefix : "\(resolvedPrefix)/"
        let belongsToPrefix: (String) -> Bool = { path in
            path == resolvedPrefix || path.hasPrefix(descendantPrefix)
        }
        return GrokLocalSessionParseCacheMetrics(
            fileDecodeCount: self.fileDecodeCountByPath
                .filter { belongsToPrefix($0.key) }
                .reduce(0) { $0 + $1.value },
            jsonDecodeCount: self.jsonDecodeCountByPath
                .filter { belongsToPrefix($0.key) }
                .reduce(0) { $0 + $1.value })
    }

    func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeAll()
        self.fileDecodeCount = 0
        self.jsonDecodeCount = 0
        self.fileDecodeCountByPath.removeAll()
        self.jsonDecodeCountByPath.removeAll()
        self.accessOrdinal = 0
    }

    private func nextAccessOrdinal() -> UInt64 {
        self.accessOrdinal &+= 1
        return self.accessOrdinal
    }

    private func trimToLimits() {
        var cachedTurns = self.entries.values.reduce(0) { $0 + $1.batch.turns.count }
        while self.entries.count > Self.maximumEntries || cachedTurns > Self.maximumCachedTurns {
            guard let victim = self.entries.min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal }) else {
                return
            }
            cachedTurns -= victim.value.batch.turns.count
            self.entries.removeValue(forKey: victim.key)
        }
    }
}

public enum GrokLocalSessionScanner {
    public static let defaultLookbackDays = 30
    public static let maximumLookbackDays = 365

    private static let maximumValidatedModelCalls = 10000

    private struct FileIdentity {
        let size: Int
        let modificationDate: Date
    }

    private struct RecentSessionSelection {
        let paths: [String]
        let historyCoverageIsEstablished: Bool
    }

    private struct MutableModelBreakdown {
        var inputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var totalTokens = 0
        var requestCount = 0
        var costUSD = 0.0
        var hasPricedCost = false
    }

    private struct MutableDailyBucket {
        var inputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var totalTokens = 0
        var requestCount = 0
        var sessionIDs: Set<String> = []
        var modelCounts: [String: Int] = [:]
        var modelBreakdowns: [String: MutableModelBreakdown] = [:]
        var costUSD = 0.0
        var hasPricedCost = false
        var unpricedRequestCount = 0
        var estimatedRequestCount = 0
    }

    private struct PricingContext {
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let customPricing: CostUsageCustomPricing?
    }

    private struct ScanAggregation {
        var modelCounts: [String: Int] = [:]
        var daily: [String: MutableDailyBucket] = [:]
    }

    private static let parseCache = GrokLocalSessionParseCache()
    private static let turnCompletedNeedle = Data("turn_completed".utf8)

    /// Request a models.dev refresh, then scan using the best catalog available.
    /// A stale catalog keeps pricing the scan while it refreshes in the background. With no catalog at all, the first
    /// scan waits for the initial attempt so a successful refresh is reflected in the snapshot that callers publish.
    public static func summarizeRequestingPricingRefresh(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) async -> GrokLocalSessionSummary
    {
        await self.summarizeRequestingPricingRefresh(
            env: env,
            fileManager: fileManager,
            lookbackDays: lookbackDays,
            now: now,
            modelsDevCacheRoot: nil)
        {
            await ModelsDevPricingPipeline.refreshIfNeeded(now: now)
        }
    }

    static func summarizeRequestingPricingRefresh(
        env: [String: String],
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init(),
        modelsDevCacheRoot: URL?,
        requestPricingRefresh: @escaping @Sendable () async -> Void) async -> GrokLocalSessionSummary
    {
        let hasCachedCatalog = ModelsDevCache.load(now: now, cacheRoot: modelsDevCacheRoot).artifact != nil
        if hasCachedCatalog {
            Task.detached(priority: .utility) {
                await requestPricingRefresh()
            }
        } else {
            await requestPricingRefresh()
        }
        return self.summarize(
            env: env,
            fileManager: fileManager,
            lookbackDays: lookbackDays,
            now: now,
            pricing: PricingContext(
                modelsDevCatalog: nil,
                modelsDevCacheRoot: modelsDevCacheRoot,
                customPricing: .empty))
    }

    /// Walk `~/.grok/sessions/<encoded_cwd>/<session_id>/updates.jsonl` and aggregate completed turns.
    public static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) -> GrokLocalSessionSummary
    {
        self.summarize(
            env: env,
            fileManager: fileManager,
            lookbackDays: lookbackDays,
            now: now,
            pricing: PricingContext(
                modelsDevCatalog: nil,
                modelsDevCacheRoot: nil,
                customPricing: .empty))
    }

    static func summarize(
        env: [String: String],
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init(),
        modelsDevCatalog: ModelsDevCatalog,
        modelsDevCacheRoot: URL? = nil,
        customPricing: CostUsageCustomPricing? = .empty,
        scanLimits: GrokLocalSessionScanLimits = .production) -> GrokLocalSessionSummary
    {
        self.summarize(
            env: env,
            fileManager: fileManager,
            lookbackDays: lookbackDays,
            now: now,
            pricing: PricingContext(
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot,
                customPricing: customPricing),
            scanLimits: scanLimits)
    }

    static func summarize(
        env: [String: String],
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init(),
        modelsDevCacheRoot: URL,
        customPricing: CostUsageCustomPricing? = .empty) -> GrokLocalSessionSummary
    {
        self.summarize(
            env: env,
            fileManager: fileManager,
            lookbackDays: lookbackDays,
            now: now,
            pricing: PricingContext(
                modelsDevCatalog: nil,
                modelsDevCacheRoot: modelsDevCacheRoot,
                customPricing: customPricing))
    }

    private static func summarize(
        env: [String: String],
        fileManager: FileManager,
        lookbackDays: Int,
        now: Date,
        pricing: PricingContext,
        scanLimits: GrokLocalSessionScanLimits = .production) -> GrokLocalSessionSummary
    {
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        var visitedCachePaths: Set<String> = []
        defer { self.parseCache.retainEntries(at: visitedCachePaths) }
        let calendar = Calendar.current
        let lookbackCutoff = calendar.date(byAdding: .day, value: -max(0, lookbackDays), to: now) ?? now
        guard let sessionSelection = self.recentSessionPaths(
            root: root,
            fileManager: fileManager,
            lookbackCutoff: lookbackCutoff,
            maximumCount: scanLimits.maximumSessions,
            maximumDiscoveryEntries: scanLimits.maximumDiscoveryEntries)
        else {
            return self.emptySummary(now: now)
        }

        var sessionCount = 0
        var lastSessionAt: Date?
        var aggregation = ScanAggregation()
        var remainingTotalBytes = scanLimits.maximumTotalBytes
        var remainingTotalTurns = scanLimits.maximumTotalTurns
        var historyCoverageIsEstablished = sessionSelection.historyCoverageIsEstablished

        for sessionPath in sessionSelection.paths {
            guard !Task.isCancelled else { return self.emptySummary(now: now) }
            guard remainingTotalBytes > 0, remainingTotalTurns > 0 else {
                historyCoverageIsEstablished = false
                break
            }
            let sessionURL = URL(fileURLWithPath: sessionPath, isDirectory: true)
            var updatesYieldedCompletedTurns = false
            let updates = sessionURL.appendingPathComponent("updates.jsonl")
            if let identity = self.fileIdentity(for: updates),
               identity.modificationDate >= lookbackCutoff
            {
                let fileByteLimit = min(scanLimits.maximumFileBytes, remainingTotalBytes)
                let fileLimits = scanLimits.limitingFileBytes(to: fileByteLimit)
                remainingTotalBytes -= min(Int64(max(0, identity.size)), fileByteLimit)
                visitedCachePaths.insert(updates.path)
                let parsed = self.parseCache.turns(
                    path: updates.path,
                    size: identity.size,
                    mtimeIntervalSince1970: identity.modificationDate.timeIntervalSince1970,
                    limits: fileLimits)
                {
                    self.decodeTurns(at: updates, fileSize: identity.size, limits: fileLimits)
                }
                guard !Task.isCancelled else { return self.emptySummary(now: now) }
                historyCoverageIsEstablished = historyCoverageIsEstablished
                    && parsed.historyCoverageIsEstablished
                updatesYieldedCompletedTurns = !parsed.turns.isEmpty
                var currentTurns = parsed.turns.filter { $0.timestamp >= lookbackCutoff }
                if currentTurns.count > remainingTotalTurns {
                    currentTurns = Array(currentTurns.suffix(remainingTotalTurns))
                    historyCoverageIsEstablished = false
                }
                remainingTotalTurns -= currentTurns.count
                if !currentTurns.isEmpty {
                    sessionCount += 1
                    for turn in currentTurns {
                        guard !Task.isCancelled else { return self.emptySummary(now: now) }
                        if turn.timestamp > (lastSessionAt ?? Date.distantPast) {
                            lastSessionAt = turn.timestamp
                        }
                        self.aggregate(
                            turn: turn,
                            sessionPath: sessionPath,
                            calendar: calendar,
                            aggregation: &aggregation,
                            pricing: pricing)
                    }
                }
            }

            let fallback = sessionURL.appendingPathComponent("signals.json")
            if !updatesYieldedCompletedTurns,
               let identity = self.fileIdentity(for: fallback),
               identity.modificationDate >= lookbackCutoff
            {
                let signalByteLimit = min(Int64(scanLimits.maximumLineBytes), remainingTotalBytes)
                remainingTotalBytes -= min(Int64(max(0, identity.size)), signalByteLimit)
                if Int64(identity.size) > signalByteLimit {
                    historyCoverageIsEstablished = false
                } else if let metadataModels = self.readSignalsMetadata(
                    at: fallback,
                    maximumBytes: Int(signalByteLimit))
                {
                    sessionCount += 1
                    if identity.modificationDate > (lastSessionAt ?? Date.distantPast) {
                        lastSessionAt = identity.modificationDate
                    }
                    for model in metadataModels {
                        aggregation.modelCounts[model, default: 0] += 1
                    }
                }
            }
        }

        let sortedModels = self.sortedModels(aggregation.modelCounts)
        let buckets = aggregation.daily.keys.sorted().map { day in
            self.finalize(day: day, bucket: aggregation.daily[day] ?? MutableDailyBucket())
        }
        return GrokLocalSessionSummary(
            sessionCount: sessionCount,
            totalTokens: buckets.reduce(0) { $0 + $1.totalTokens },
            lastSessionAt: lastSessionAt,
            primaryModel: sortedModels.first,
            models: sortedModels,
            daily: buckets,
            scannedAt: now,
            historyCoverageIsEstablished: historyCoverageIsEstablished)
    }

    public static func summarizeOffMainThread(
        env: [String: String],
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) async throws -> GrokLocalSessionSummary
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try checkCancellation()
            let summary = Self.summarize(env: env, lookbackDays: lookbackDays, now: now)
            try checkCancellation()
            return summary
        }
    }

    static func parseCacheMetricsForTesting() -> GrokLocalSessionParseCacheMetrics {
        self.parseCache.metrics()
    }

    static func parseCacheMetricsForTesting(pathPrefix: String) -> GrokLocalSessionParseCacheMetrics {
        self.parseCache.metrics(pathPrefix: pathPrefix)
    }

    static func resetParseCacheForTesting() {
        self.parseCache.reset()
    }

    static func parseCacheEntryCountForTesting() -> Int {
        self.parseCache.entryCount()
    }

    static func parseCacheTurnCountForTesting() -> Int {
        self.parseCache.cachedTurnCount()
    }

    private static func emptySummary(now: Date) -> GrokLocalSessionSummary {
        GrokLocalSessionSummary(
            sessionCount: 0,
            totalTokens: 0,
            lastSessionAt: nil,
            primaryModel: nil,
            models: [],
            scannedAt: now)
    }

    private static func fileIdentity(for url: URL) -> FileIdentity? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = values.fileSize,
              let modificationDate = values.contentModificationDate
        else { return nil }
        return FileIdentity(size: size, modificationDate: modificationDate)
    }

    private static func recentSessionPaths(
        root: URL,
        fileManager: FileManager,
        lookbackCutoff: Date,
        maximumCount: Int,
        maximumDiscoveryEntries: Int) -> RecentSessionSelection?
    {
        guard let rootEnum = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        var sessionModificationDates: [String: Date] = [:]
        var historyCoverageIsEstablished = true
        let trimThreshold = maximumCount > Int.max / 2 ? Int.max : maximumCount * 2
        var discoveryEntryCount = 0
        while discoveryEntryCount < maximumDiscoveryEntries,
              let url = rootEnum.nextObject() as? URL
        {
            discoveryEntryCount += 1
            guard !Task.isCancelled else { return nil }
            let name = url.lastPathComponent
            guard name == "updates.jsonl" || name == "signals.json" else { continue }
            guard let identity = self.fileIdentity(for: url),
                  identity.modificationDate >= lookbackCutoff
            else { continue }
            let sessionPath = url.deletingLastPathComponent().path
            sessionModificationDates[sessionPath] = max(
                sessionModificationDates[sessionPath] ?? .distantPast,
                identity.modificationDate)
            if sessionModificationDates.count > trimThreshold {
                historyCoverageIsEstablished = false
                self.trimRecentSessions(&sessionModificationDates, maximumCount: maximumCount)
            }
        }
        if discoveryEntryCount == maximumDiscoveryEntries {
            // DirectoryEnumerator is lazy, so stopping here bounds both traversal and metadata I/O. Conservatively
            // mark coverage incomplete at the boundary because there may be undiscovered sessions after this point.
            historyCoverageIsEstablished = false
        }
        if sessionModificationDates.count > maximumCount {
            historyCoverageIsEstablished = false
            self.trimRecentSessions(&sessionModificationDates, maximumCount: maximumCount)
        }
        let paths = sessionModificationDates.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
        return RecentSessionSelection(
            paths: paths,
            historyCoverageIsEstablished: historyCoverageIsEstablished)
    }

    private static func trimRecentSessions(
        _ sessions: inout [String: Date],
        maximumCount: Int)
    {
        guard sessions.count > maximumCount else { return }
        let recent = sessions.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.prefix(maximumCount)
        sessions = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
    }

    private static func decodeTurns(
        at url: URL,
        fileSize: Int,
        limits: GrokLocalSessionScanLimits) -> GrokTurnDecodeResult
    {
        var turns: [GrokParsedTurn] = []
        var jsonDecodeCount = 0
        let boundedFileSize = max(0, Int64(fileSize))
        let startOffset = max(0, boundedFileSize - limits.maximumFileBytes)
        var historyCoverageIsEstablished = startOffset == 0
        var cacheable = true
        var droppedTurns = false
        let compactionThreshold = limits.maximumTurnsPerFile > Int.max / 2
            ? Int.max
            : limits.maximumTurnsPerFile * 2

        do {
            try CostUsageJsonl.scan(
                fileURL: url,
                offset: startOffset,
                maxLineBytes: limits.maximumLineBytes,
                prefixBytes: limits.maximumLineBytes,
                maxBytesToRead: limits.maximumFileBytes,
                checkCancellation: {
                    if Task.isCancelled { throw CancellationError() }
                },
                onLine: { line in
                    guard line.bytes.range(of: self.turnCompletedNeedle) != nil else { return }
                    jsonDecodeCount += 1
                    guard !line.wasTruncated else {
                        historyCoverageIsEstablished = false
                        return
                    }
                    guard let turn = self.decodeTurnWithScopedAutoreleasePool(line.bytes) else { return }
                    turns.append(turn)
                    if turns.count > compactionThreshold {
                        turns.removeFirst(limits.maximumTurnsPerFile)
                        droppedTurns = true
                    }
                })
        } catch {
            historyCoverageIsEstablished = false
            cacheable = false
        }

        if turns.count > limits.maximumTurnsPerFile {
            turns.removeFirst(turns.count - limits.maximumTurnsPerFile)
            droppedTurns = true
        }
        return GrokTurnDecodeResult(
            batch: GrokParsedTurnBatch(
                turns: turns,
                historyCoverageIsEstablished: historyCoverageIsEstablished && !droppedTurns),
            jsonDecodeCount: jsonDecodeCount,
            cacheable: cacheable)
    }

    private static func decodeTurnWithScopedAutoreleasePool(_ data: Data) -> GrokParsedTurn? {
        #if canImport(Darwin)
        autoreleasepool { self.decodeTurn(data) }
        #else
        self.decodeTurn(data)
        #endif
    }

    private static func decodeTurn(_ data: Data) -> GrokParsedTurn? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = self.integer(json["timestamp"]),
              let params = json["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usageObject = update["usage"] as? [String: Any],
              !usageObject.isEmpty
        else { return nil }

        let usage = self.tokenUsage(from: usageObject)
        var modelUsage: [String: GrokParsedTokenUsage] = [:]
        if let models = usageObject["modelUsage"] as? [String: Any] {
            for (rawSKU, value) in models {
                let sku = rawSKU.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sku.isEmpty, let object = value as? [String: Any], !object.isEmpty else { continue }
                modelUsage[sku] = self.tokenUsage(from: object)
            }
        }
        return GrokParsedTurn(
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            usage: usage,
            modelUsage: modelUsage)
    }

    private static func tokenUsage(from object: [String: Any]) -> GrokParsedTokenUsage {
        let inputTokens = max(0, self.integer(object["inputTokens"]) ?? 0)
        let outputTokens = max(0, self.integer(object["outputTokens"]) ?? 0)
        let computedTotalTokens = inputTokens + outputTokens
        let reportedTotalTokens = max(0, self.integer(object["totalTokens"]) ?? 0)
        return GrokParsedTokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: reportedTotalTokens > 0 || computedTotalTokens == 0
                ? reportedTotalTokens
                : computedTotalTokens,
            cachedReadTokens: max(0, self.integer(object["cachedReadTokens"]) ?? 0),
            cacheCreationTokens: max(0, self.integer(object["cacheCreationTokens"]) ?? 0),
            reasoningTokens: max(0, self.integer(object["reasoningTokens"]) ?? 0),
            modelCalls: self.integer(object["modelCalls"]))
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func readSignalsMetadata(at url: URL, maximumBytes: Int) -> [String]? {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        guard let data = try? handle.read(upToCount: readLimit),
              data.count <= maximumBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var models: [String] = []
        if let primary = self.nonEmptyString(json["primaryModelId"] as? String) {
            models.append(primary)
        }
        if let used = json["modelsUsed"] as? [String] {
            models.append(contentsOf: used.compactMap(self.nonEmptyString))
        }
        return Array(Set(models)).sorted()
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func aggregate(
        turn: GrokParsedTurn,
        sessionPath: String,
        calendar: Calendar,
        aggregation: inout ScanAggregation,
        pricing: PricingContext)
    {
        guard let day = self.dayKey(for: turn.timestamp, calendar: calendar) else { return }
        var bucket = aggregation.daily[day] ?? MutableDailyBucket()
        bucket.inputTokens += turn.usage.inputTokens
        bucket.cacheReadTokens += turn.usage.cachedReadTokens
        bucket.cacheCreationTokens += turn.usage.cacheCreationTokens
        bucket.outputTokens += turn.usage.outputTokens
        bucket.reasoningTokens += turn.usage.reasoningTokens
        bucket.totalTokens += turn.usage.totalTokens
        bucket.sessionIDs.insert(sessionPath)

        if turn.modelUsage.isEmpty {
            let requests = self.requestCount(for: turn.usage)
            bucket.requestCount += requests
            bucket.unpricedRequestCount += requests
        }
        for (sku, usage) in turn.modelUsage {
            let requests = self.requestCount(for: usage)
            bucket.requestCount += requests
            aggregation.modelCounts[sku, default: 0] += requests
            bucket.modelCounts[sku, default: 0] += requests
            var breakdown = bucket.modelBreakdowns[sku] ?? MutableModelBreakdown()
            breakdown.inputTokens += usage.inputTokens
            breakdown.cacheReadTokens += usage.cachedReadTokens
            breakdown.cacheCreationTokens += usage.cacheCreationTokens
            breakdown.outputTokens += usage.outputTokens
            breakdown.reasoningTokens += usage.reasoningTokens
            breakdown.totalTokens += usage.totalTokens
            breakdown.requestCount += requests

            if let cost = self.costUSD(
                sku: sku,
                usage: usage,
                pricingDate: turn.timestamp,
                pricing: pricing)
            {
                breakdown.costUSD += cost
                breakdown.hasPricedCost = true
                bucket.costUSD += cost
                bucket.hasPricedCost = true
            } else {
                bucket.unpricedRequestCount += requests
            }
            bucket.modelBreakdowns[sku] = breakdown
        }
        aggregation.daily[day] = bucket
    }

    private static func costUSD(
        sku: String,
        usage: GrokParsedTokenUsage,
        pricingDate: Date,
        pricing: PricingContext) -> Double?
    {
        let model = "xai/\(sku)"
        guard let resolvedPricing = CostUsagePricing.resolvedCodexPricing(
            model: model,
            pricingDate: pricingDate,
            modelsDevCatalog: pricing.modelsDevCatalog,
            modelsDevCacheRoot: pricing.modelsDevCacheRoot)
        else { return nil }

        guard let callCount = self.validatedModelCallCount(for: usage) else {
            if let threshold = resolvedPricing.thresholdTokens,
               usage.inputTokens > threshold
            {
                return nil
            }
            return CostUsagePricing.codexCostUSD(
                pricing: resolvedPricing,
                inputTokens: usage.inputTokens,
                cachedInputTokens: usage.cachedReadTokens,
                cacheWriteInputTokens: usage.cacheCreationTokens,
                outputTokens: usage.outputTokens)
        }

        // Even splitting is intentionally an approximation: context normally grows within a turn,
        // so mean per-call inputs under-tier later calls. In a measured 27-turn sample this was about
        // 4% below the vendor tick proxy overall and 26% low on one 28-call turn. Vendor ticks still
        // do not drive displayed cost; the split is retained because aggregate tiering overstates it.
        return self.syntheticCallGroups(
            usage: usage,
            callCount: callCount,
            pricing: resolvedPricing)
            .reduce(0) { partial, group in
                partial + CostUsagePricing.codexCostUSD(
                    pricing: self.fixedTierPricing(resolvedPricing, usesLongContextRates: group.isLongContext),
                    inputTokens: group.inputTokens,
                    cachedInputTokens: group.cachedReadTokens,
                    cacheWriteInputTokens: group.cacheCreationTokens,
                    outputTokens: group.outputTokens)
            }
    }

    private static func distributed(_ total: Int, index: Int, count: Int) -> Int {
        let quotient = total / count
        return quotient + (index < total % count ? 1 : 0)
    }

    private struct SyntheticCallGroup {
        let inputTokens: Int
        let cachedReadTokens: Int
        let cacheCreationTokens: Int
        let outputTokens: Int
        let isLongContext: Bool
    }

    private static func validatedModelCallCount(for usage: GrokParsedTokenUsage) -> Int? {
        guard let modelCalls = usage.modelCalls,
              modelCalls > 0,
              modelCalls <= usage.inputTokens,
              modelCalls <= self.maximumValidatedModelCalls
        else { return nil }
        return modelCalls
    }

    private static func requestCount(for usage: GrokParsedTokenUsage) -> Int {
        self.validatedModelCallCount(for: usage) ?? 1
    }

    private static func syntheticCallGroups(
        usage: GrokParsedTokenUsage,
        callCount: Int,
        pricing: CostUsagePricing.CodexPricing) -> [SyntheticCallGroup]
    {
        let largerInputCallCount = usage.inputTokens % callCount
        let baseInput = usage.inputTokens / callCount
        let threshold = pricing.thresholdTokens
        var ranges: [(range: Range<Int>, isLongContext: Bool)] = []
        if largerInputCallCount > 0 {
            ranges.append((
                0..<largerInputCallCount,
                threshold.map { baseInput + 1 > $0 } ?? false))
        }
        if largerInputCallCount < callCount {
            ranges.append((
                largerInputCallCount..<callCount,
                threshold.map { baseInput > $0 } ?? false))
        }
        return ranges.map { group in
            let effectiveInput = self.effectiveInputTotals(
                inputTokens: usage.inputTokens,
                cachedReadTokens: usage.cachedReadTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                callCount: callCount,
                range: group.range)
            return SyntheticCallGroup(
                inputTokens: effectiveInput.input,
                cachedReadTokens: effectiveInput.cachedRead,
                cacheCreationTokens: effectiveInput.cacheCreation,
                outputTokens: self.distributedTotal(
                    usage.outputTokens,
                    count: callCount,
                    range: group.range),
                isLongContext: group.isLongContext)
        }
    }

    private static func effectiveInputTotals(
        inputTokens: Int,
        cachedReadTokens: Int,
        cacheCreationTokens: Int,
        callCount: Int,
        range: Range<Int>) -> (input: Int, cachedRead: Int, cacheCreation: Int)
    {
        let boundaries = Set([
            range.lowerBound,
            range.upperBound,
            min(max(inputTokens % callCount, range.lowerBound), range.upperBound),
            min(max(cachedReadTokens % callCount, range.lowerBound), range.upperBound),
            min(max(cacheCreationTokens % callCount, range.lowerBound), range.upperBound),
        ]).sorted()
        var input = 0
        var cachedRead = 0
        var cacheCreation = 0
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where lower < upper {
            let count = upper - lower
            let perCallInput = self.distributed(inputTokens, index: lower, count: callCount)
            let perCallCachedRead = min(
                self.distributed(cachedReadTokens, index: lower, count: callCount),
                perCallInput)
            let remainingInput = perCallInput - perCallCachedRead
            let perCallCacheCreation = min(
                self.distributed(cacheCreationTokens, index: lower, count: callCount),
                remainingInput)
            input += perCallInput * count
            cachedRead += perCallCachedRead * count
            cacheCreation += perCallCacheCreation * count
        }
        return (input, cachedRead, cacheCreation)
    }

    private static func distributedTotal(_ total: Int, count: Int, range: Range<Int>) -> Int {
        let quotient = total / count
        let remainder = total % count
        let extra = max(0, min(range.upperBound, remainder) - range.lowerBound)
        return quotient * range.count + extra
    }

    private static func fixedTierPricing(
        _ pricing: CostUsagePricing.CodexPricing,
        usesLongContextRates: Bool) -> CostUsagePricing.CodexPricing
    {
        guard usesLongContextRates else {
            return CostUsagePricing.CodexPricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken,
                displayLabel: pricing.displayLabel,
                cacheWriteInputCostPerToken: pricing.cacheWriteInputCostPerToken)
        }
        let inputRate = pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
        return CostUsagePricing.CodexPricing(
            inputCostPerToken: inputRate,
            outputCostPerToken: pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken,
            cacheReadInputCostPerToken: pricing.cacheReadInputCostPerTokenAboveThreshold
                ?? pricing.cacheReadInputCostPerToken
                ?? inputRate,
            displayLabel: pricing.displayLabel,
            cacheWriteInputCostPerToken: pricing.cacheWriteInputCostPerTokenAboveThreshold
                ?? pricing.cacheWriteInputCostPerToken
                ?? inputRate)
    }

    private static func finalize(day: String, bucket: MutableDailyBucket) -> GrokLocalDailyBucket {
        let models = self.sortedModels(bucket.modelCounts)
        let breakdowns = models.compactMap { model -> CostUsageDailyReport.ModelBreakdown? in
            guard let value = bucket.modelBreakdowns[model] else { return nil }
            return CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: value.hasPricedCost ? value.costUSD : nil,
                totalTokens: value.totalTokens,
                requestCount: value.requestCount,
                inputTokens: value.inputTokens,
                outputTokens: value.outputTokens,
                cacheReadTokens: value.cacheReadTokens,
                cacheCreationTokens: value.cacheCreationTokens,
                reasoningTokens: value.reasoningTokens)
        }
        return GrokLocalDailyBucket(
            date: day,
            inputTokens: bucket.inputTokens,
            cacheReadTokens: bucket.cacheReadTokens,
            cacheCreationTokens: bucket.cacheCreationTokens,
            outputTokens: bucket.outputTokens,
            reasoningTokens: bucket.reasoningTokens,
            totalTokens: bucket.totalTokens,
            sessionCount: bucket.sessionIDs.count,
            requestCount: bucket.requestCount,
            costUSD: bucket.hasPricedCost ? bucket.costUSD : nil,
            models: models,
            modelBreakdowns: breakdowns,
            unpricedRequestCount: bucket.unpricedRequestCount,
            estimatedRequestCount: bucket.estimatedRequestCount)
    }

    private static func sortedModels(_ counts: [String: Int]) -> [String] {
        counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
