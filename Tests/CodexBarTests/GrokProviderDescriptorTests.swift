import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct GrokProviderDescriptorTests {
    @Test
    func `descriptor enables inline cost dashboard with local logs disclaimers`() {
        let descriptor = GrokProviderDescriptor.descriptor

        #expect(descriptor.presentation.menuCard.supportsInlineTokenCostDashboard)
        #expect(descriptor.tokenCost.menuHintLines.contains(.localized("grok_local_logs_hint")))
        #expect(descriptor.tokenCost.showsHintInProviderDetails)
        #expect(descriptor.tokenCost.chartEstimateDisclaimer == .localized("grok_local_logs_hint"))
        #expect(CostHistoryChartMenuView.estimateDisclaimer(provider: .grok)
            == "Estimated from local Grok CLI logs · not a subscription bill")
    }
}
