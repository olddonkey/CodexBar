import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches credits from the Grok CLI's billing backend. The grok.com gRPC-web endpoint now requires
/// a browser-held WKE keypair (#2812), so the CLI proxy is the supported bearer-token path.
public enum GrokCreditsProxyFetcher {
    public static let defaultEndpoint = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetch(
        credentials: GrokCredentials,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> GrokWebBillingSnapshot
    {
        guard !credentials.isExpired else {
            throw GrokWebBillingError.missingCredentials
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw GrokWebBillingError.invalidResponse
        } catch {
            throw error
        }
        guard response.statusCode == 200 else {
            let body = String(data: response.data.prefix(400), encoding: .utf8) ?? ""
            throw GrokWebBillingError.requestFailed(response.statusCode, body)
        }
        return try Self.parseSnapshot(response.data)
    }

    static func parseSnapshot(_ data: Data) throws -> GrokWebBillingSnapshot {
        let response: CreditsResponse
        do {
            response = try JSONDecoder().decode(CreditsResponse.self, from: data)
        } catch {
            throw GrokWebBillingError.parseFailed
        }
        guard let config = response.config else {
            throw GrokWebBillingError.parseFailed
        }

        let subscriptionTier = GrokPlan.displayName(
            from: config.subscriptionTier ?? response.subscriptionTier)
        let resetsAt =
            config.currentPeriod?.end.flatMap(Self.parseISO8601)
            ?? config.billingPeriodEnd.flatMap(Self.parseISO8601)
        let windowMinutes =
            Self.windowMinutes(
                start: config.currentPeriod?.start,
                end: config.currentPeriod?.end)
            ?? Self.windowMinutes(
                start: config.billingPeriodStart,
                end: config.billingPeriodEnd)
        let productUsage = (config.productUsage ?? []).compactMap { entry -> GrokProductUsage? in
            guard let product = entry.product, !product.isEmpty else { return nil }
            return GrokProductUsage(product: product, usagePercent: entry.usagePercent)
        }
        let onDemandUsedPercent: Double? = if let cap = config.onDemandCap?.val,
                                              cap > 0,
                                              let used = config.onDemandUsed?.val
        {
            min(100, max(0, used / cap * 100))
        } else {
            nil
        }

        if let percent = config.creditUsagePercent, percent.isFinite {
            return GrokWebBillingSnapshot(
                usedPercent: min(100, max(0, percent)),
                resetsAt: resetsAt,
                subscriptionTier: subscriptionTier,
                windowMinutes: windowMinutes,
                productUsage: productUsage,
                onDemandUsedPercent: onDemandUsedPercent)
        }

        if let onDemandUsedPercent {
            return GrokWebBillingSnapshot(
                usedPercent: onDemandUsedPercent,
                resetsAt: resetsAt,
                subscriptionTier: subscriptionTier,
                windowMinutes: windowMinutes,
                productUsage: productUsage,
                onDemandUsedPercent: onDemandUsedPercent)
        }

        if resetsAt != nil {
            return GrokWebBillingSnapshot(
                usedPercent: 0,
                resetsAt: resetsAt,
                subscriptionTier: subscriptionTier,
                windowMinutes: windowMinutes,
                productUsage: productUsage,
                onDemandUsedPercent: onDemandUsedPercent)
        }

        throw GrokWebBillingError.parseFailed
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func windowMinutes(start rawStart: String?, end rawEnd: String?) -> Int? {
        guard let rawStart,
              let rawEnd,
              let start = parseISO8601(rawStart),
              let end = parseISO8601(rawEnd),
              end > start
        else {
            return nil
        }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes > 0 ? minutes : nil
    }

    private struct CreditsResponse: Decodable {
        let config: CreditsConfig?
        let subscriptionTier: String?
    }

    private struct CreditsConfig: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: CurrentPeriod?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
        let productUsage: [ProductUsageEntry]?
        // `val` has no declared unit, and the parallel CLI RPC models amounts as cents. Decode cap/used
        // only to derive a percentage; prepaid balance stays intentionally undecoded until a nonzero
        // payload can establish whether this proxy reports cents or dollars.
        let onDemandCap: CreditsAmount?
        let onDemandUsed: CreditsAmount?
        let subscriptionTier: String?
    }

    private struct CurrentPeriod: Decodable {
        let start: String?
        let end: String?
    }

    private struct ProductUsageEntry: Decodable {
        let product: String?
        let usagePercent: Double?
    }

    /// The proxy reports amounts as `{ "val": <number> }`; accept fractional values so an unusual
    /// cap/used shape cannot fail decoding of an otherwise valid response.
    private struct CreditsAmount: Decodable {
        let val: Double?
    }
}
