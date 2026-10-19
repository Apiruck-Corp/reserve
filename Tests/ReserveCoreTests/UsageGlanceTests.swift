import Foundation
import Testing
@testable import ReserveCore

@Suite("Usage glance trust rules")
struct UsageGlanceTests {
  private func entry(
    _ provider: ProviderID, _ day: String, tokens: Int64?, cost: Double?, detail: UsageDayDetail? = nil
  ) -> InsightReport.Entry {
    InsightReport.Entry(provider: provider, day: CachedUsageDay(day: day, tokens: tokens,
      costUSD: cost, fetchedAt: .distantPast, detail: detail))
  }

  private func detail(_ models: [String: InsightModelUsage] = [:], savings: Double? = 1,
                      unpriced: Int64 = 0) -> UsageDayDetail {
    UsageDayDetail(input: 100, cached: 80, cacheWrite: 0, output: 10,
      cacheSavingsUSD: savings, unpricedCacheReads: unpriced, models: models)
  }

  @Test func fullyPricedPeriodLeadsWithCost() {
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.openAI, "2026-10-01", tokens: 110, cost: 3, detail: detail()),
      entry(.anthropic, "2026-10-01", tokens: 190, cost: 9, detail: detail()),
    ]))
    #expect(glance.lead == .cost)
    #expect(glance.costUSD == 12)
    #expect(glance.unpricedProviders.isEmpty)
    #expect(glance.providers.map(\.provider) == [.anthropic, .openAI])
    #expect(glance.providers.first?.share == 0.75)
    #expect(glance.tokenMix != nil)
    #expect(!glance.tokenMixIsPartial)
    #expect(glance.cacheSavingsUSD == 2)
    #expect(!glance.cacheSavingsIsPartial)
  }

  @Test func anUnpricedProviderIsNamedAndLeftOutOfCost() {
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.anthropic, "2026-10-01", tokens: 100, cost: 4),
      entry(.cursor, "2026-10-01", tokens: 900, cost: nil),
    ]))
    #expect(glance.lead == .cost)
    #expect(glance.costUSD == 4)
    #expect(glance.unpricedProviders == [.cursor])
    #expect(glance.tokens == 1_000)
    let cursor = glance.providers.first { $0.provider == .cursor }
    #expect(cursor?.costUSD == nil)
    #expect(cursor?.share == nil)
    #expect(glance.providers.first?.provider == .anthropic)
    #expect(glance.providers.first?.share == 1)
  }

  @Test func aPartlyPricedProviderShowsNoCost() {
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.openAI, "2026-10-01", tokens: 100, cost: 2),
      entry(.openAI, "2026-10-02", tokens: 300, cost: nil),
    ]))
    #expect(glance.lead == .tokens)
    #expect(glance.costUSD == nil)
    #expect(glance.unpricedProviders == [.openAI])
    #expect(glance.providers.first?.costUSD == nil)
    #expect(glance.providers.first?.share == 1)
  }

  @Test func idleUnpricedDaysDoNotRemoveAPrice() {
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.openAI, "2026-10-01", tokens: 100, cost: 2),
      entry(.openAI, "2026-10-02", tokens: 0, cost: nil),
    ]))
    #expect(glance.lead == .cost)
    #expect(glance.unpricedProviders.isEmpty)
  }

  @Test func noPriceAtAllHidesCostInsteadOfShowingZero() {
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.cursor, "2026-10-01", tokens: 500, cost: nil),
    ]))
    #expect(glance.costUSD == nil)
    #expect(glance.lead == .tokens)
  }

  @Test func missingTokenTypesAreAbsentOrPartialNeverZero() {
    let none = UsageGlance(report: InsightReport(entries: [
      entry(.openAI, "2026-10-01", tokens: 100, cost: 1),
    ]))
    #expect(none.tokenMix == nil)
    #expect(none.cacheSavingsUSD == nil)
    let some = UsageGlance(report: InsightReport(entries: [
      entry(.openAI, "2026-10-01", tokens: 110, cost: 1, detail: detail()),
      entry(.openAI, "2026-10-02", tokens: 100, cost: 1),
    ]))
    #expect(some.tokenMix != nil)
    #expect(some.tokenMixDays.detailed == 1 && some.tokenMixDays.active == 2)
    #expect(some.tokenMixIsPartial)
    #expect(some.cacheSavingsIsPartial)
  }

  @Test func unpricedCacheReadsMarkSavingsPartial() {
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.anthropic, "2026-10-01", tokens: 190, cost: 2, detail: detail(unpriced: 40)),
    ]))
    #expect(glance.cacheSavingsUSD == 1)
    #expect(glance.cacheSavingsIsPartial)
  }

  @Test func modelsAreRankedAndLimitedWithUnnamedUsageApart() {
    let models = [
      "big": InsightModelUsage(tokens: 100, costUSD: 6),
      "mid": InsightModelUsage(tokens: 50, costUSD: 3),
      "small": InsightModelUsage(tokens: 20, costUSD: 1),
    ]
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.anthropic, "2026-10-01", tokens: 190, cost: 10, detail: detail(models)),
    ]), modelLimit: 2)
    #expect(glance.models.map(\.label) == ["big", "mid"])
    #expect(glance.models.first?.share == 0.6)
    #expect(glance.unattributed.map(\.tokens) == [20])
    #expect(glance.unattributed.first?.provider == .anthropic)
  }

  @Test func emptyPeriodHasNoUsage() {
    let glance = UsageGlance(report: InsightReport(entries: [
      entry(.openAI, "2026-10-01", tokens: 0, cost: 0),
    ]))
    #expect(!glance.hasUsage)
    #expect(glance.providers.isEmpty)
    #expect(glance.models.isEmpty)
    #expect(glance.coveredDays == 1)
  }
}
