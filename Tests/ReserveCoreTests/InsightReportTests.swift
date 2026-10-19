import Foundation
import Testing
@testable import ReserveCore

@Suite("Insight range reporting")
struct InsightReportTests {
  private func entry(_ provider: ProviderID, _ day: String, tokens: Int64?, cost: Double?, detail: UsageDayDetail? = nil) -> InsightReport.Entry {
    InsightReport.Entry(provider: provider, day: CachedUsageDay(day: day, tokens: tokens,
      costUSD: cost, fetchedAt: .distantPast, detail: detail))
  }
  @Test func unknownDaysAndPricesAreNotZero() {
    let report = InsightReport(entries: [entry(.openAI, "2026-10-01", tokens: 100, cost: nil),
      entry(.openAI, "2026-10-02", tokens: nil, cost: nil),
      entry(.cursor, "2026-10-01", tokens: 0, cost: 0)])
    #expect(report.tokens == 100)
    #expect(report.coveredDays == 2)
    #expect(report.activeDays == 1)
    #expect(report.pricedDays == 1)
    #expect(report.costUSD == 0)
    #expect(report.providerRows.first { $0.provider == .openAI }?.costUSD == nil)
    #expect(report.detailDays == 0)
    #expect(report.modelRows.first { $0.provider == .openAI }?.label == "Model unavailable")
  }
  @Test func tokenTypesUseEachProvidersCacheAccounting() {
    let detail = UsageDayDetail(input: 100, cached: 80, cacheWrite: 5, output: 10,
      cacheSavingsUSD: 2, unpricedCacheReads: 20)
    let report = InsightReport(entries: [entry(.openAI, "2026-10-01", tokens: 110, cost: 3, detail: detail),
      entry(.anthropic, "2026-10-01", tokens: 195, cost: 4, detail: detail)])
    #expect(report.tokenMix.uncachedInput == 115)
    #expect(report.tokenMix.cachedInput == 160)
    #expect(report.tokenMix.cacheWrite == 10)
    #expect(report.tokenMix.output == 20)
    #expect(report.tokens == 305)
    #expect(report.cacheSavingsUSD == 4)
    #expect(report.unpricedCacheReads == 40)
  }
  @Test func modelsKeepProviderIdentityAndUnknownRemainders() {
    let detail = UsageDayDetail(input: 100, cached: 0, cacheWrite: 0, output: 0,
      cacheSavingsUSD: nil, unpricedCacheReads: 0,
      models: ["shared-model": InsightModelUsage(tokens: 60, costUSD: 2)])
    let report = InsightReport(entries: [entry(.openAI, "2026-10-01", tokens: 100, cost: 4, detail: detail),
      entry(.cursor, "2026-10-01", tokens: 100, cost: 4, detail: detail)])
    #expect(report.modelRows.count == 4)
    #expect(report.modelRows.filter { $0.label == "shared-model" }.count == 2)
    #expect(report.modelRows.filter { $0.label == "Model unavailable" }.allSatisfy { $0.tokens == 40 && $0.costUSD == nil })
    #expect(InsightReport.sum([.max, 1]) == .max)
  }
  @Test func newDetailRoundTripsAndOldDaysDecode() throws {
    let detail = UsageDayDetail(input: 10, cached: 2, cacheWrite: 0, output: 1,
      cacheSavingsUSD: 0.1, unpricedCacheReads: 0,
      models: ["model": InsightModelUsage(tokens: 11, costUSD: nil)])
    let value = entry(.openAI, "2026-10-01", tokens: 11, cost: nil, detail: detail).day
    #expect(try JSONDecoder().decode(CachedUsageDay.self, from: JSONEncoder().encode(value)) == value)
    let old = Data(#"{"day":"2026-10-01","tokens":11,"fetchedAt":0}"#.utf8)
    #expect(try JSONDecoder().decode(CachedUsageDay.self, from: old).detail == nil)
  }
  @Test func modelPricesUseTheSameCoveredDaysAsTheHeadline() {
    let detail = UsageDayDetail(input: 100, cached: 0, cacheWrite: 0, output: 0,
      cacheSavingsUSD: nil, unpricedCacheReads: 0,
      models: ["model": InsightModelUsage(tokens: 100, costUSD: 7)])
    let report = InsightReport(entries: [entry(.openAI, "2026-10-01", tokens: 100, cost: nil, detail: detail)])
    #expect(report.modelRows.first?.costUSD == nil)
    #expect(report.costUSD == nil)
    #expect(report.modelRows.first?.tokens == 100)
  }
  @Test func cumulativeCodexUsageDoesNotAssignEveryTokenToTheLastModel() throws {
    let context1 = #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"#
    let usage1 = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#
    let context2 = #"{"type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#
    let usage2 = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"output_tokens":20}}}}"#
    let parsed = try #require(LocalUsageScanner.parseCodexTailData(Data([context1, usage1, context2, usage2].joined(separator: "\n").utf8)))
    #expect(parsed.totals.totalTokens(provider: .openAI) == 320)
    #expect(parsed.totals.models == nil)
  }
  @Test func replacingAParsedRowReplacesItsModelTotals() throws {
    let a = UsageTotals(input: 100, models: ["first": InsightModelUsage(tokens: 100, costUSD: 1)])
    let b = UsageTotals(input: 200, models: ["second": InsightModelUsage(tokens: 200, costUSD: nil)])
    var day = UsageTotals(); day.add(a); day.subtract(a); day.add(b)
    #expect(day.models?["first"] == nil)
    #expect(day.models?["second"]?.tokens == 200)
    #expect(day.models?["second"]?.costUSD == nil)
    #expect(try JSONDecoder().decode(UsageTotals.self, from: JSONEncoder().encode(day)) == day)
  }
}
