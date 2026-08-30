import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Developer tool, skipped by default: renders the Grok card for a billing period that has not
/// recorded usage yet, before and after the resolver adopts the surface's no-usage-yet reading.
///
/// Both cards are rendered from the real fetch types. The "before" card is the proxy-only answer
/// the previous gate returned; the "after" card is whatever `resolvingUnknownUsage` produces for
/// the same two fixtures, so the screenshot cannot drift from the shipped behavior.
///
/// Run with:
///   CODEXBAR_GROK_ZERO_SCREENSHOT_DIR=~/Downloads swift test --filter GrokZeroUsageScreenshotRenderTests
@MainActor
final class GrokZeroUsageScreenshotRenderTests: XCTestCase {
    private static let width: CGFloat = 320
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)
    private static let resetsAt = Date(timeIntervalSince1970: 1_782_000_000 + 6 * 86400 + 3 * 3600)

    private static let credentials = GrokCredentials(
        accessToken: "token-123",
        refreshToken: "refresh-123",
        scope: "https://auth.x.ai::client",
        authMode: "oidc",
        userId: "user-123",
        email: "you@example.com",
        firstName: "G",
        lastName: "Rok",
        teamId: nil,
        oidcIssuer: "https://auth.x.ai",
        oidcClientId: "client",
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        createTime: Date(timeIntervalSince1970: 1_779_000_000))

    /// The credits proxy describes the period but publishes no percentage.
    private static let proxySnapshot = GrokWebBillingSnapshot(
        usedPercent: nil,
        resetsAt: Date(timeIntervalSince1970: 1_782_000_000 + 6 * 86400 + 3 * 3600),
        subscriptionTier: "SuperGrok Heavy")

    /// What grok.com returns while the period has no usage: a live period, and no percentage
    /// anywhere, because the percentage is a proto3 scalar and an exact zero is omitted.
    private static let noUsageYetSnapshot = GrokWebBillingSnapshot(
        usedPercent: 0,
        resetsAt: nil,
        usedPercentIsWirePublished: false)

    func test_renderGrokZeroUsageScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_GROK_ZERO_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_GROK_ZERO_SCREENSHOT_DIR to render Grok zero-usage screenshots.")
        }
        let directory = URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let noUsageYet = Self.noUsageYetSnapshot
        let resolved = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            Self.proxySnapshot,
            credentials: Self.credentials,
            grpcBilling: { _ in noUsageYet })
        XCTAssertEqual(resolved.snapshot.usedPercent, 0, "the resolver must adopt the no-usage-yet reading")
        XCTAssertFalse(resolved.snapshot.usedPercentIsWirePublished, "the zero stays marked as inferred")

        let cards: [(name: String, billing: GrokWebBillingSnapshot)] = [
            ("grok-zero-usage-before", Self.proxySnapshot),
            ("grok-zero-usage-after", resolved.snapshot),
        ]
        for card in cards {
            let data = try XCTUnwrap(Self.pngData(for: Self.view(billing: card.billing)), "render failed")
            let url = directory.appendingPathComponent("codexbar-\(card.name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    private static func view(billing: GrokWebBillingSnapshot) -> AnyView {
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: billing,
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Self.now,
            subscriptionTier: billing.subscriptionTier ?? "SuperGrok Heavy")
        let model = UsageMenuCardView.Model.make(.init(
            provider: .grok,
            metadata: ProviderDefaults.metadata[.grok]!,
            snapshot: snapshot.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "you@example.com", plan: "SuperGrok Heavy"),
            isRefreshing: false,
            lastError: billing.usedPercent == nil ? GrokStatusProbe.usageUnavailableMessage : nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Self.now))
        return AnyView(UsageMenuCardView(model: model, width: Self.width)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor)))
    }

    private static func pngData(for view: AnyView, appearance: NSAppearance.Name = .aqua) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        hosting.displayIgnoringOpacity(hosting.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }
}
