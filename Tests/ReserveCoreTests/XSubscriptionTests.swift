import Foundation
import Testing

@testable import ReserveCore

/// The X Subscription (2026-10-12) moves Grok and Cursor onto one weekly pool
/// with new tier names. No real account, CLI or network is used: the billing
/// and settings responses are fixtures.
struct XSubscriptionTests {
  @Test
  func tierNamesAreRecognisedInEveryReportedShape() {
    for value in [
      "Premium", "premium", "PREMIUM", "x_subscription_premium", "The X Subscription Premium",
      "SUBSCRIPTION_TIER_PREMIUM", "premium_team", "Premium Team",
    ] {
      #expect(XSubscriptionPlan.tier(from: value) == "Premium", "\(value)")
    }
    #expect(XSubscriptionPlan.tier(from: "plus") == "Plus")
    #expect(XSubscriptionPlan.tier(from: "SUPER") == "Super")
    #expect(XSubscriptionPlan.tier(from: "x-subscription-ultra") == "Ultra")
    #expect(XSubscriptionPlan.tier(from: "free") == "Free")
  }

  @Test
  func olderStandalonePlansAreNotMistakenForTiers() {
    for value in [
      "x_premium", "X Premium", "x_premium_plus", "X Premium+", "supergrok", "SuperGrok",
      "supergrok_heavy", "supergrok_plus", "x_basic", "The X Subscription", "pro", "pro_plus",
      "", "premiums", "superpremium",
    ] {
      #expect(XSubscriptionPlan.tier(from: value) == nil, "\(value)")
    }
  }

  @Test
  func grokPlanNamesKeepOldPlansAndNameNewTiers() {
    #expect(GrokPlanFormatter.plan(from: "Premium") == "Premium")
    #expect(GrokPlanFormatter.plan(from: "x_subscription_super") == "Super")
    #expect(GrokPlanFormatter.plan(from: "ultra") == "Ultra")
    #expect(GrokPlanFormatter.plan(from: "x_premium") == "X Premium")
    #expect(GrokPlanFormatter.plan(from: "X Premium") == "X Premium")
    #expect(GrokPlanFormatter.plan(from: "x_premium_plus") == "X Premium+")
    #expect(GrokPlanFormatter.plan(from: "X Premium+") == "X Premium+")
    #expect(GrokPlanFormatter.plan(from: "supergrok") == "SuperGrok")
    #expect(GrokPlanFormatter.plan(from: "SuperGrok Heavy") == "SuperGrok Heavy")
  }

  @Test
  func cursorPlanNamesKeepCursorPlansAndNameNewTiers() {
    #expect(CursorPlanFormatter.plan(from: "Premium") == "Premium")
    #expect(CursorPlanFormatter.plan(from: "super") == "Super")
    #expect(CursorPlanFormatter.plan(from: "x_subscription_plus") == "Plus")
    #expect(CursorPlanFormatter.plan(from: "x_subscription_free") == "Free")
    // Standalone Cursor plans are unchanged.
    #expect(CursorPlanFormatter.plan(from: "free") == "Hobby")
    #expect(CursorPlanFormatter.plan(from: "pro") == "Pro")
    #expect(CursorPlanFormatter.plan(from: "pro_plus") == "Pro+")
    #expect(CursorPlanFormatter.plan(from: "ultra") == "Ultra")
  }

  @Test
  func pooledProductsGetReadableLabels() {
    #expect(GrokProvider.productLabel("GrokBuild") == "Grok Build share")
    #expect(GrokProvider.productLabel("GrokChat") == "Grok Chat share")
    #expect(GrokProvider.productLabel("Cursor") == "Cursor share")
    #expect(GrokProvider.productLabel("PRODUCT_CURSOR") == "Cursor share")
    #expect(GrokProvider.productLabel("GrokBot") == "Grok Bot share")
    #expect(GrokProvider.productLabel("PRODUCT_GROK_BOT") == "Grok Bot share")
    #expect(GrokProvider.productLabel("GrokImagine") == "Grok Imagine share")
    #expect(GrokProvider.productLabel("Something") == "Something share")
  }

  @Test
  func shareCardKeepsNewTiersAndCursorShare() {
    let model = UsageShareCardBuilder.model(
      provider: .grok, planName: "Premium",
      windows: [
        UsageWindow(id: "usage-pool", label: "Weekly", usedPercent: 40),
        UsageWindow(id: "product-cursor", label: "Cursor share", usedPercent: 25),
      ],
      tokensUsed: nil, tokenPeriodDays: nil, tokensCheckedAt: nil,
      estimatedAPIEquivalentUSD: nil, generatedAt: Date(), hidingPersonal: false)
    #expect(model.planName == "Premium")
    #expect(model.windows.map(\.label) == ["Weekly limit", "Cursor share"])
  }

  @Test
  func grokReadsTheSharedPoolOfAnXSubscriptionAccount() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-x-subscription-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let authFile = directory.appendingPathComponent("auth.json")
    let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 3_600))
    try JSONSerialization.data(withJSONObject: [
      "https://auth.x.ai::fixture": [
        "key": "fixture-key", "user_id": "fixture-user", "expires_at": future,
      ]
    ]).write(to: authFile)

    let billing = Data(
      #"""
      {"config":{"creditUsagePercent":46,"isUnifiedBillingUser":true,
        "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
          "start":"2026-10-12T00:00:00Z","end":"2026-10-19T00:00:00Z"},
        "productUsage":[{"product":"Cursor","usagePercent":30},
          {"product":"GrokBot","usagePercent":10},{"product":"GrokChat","usagePercent":6},
          {"product":"GrokImagine"}],
        "prepaidBalance":{"val":2500}},
       "onDemandEnabled":true}
      """#.utf8)
    let settings = Data(#"{"subscription_tier":"x_subscription_premium"}"#.utf8)
    let provider = GrokProvider(
      environment: ["GROK_AUTH_PATH": authFile.path],
      renewer: { _, _ in },
      executableLocator: { _ in "/usr/bin/true" },
      versionProbe: { _ in SemanticVersion(1, 0, 50) },
      requestHandler: { request in
        let body = request.url?.lastPathComponent == "settings" ? settings : billing
        return (
          body,
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        )
      })

    let snapshot = try await provider.fetch()
    #expect(snapshot.planName == "Premium")
    #expect(snapshot.windows.map(\.label) == [
      "Weekly", "Cursor share", "Grok Bot share", "Grok Chat share",
    ])
    #expect(snapshot.windows.map(\.usedPercent) == [46, 30, 10, 6])
    #expect(snapshot.windows.allSatisfy { $0.windowMinutes == 7 * 24 * 60 })
    #expect(snapshot.details.contains { $0.label == "Prepaid balance" && $0.value == "$25.00" })
  }
}
