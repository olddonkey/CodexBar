import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in real-account proof, skipped by default: drives the shipped Grok billing path against the
/// live surfaces and prints a redacted transcript, then renders the resulting card.
///
/// It reads the bearer from `~/.grok/auth.json` — the same file the app reads — and touches neither
/// the Keychain nor browser cookies. Only aggregate fields are printed: no token, no account
/// identity, no session contents. The single network round trip per surface is the same request the
/// provider makes on a normal refresh.
///
/// Run with:
///   CODEXBAR_LIVE_GROK_ZERO_PROOF=1 \
///   CODEXBAR_LIVE_GROK_ZERO_PROOF_DIR=.github/pr-proof \
///   swift test --filter GrokZeroUsageLiveProofTests
@MainActor
final class GrokZeroUsageLiveProofTests: XCTestCase {
    private static let width: CGFloat = 320

    func test_liveGrokZeroUsageProof() async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_LIVE_GROK_ZERO_PROOF"] == "1" else {
            throw XCTSkip("Set CODEXBAR_LIVE_GROK_ZERO_PROOF=1 to probe the live Grok billing surfaces.")
        }
        let credentials = try GrokCredentialsStore.load()
        let proxy = try await GrokCreditsProxyFetcher.fetch(credentials: credentials)
        let web = try await GrokWebBillingFetcher.fetch(credentials: credentials)

        // The resolver runs on the two real snapshots; injecting the already-fetched grok.com answer
        // keeps this to one round trip per surface without changing the code under proof.
        let resolved = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            proxy,
            credentials: credentials,
            grpcBilling: { _ in web })

        let branch: String
        if proxy.usedPercent != nil {
            branch = "proxy_published_percent"
            XCTAssertEqual(resolved.snapshot.usedPercent, proxy.usedPercent)
            XCTAssertEqual(resolved.sourceLabel, "grok-cli-proxy")
        } else if web.usedPercent == 0, !web.usedPercentIsWirePublished {
            branch = "grok_web_no_usage_yet_zero"
            XCTAssertEqual(resolved.snapshot.usedPercent, 0, "the no-usage-yet reading must be adopted")
            XCTAssertFalse(resolved.snapshot.usedPercentIsWirePublished, "the adopted zero stays inferred")
            XCTAssertEqual(resolved.sourceLabel, "grok-web")
        } else if web.usedPercent != nil, web.usedPercentIsWirePublished {
            branch = "grok_web_published_percent"
            XCTAssertEqual(resolved.snapshot.usedPercent, web.usedPercent)
            XCTAssertEqual(resolved.sourceLabel, "grok-web")
        } else {
            branch = "usage_unknown_on_both_surfaces"
            XCTAssertNil(resolved.snapshot.usedPercent)
            XCTAssertEqual(resolved.sourceLabel, "grok-cli-proxy")
        }

        print("branch=\(branch)")
        print("proxy_used_percent=\(Self.describe(proxy.usedPercent))")
        print("proxy_has_period=\(proxy.resetsAt != nil)")
        print("grok_web_used_percent=\(Self.describe(web.usedPercent))")
        print("grok_web_percent_is_wire_published=\(web.usedPercentIsWirePublished)")
        print("resolved_used_percent=\(Self.describe(resolved.snapshot.usedPercent))")
        print("resolved_percent_is_wire_published=\(resolved.snapshot.usedPercentIsWirePublished)")
        print("resolved_source=\(resolved.sourceLabel)")
        print("resolved_resets_at=\(Self.describeDay(resolved.snapshot.resetsAt))")
        print("renders_usage_bar=\(resolved.snapshot.usedPercent != nil)")

        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_LIVE_GROK_ZERO_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(Self.pngData(for: Self.view(billing: resolved.snapshot)), "render failed")
        let url = directory.appendingPathComponent("codexbar-grok-zero-usage-live.png")
        try data.write(to: url, options: .atomic)
        print("Wrote \(url.path)")
    }

    private static func describe(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "nil"
    }

    private static func describeDay(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) + "Z"
    }

    /// Rendered with personal information hidden, so the card can be published as proof.
    private static func view(billing: GrokWebBillingSnapshot) -> AnyView {
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: billing,
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Date(),
            subscriptionTier: billing.subscriptionTier)
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
            account: AccountInfo(email: nil, plan: billing.subscriptionTier),
            isRefreshing: false,
            lastError: billing.usedPercent == nil ? GrokStatusProbe.usageUnavailableMessage : nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: Date()))
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
