import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct GrokLocalSessionScannerTests: GrokLocalSessionScannerTestSupport {
    @Test
    func `line timestamps split one session across local midnight`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let beforeMidnight = try self.localDate(day: 20, hour: 23, minute: 59)
        let afterMidnight = try self.localDate(day: 21, hour: 0, minute: 1)
        let firstUsage = self.singleModelUsage(input: 100, output: 10)
        let secondUsage = self.singleModelUsage(input: 200, output: 20)
        try self.writeUpdates(
            [
                self.turn(timestamp: beforeMidnight, usage: firstUsage, method: "_x.ai/session/update"),
                self.turn(timestamp: afterMidnight, usage: secondUsage, method: "session/update"),
            ],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: afterMidnight.addingTimeInterval(60))

        let summary = try self.summarize(fixture: fixture, now: afterMidnight.addingTimeInterval(120))

        #expect(summary.sessionCount == 1)
        #expect(summary.daily.map(\.totalTokens) == [110, 220])
        #expect(summary.daily.map(\.sessionCount) == [1, 1])
        #expect(Set(summary.daily.map(\.date)).count == 2)
        #expect(summary.lastSessionAt == afterMidnight)
    }

    @Test
    func `malformed completed lines do not discard valid turns`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 15)
        let valid = self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 123, output: 7))
        try self.writeUpdates(
            [valid],
            rawLines: ["{\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\"}}"],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let summary = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))

        #expect(summary.sessionCount == 1)
        #expect(summary.totalTokens == 130)
        #expect(summary.daily.count == 1)
    }

    @Test
    func `signals fallback contributes metadata only and updates take precedence`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-signals-fallback-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo", isDirectory: true)
        let signalsOnly = sessions.appendingPathComponent("signals-only", isDirectory: true)
        let updatesPreferred = sessions.appendingPathComponent("updates-preferred", isDirectory: true)
        try FileManager.default.createDirectory(at: signalsOnly, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updatesPreferred, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let turnAt = try self.localDate(day: 20, hour: 16)
        let now = turnAt.addingTimeInterval(120)
        try self.writeSignals(
            model: "grok-signals-only",
            tokens: 999_999,
            to: signalsOnly.appendingPathComponent("signals.json"),
            modificationDate: now)
        try self.writeSignals(
            model: "grok-must-not-win",
            tokens: 888_888,
            to: updatesPreferred.appendingPathComponent("signals.json"),
            modificationDate: now)
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 90, output: 10))],
            to: updatesPreferred.appendingPathComponent("updates.jsonl"),
            modificationDate: now)

        let summary = try GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: now,
            modelsDevCatalog: Self.catalog())

        #expect(summary.sessionCount == 2)
        #expect(summary.totalTokens == 100)
        #expect(summary.models.contains("grok-signals-only"))
        #expect(summary.models.contains("grok-4.6-build"))
        #expect(!summary.models.contains("grok-must-not-win"))
    }

    @Test
    func `daily buckets stay local and never invent dollars`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = try self.localDate(day: 20, hour: 16, minute: 30)
        try self.writeSignals(
            model: "grok-signals-only",
            tokens: 999_999,
            to: fixture.session.appendingPathComponent("signals.json"),
            modificationDate: now)

        let summary = try self.summarize(fixture: fixture, now: now)

        #expect(summary.sessionCount == 1)
        #expect(summary.totalTokens == 0)
        #expect(summary.daily.isEmpty)
        #expect(summary.toCostUsageTokenSnapshot(historyDays: 7) == nil)
    }

    @Test
    func `empty and absent session trees preserve the empty summary`() throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-absent-\(UUID().uuidString)", isDirectory: true)
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        for root in [absent, empty] {
            let summary = GrokLocalSessionScanner.summarize(
                env: ["GROK_HOME": root.path],
                lookbackDays: 7,
                now: Date())
            #expect(summary.sessionCount == 0)
            #expect(summary.totalTokens == 0)
            #expect(summary.daily.isEmpty)
            #expect(summary.toCostUsageTokenSnapshot(historyDays: 7) == nil)
        }
    }

    @Test
    func `absent models dev cache requests an initial refresh`() async throws {
        let cacheRoot = try self.makeModelsDevCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        await self.expectPricingRefreshRequests(
            cacheRoot: cacheRoot,
            now: Date(timeIntervalSince1970: 100_000),
            expectedRequests: 1)
    }

    @Test
    func `successful initial catalog refresh prices the first summary`() async throws {
        let fixture = try self.makeFixture()
        let cacheRoot = try self.makeModelsDevCacheRoot()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let turnAt = try self.localDate(day: 20, hour: 16, minute: 45)
        let now = turnAt.addingTimeInterval(120)
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 100, output: 10))],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))
        let catalog = try Self.catalog()

        let summary = await GrokLocalSessionScanner.summarizeRequestingPricingRefresh(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 7,
            now: now,
            modelsDevCacheRoot: cacheRoot)
        {
            _ = ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: cacheRoot)
        }

        #expect(summary.totalTokens == 110)
        #expect(summary.daily.first?.costUSD != nil)
        #expect(summary.daily.first?.unpricedRequestCount == 0)
    }

    @Test
    func `stale models dev cache requests a background refresh`() async throws {
        let cacheRoot = try self.makeModelsDevCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let now = Date(timeIntervalSince1970: 100_000)
        try ModelsDevCache.save(
            catalog: Self.catalog(),
            fetchedAt: now.addingTimeInterval(-ModelsDevCache.ttlSeconds - 1),
            cacheRoot: cacheRoot)

        await self.expectPricingRefreshRequests(
            cacheRoot: cacheRoot,
            now: now,
            expectedRequests: 1)
    }

    @Test
    func `fresh models dev cache skips the background refresh`() async throws {
        let cacheRoot = try self.makeModelsDevCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let now = Date(timeIntervalSince1970: 100_000)
        try ModelsDevCache.save(catalog: Self.catalog(), fetchedAt: now, cacheRoot: cacheRoot)

        await self.expectPricingRefreshRequests(
            cacheRoot: cacheRoot,
            now: now,
            expectedRequests: 0)
    }

    @Test
    func `parse cache decodes unchanged files once and invalidates on file identity`() throws {
        GrokLocalSessionScanner.resetParseCacheForTesting()
        defer { GrokLocalSessionScanner.resetParseCacheForTesting() }
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 17)
        let updates = fixture.session.appendingPathComponent("updates.jsonl")
        let first = self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 10, output: 1))
        let nonTurn = "{\"params\":{\"update\":{\"sessionUpdate\":\"tool_call_update\"}}}"
        try self.writeUpdates(
            [first],
            rawLines: [nonTurn],
            to: updates,
            modificationDate: turnAt.addingTimeInterval(60))

        _ = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))
        let firstMetrics = GrokLocalSessionScanner.parseCacheMetricsForTesting()
        _ = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))
        let warmMetrics = GrokLocalSessionScanner.parseCacheMetricsForTesting()
        let second = self.turn(
            timestamp: turnAt.addingTimeInterval(1),
            usage: self.singleModelUsage(input: 20, output: 2))
        try self.writeUpdates(
            [first, second],
            rawLines: [nonTurn],
            to: updates,
            modificationDate: turnAt.addingTimeInterval(90))
        let changed = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))
        let changedMetrics = GrokLocalSessionScanner.parseCacheMetricsForTesting()

        #expect(firstMetrics == GrokLocalSessionParseCacheMetrics(fileDecodeCount: 1, jsonDecodeCount: 1))
        #expect(warmMetrics == firstMetrics)
        #expect(changedMetrics == GrokLocalSessionParseCacheMetrics(fileDecodeCount: 2, jsonDecodeCount: 3))
        #expect(changed.totalTokens == 33)
    }

    @Test
    func `parse cache evicts deleted session files after the next scan`() throws {
        GrokLocalSessionScanner.resetParseCacheForTesting()
        defer { GrokLocalSessionScanner.resetParseCacheForTesting() }
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 17, minute: 30)
        let updates = fixture.session.appendingPathComponent("updates.jsonl")
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 10, output: 1))],
            to: updates,
            modificationDate: turnAt.addingTimeInterval(60))

        _ = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))
        #expect(GrokLocalSessionScanner.parseCacheEntryCountForTesting() == 1)

        try FileManager.default.removeItem(at: updates)
        _ = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))

        #expect(GrokLocalSessionScanner.parseCacheEntryCountForTesting() == 0)
    }

    @Test
    func `bounded tail scan retains only recent turns and marks history incomplete`() throws {
        GrokLocalSessionScanner.resetParseCacheForTesting()
        defer { GrokLocalSessionScanner.resetParseCacheForTesting() }
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstAt = try self.localDate(day: 20, hour: 17, minute: 40)
        let secondAt = firstAt.addingTimeInterval(1)
        let recentObjects = [
            self.turn(timestamp: firstAt, usage: self.singleModelUsage(input: 10, output: 1)),
            self.turn(timestamp: secondAt, usage: self.singleModelUsage(input: 20, output: 2)),
        ]
        let recentLines = try recentObjects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        let recentContents = recentLines.joined(separator: "\n") + "\n"
        let contents = String(repeating: "x", count: 4096) + "\n" + recentContents
        let updates = fixture.session.appendingPathComponent("updates.jsonl")
        try Data(contents.utf8).write(to: updates)
        try FileManager.default.setAttributes(
            [.modificationDate: secondAt.addingTimeInterval(60)],
            ofItemAtPath: updates.path)
        let limits = GrokLocalSessionScanLimits(
            maximumFileBytes: Int64(recentContents.utf8.count),
            maximumLineBytes: 64 * 1024,
            maximumTurnsPerFile: 1)

        let summary = try GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 7,
            now: secondAt.addingTimeInterval(120),
            modelsDevCatalog: Self.catalog(),
            scanLimits: limits)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))

        #expect(summary.totalTokens == 22)
        #expect(summary.lastSessionAt == secondAt)
        #expect(!summary.historyCoverageIsEstablished)
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(GrokLocalSessionScanner.parseCacheTurnCountForTesting() == 1)
        #expect(GrokLocalSessionScanner.parseCacheMetricsForTesting().jsonDecodeCount == 2)
    }

    @Test
    func `parse cache caps retained session entries globally`() throws {
        GrokLocalSessionScanner.resetParseCacheForTesting()
        defer { GrokLocalSessionScanner.resetParseCacheForTesting() }
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionsRoot = fixture.session.deletingLastPathComponent()
        let turnAt = try self.localDate(day: 20, hour: 17, minute: 50)
        for index in 0..<80 {
            let session = sessionsRoot.appendingPathComponent("session-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try self.writeUpdates(
                [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 1, output: 1))],
                to: session.appendingPathComponent("updates.jsonl"),
                modificationDate: turnAt.addingTimeInterval(60))
        }

        let summary = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))

        #expect(summary.totalTokens == 160)
        #expect(summary.historyCoverageIsEstablished)
        #expect(GrokLocalSessionScanner.parseCacheEntryCountForTesting() <= 64)
        #expect(GrokLocalSessionScanner.parseCacheTurnCountForTesting() <= 64)
    }

    @Test
    func `global scan budgets retain newest sessions and mark history incomplete`() throws {
        GrokLocalSessionScanner.resetParseCacheForTesting()
        defer { GrokLocalSessionScanner.resetParseCacheForTesting() }
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionsRoot = fixture.session.deletingLastPathComponent()
        let firstAt = try self.localDate(day: 20, hour: 18)
        for index in 0..<5 {
            let session = sessionsRoot.appendingPathComponent("budget-session-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let turnAt = firstAt.addingTimeInterval(TimeInterval(index))
            try self.writeUpdates(
                [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: index + 1, output: 0))],
                to: session.appendingPathComponent("updates.jsonl"),
                modificationDate: turnAt)
        }
        let limits = GrokLocalSessionScanLimits(
            maximumFileBytes: 64 * 1024,
            maximumLineBytes: 64 * 1024,
            maximumTurnsPerFile: 10,
            maximumSessions: 3,
            maximumTotalBytes: 1024 * 1024,
            maximumTotalTurns: 2)

        let summary = try GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 7,
            now: firstAt.addingTimeInterval(60),
            modelsDevCatalog: Self.catalog(),
            scanLimits: limits)

        #expect(summary.totalTokens == 9)
        #expect(summary.sessionCount == 2)
        #expect(summary.lastSessionAt == firstAt.addingTimeInterval(4))
        #expect(!summary.historyCoverageIsEstablished)
        #expect(GrokLocalSessionScanner.parseCacheEntryCountForTesting() == 2)
        #expect(GrokLocalSessionScanner.parseCacheTurnCountForTesting() == 2)
    }

    @Test
    func `absurd model call count promptly falls back without iterating file content`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 18, minute: 15)
        let model = self.modelUsage(input: 300_000, output: 10, modelCalls: 900_000_000)
        let usage = self.usage(
            input: 300_000,
            output: 10,
            modelCalls: 900_000_000,
            modelUsage: ["grok-4.6-build": model])
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let clock = ContinuousClock()
        let startedAt = clock.now
        let day = try #require(self.summarize(
            fixture: fixture,
            now: turnAt.addingTimeInterval(120)).daily.first)
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .seconds(2))
        #expect(day.totalTokens == 300_010)
        #expect(day.requestCount == 1)
        #expect(day.costUSD == nil)
        #expect(day.unpricedRequestCount == 1)
    }

    @Test
    func `explicit zero total tokens falls back to nonzero input and output sum`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 18, minute: 30)
        var usage = self.singleModelUsage(input: 100, output: 10)
        usage["totalTokens"] = 0
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let day = try #require(self.summarize(
            fixture: fixture,
            now: turnAt.addingTimeInterval(120)).daily.first)

        #expect(day.totalTokens == 110)
        #expect(day.inputTokens == 100)
        #expect(day.outputTokens == 10)
    }

    @Test
    func `request coverage uses per SKU calls when model usage exists`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 18, minute: 45)
        let usage = self.usage(
            input: 100,
            output: 10,
            modelCalls: 5,
            modelUsage: ["grok-4.6-build": self.modelUsage(input: 100, output: 10, modelCalls: nil)])
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let summary = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))
        let day = try #require(summary.daily.first)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))

        #expect(day.requestCount == 1)
        #expect(day.unpricedRequestCount == 0)
        #expect(snapshot.daily.first?.coverageCounts.priced == 1)
    }

    @MainActor
    @Test
    func `supplied Grok provider snapshot performs zero additional JSON decodes`() throws {
        GrokLocalSessionScanner.resetParseCacheForTesting()
        defer { GrokLocalSessionScanner.resetParseCacheForTesting() }
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 19)
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 50, output: 5))],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))
        let summary = try self.summarize(fixture: fixture, now: turnAt.addingTimeInterval(120))
        let projected = try #require(summary.toCostUsageTokenSnapshot(
            historyDays: GrokLocalSessionScanner.maximumLookbackDays))
        let warmMetrics = GrokLocalSessionScanner.parseCacheMetricsForTesting()
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: projected,
            updatedAt: turnAt,
            identity: nil)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: testSettingsStore(suiteName: "GrokLocalSessionScannerTests-snapshot"),
            startupBehavior: .testing,
            environmentBase: ["GROK_HOME": fixture.root.path])

        #expect(warmMetrics == GrokLocalSessionParseCacheMetrics(fileDecodeCount: 1, jsonDecodeCount: 1))
        let result = store.tokenSnapshot(fromProviderSnapshot: usage, provider: .grok, historyDays: 7)

        #expect(result?.historyDays == 7)
        #expect(result?.daily == projected.daily)
        #expect(result?.last30DaysTokens == projected.last30DaysTokens)
        #expect(GrokLocalSessionScanner.parseCacheMetricsForTesting() == warmMetrics)
    }

    @MainActor
    @Test
    func `concurrent Grok fallback callers coalesce into one maximum window scan`() async throws {
        let settings = testSettingsStore(suiteName: "GrokLocalSessionScannerTests-coalesced")
        let metadata = ProviderDescriptorRegistry.descriptor(for: .grok).metadata
        settings.setProviderEnabled(provider: .grok, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["GROK_HOME": "/fixture/not-read"])
        let updatedAt = try self.localDate(day: 20, hour: 19, minute: 15)
        let day = try #require(GrokLocalSessionScanner.dayKey(for: updatedAt, calendar: .current))
        let source = try #require(GrokLocalSessionSummary(
            sessionCount: 1,
            totalTokens: 77,
            lastSessionAt: updatedAt,
            primaryModel: "grok-4.6-build",
            models: ["grok-4.6-build"],
            daily: [GrokLocalDailyBucket(
                date: day,
                totalTokens: 77,
                sessionCount: 1,
                requestCount: 1,
                costUSD: 0.1,
                models: ["grok-4.6-build"])],
            scannedAt: updatedAt)
            .toCostUsageTokenSnapshot(historyDays: GrokLocalSessionScanner.maximumLookbackDays))
        var scanCount = 0
        var receivedLookbackDays: [Int] = []
        store._test_grokLocalTokenScannerOverride = { historyDays in
            scanCount += 1
            receivedLookbackDays.append(historyDays)
            try? await Task.sleep(nanoseconds: 50_000_000)
            return source
        }

        let first = Task { @MainActor in
            await store.scanAndPublishGrokLocalTokenSnapshot(historyDays: 30)
        }
        let second = Task { @MainActor in
            await store.scanAndPublishGrokLocalTokenSnapshot(historyDays: 365)
        }
        let firstResult = await first.value
        let secondResult = await second.value

        #expect(scanCount == 1)
        #expect(receivedLookbackDays == [365])
        #expect(firstResult?.historyDays == 30)
        #expect(secondResult?.historyDays == 365)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .grok)?.snapshot?.historyDays == 365)
    }

    @MainActor
    @Test
    func `missing remote snapshot scans and publishes local tokens then clears empty data`() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 19, minute: 30)
        let updates = fixture.session.appendingPathComponent("updates.jsonl")
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 70, output: 7))],
            to: updates,
            modificationDate: turnAt.addingTimeInterval(60))
        let settings = testSettingsStore(suiteName: "GrokLocalSessionScannerTests-detached")
        let metadata = ProviderDescriptorRegistry.descriptor(for: .grok).metadata
        settings.setProviderEnabled(provider: .grok, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["GROK_HOME": fixture.root.path])

        let snapshot = await store.scanAndPublishGrokLocalTokenSnapshot(historyDays: 7)

        #expect(snapshot?.last30DaysTokens == 77)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .grok)?.snapshot?.last30DaysTokens == 77)

        var fallbackScanCount = 0
        store._test_grokLocalTokenScannerOverride = { _ in
            fallbackScanCount += 1
            return nil
        }
        store._test_providerFetchOutcomeOverride = { provider in
            #expect(provider == .grok)
            return ProviderFetchOutcome(result: .failure(URLError(.badServerResponse)), attempts: [])
        }
        await store.refreshProvider(.grok)

        #expect(fallbackScanCount == 0)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .grok)?.snapshot?.last30DaysTokens == 77)

        await store.refreshProvider(.grok)

        #expect(fallbackScanCount == 0)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .grok)?.snapshot?.last30DaysTokens == 77)

        store._test_grokLocalTokenScannerOverride = nil
        try FileManager.default.removeItem(at: updates)
        store.clearTokenSnapshot(for: .grok)
        let empty = await store.scanAndPublishGrokLocalTokenSnapshot(historyDays: 7)

        #expect(empty == nil)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .grok)?.snapshot == nil)
    }

    @Test
    func `local scan clock wins over a stale remote snapshot`() throws {
        let calendar = Calendar.current
        let staleRemoteTime = try self.localDate(day: 20, hour: 10)
        let localScanTime = try #require(calendar.date(byAdding: .day, value: 1, to: staleRemoteTime))
        let localDay = try #require(GrokLocalSessionScanner.dayKey(for: localScanTime, calendar: calendar))
        let summary = GrokLocalSessionSummary(
            sessionCount: 1,
            totalTokens: 250,
            lastSessionAt: localScanTime,
            primaryModel: "grok-4.6-build",
            models: ["grok-4.6-build"],
            daily: [GrokLocalDailyBucket(
                date: localDay,
                totalTokens: 250,
                sessionCount: 1,
                costUSD: 0.25,
                models: ["grok-4.6-build"])],
            scannedAt: localScanTime)
        let remote = GrokUsageSnapshot(
            billing: nil,
            credentials: nil,
            localSummary: summary,
            cliVersion: nil,
            updatedAt: staleRemoteTime)

        let snapshot = try #require(remote.toUsageSnapshot().costUsage)
        #expect(snapshot.sessionTokens == 250)
        #expect(snapshot.sessionCostUSD == 0.25)
        #expect(snapshot.updatedAt == localScanTime)
    }

    private func makeModelsDevCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-modelsdev-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func expectPricingRefreshRequests(
        cacheRoot: URL,
        now: Date,
        expectedRequests: Int) async
    {
        let transport = GrokModelsDevTrackingTransport()
        let completion = GrokPricingRefreshCompletion()
        let summary = await GrokLocalSessionScanner.summarizeRequestingPricingRefresh(
            env: ["GROK_HOME": cacheRoot.path],
            lookbackDays: 7,
            now: now,
            modelsDevCacheRoot: cacheRoot)
        {
            await ModelsDevPricingPipeline.refreshIfNeeded(
                now: now,
                cacheRoot: cacheRoot,
                client: ModelsDevClient(transport: transport))
            await completion.finish()
        }
        await completion.waitUntilFinished()

        #expect(summary.daily.isEmpty)
        #expect(transport.calls == expectedRequests)
    }
}

private actor GrokPricingRefreshCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        self.finished = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        if self.finished { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }
}

private final class GrokModelsDevTrackingTransport: ModelsDevHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var calls: Int {
        self.lock.withLock { self.callCount }
    }

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        self.lock.withLock { self.callCount += 1 }
        throw GrokModelsDevTrackingError.failed
    }
}

private enum GrokModelsDevTrackingError: Error {
    case failed
}
