import Foundation
import Testing
@testable import ReserveCore

@Suite("Shareable usage card")
struct UsageShareCardTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private static func keys(_ count: Int) -> [String] {
    let formatter = DateFormatter()
    formatter.calendar = Self.calendar
    formatter.timeZone = Self.calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return (0..<count).reversed().map {
      formatter.string(from: Self.calendar.date(byAdding: .day, value: -$0, to: Self.now)!)
    }
  }

  private static func entry(
    _ provider: ProviderID, _ day: String, tokens: Int64?, cost: Double?,
    models: [String: InsightModelUsage] = [:], detailed: Bool = true
  ) -> InsightReport.Entry {
    let detail = detailed && (tokens ?? 0) > 0
      ? UsageDayDetail(
        input: (tokens ?? 0) / 4, cached: (tokens ?? 0) / 2, cacheWrite: 0, output: (tokens ?? 0) / 4,
        cacheSavingsUSD: cost.map { $0 / 2 }, unpricedCacheReads: 0, models: models)
      : nil
    return InsightReport.Entry(provider: provider, day: CachedUsageDay(
      day: day, tokens: tokens, costUSD: cost, fetchedAt: Self.now, detail: detail))
  }

  private static func build(
    accounts: [UsageShareAccount] = [], history: [InsightReport.Entry]?,
    options: UsageShareOptions = UsageShareOptions()
  ) -> UsageShareModel {
    UsageShareCardBuilder.model(
      accounts: accounts, history: history, usageCheckedAt: Self.now, options: options,
      now: Self.now, calendar: Self.calendar)
  }

  @Test func dynamicPersonalTextNeverReachesTheModelOrText() {
    let poison = "ada@example.com / Acme Org / /Users/ada/.codex/sessions/secret.jsonl"
    let window = UsageWindow(
      id: poison, label: poison, usedPercent: 25, windowMinutes: 10_080,
      resetsAt: Self.now.addingTimeInterval(86_400))
    let day = Self.keys(1)[0]
    let model = Self.build(
      accounts: [UsageShareAccount(provider: .anthropic, planName: poison, windows: [window], checkedAt: nil)],
      history: [Self.entry(.anthropic, day, tokens: 1_200, cost: 4.5,
        models: [poison: InsightModelUsage(tokens: 1_200, costUSD: 4.5)])],
      options: UsageShareOptions(periodDays: 1))
    let text = model.plainText()
    #expect(model.plans.isEmpty)
    #expect(model.usage?.models.isEmpty == true)
    #expect(model.usage?.otherModelTokens == 1_200)
    #expect(!text.contains("ada@"))
    #expect(!text.contains("Acme"))
    #expect(!text.contains("/Users"))
    #expect(!text.contains("secret"))
    #expect(text.contains("Estimated API equivalent: $4.50"))
    #expect(text.contains("Not an actual charge"))
  }

  @Test func knownPlanWindowAndPaceStay() {
    // Two days into a seven-day window with 10% used: under pace.
    let window = UsageWindow(
      id: "weekly", label: "Weekly", usedPercent: 10, windowMinutes: 10_080,
      resetsAt: Self.now.addingTimeInterval(5 * 86_400))
    let model = Self.build(
      accounts: [UsageShareAccount(provider: .openAI, planName: "Plus", windows: [window], checkedAt: Self.now)],
      history: nil)
    let plan = try! #require(model.plans.first)
    #expect(plan.name == "Codex" || plan.name == ProviderID.openAI.neutralDisplayName)
    #expect(plan.planName == "Plus")
    #expect(plan.limits.first?.label == "Weekly limit")
    #expect(plan.limits.first?.remainingPercent == 90)
    #expect(plan.limits.first?.pace == .underPace)
    #expect(model.usage == nil)
    let text = model.plainText()
    #expect(text.contains("Plus"))
    #expect(text.contains("Weekly limit: 90% left"))
    #expect(text.contains("under pace"))
  }

  @Test func staleLimitsHaveNoPace() {
    let window = UsageWindow(
      id: "weekly", label: "Weekly", usedPercent: 10, windowMinutes: 10_080,
      resetsAt: Self.now.addingTimeInterval(5 * 86_400))
    let model = Self.build(
      accounts: [UsageShareAccount(
        provider: .openAI, planName: "Plus", windows: [window], checkedAt: Self.now.addingTimeInterval(-7_200))],
      history: nil)
    #expect(model.plans.first?.limits.first?.pace == nil)
    #expect(model.limitsCheckedAt == Self.now.addingTimeInterval(-7_200))
  }

  @Test func modelScopedLimitsKeepOnlyPublicScopes() {
    #expect(UsageShareCardBuilder.normalizedWindowLabel("Fable weekly") == "Fable weekly")
    #expect(UsageShareCardBuilder.normalizedWindowLabel("GPT-5 · 5 hours") == "GPT-5 · 5-hour window")
    #expect(UsageShareCardBuilder.normalizedWindowLabel("Acme weekly") == nil)
    #expect(UsageShareCardBuilder.normalizedWindowLabel("ada@example.com · Weekly") == nil)
    #expect(UsageShareCardBuilder.normalizedWindowLabel("5 hours") == "5-hour window")
    #expect(UsageShareCardBuilder.normalizedWindowLabel("14 days") == "14 days")
  }

  @Test func modelNamesMustBePublicProductNames() {
    #expect(UsageShareCardBuilder.safeModelName("claude-opus-5") == "claude-opus-5")
    #expect(UsageShareCardBuilder.safeModelName("claude-sonnet-4-5-20250929") != nil)
    #expect(UsageShareCardBuilder.safeModelName("gpt-5.6-sol") != nil)
    #expect(UsageShareCardBuilder.safeModelName("gpt-4o-mini") != nil)
    #expect(UsageShareCardBuilder.safeModelName("o3") != nil)
    #expect(UsageShareCardBuilder.safeModelName("o4-mini") != nil)
    #expect(UsageShareCardBuilder.safeModelName("gemini-2.5-pro") != nil)
    #expect(UsageShareCardBuilder.safeModelName("grok-code-fast-1") != nil)
    #expect(UsageShareCardBuilder.safeModelName("kimi-k2-0905-preview") != nil)
    #expect(UsageShareCardBuilder.safeModelName("glm-4.6") != nil)
    // Fine-tunes, deployments and proxies can carry an organization.
    #expect(UsageShareCardBuilder.safeModelName("ft:gpt-4o:acme-corp:custom:abc123") == nil)
    #expect(UsageShareCardBuilder.safeModelName("claude-acme-internal") == nil)
    #expect(UsageShareCardBuilder.safeModelName("arn:aws:bedrock:us-east-1:123456789012:x") == nil)
    #expect(UsageShareCardBuilder.safeModelName("openrouter/anthropic/claude-opus-5") == nil)
    #expect(UsageShareCardBuilder.safeModelName("ada-model") == nil)
    #expect(UsageShareCardBuilder.safeModelName("") == nil)
  }

  @Test func usageCarriesTotalsChartProvidersMixAndModels() {
    let keys = Self.keys(7)
    var history: [InsightReport.Entry] = []
    for (index, day) in keys.enumerated() {
      let tokens: Int64? = index == 2 ? 0 : Int64(index + 1) * 1_000
      history.append(Self.entry(.anthropic, day, tokens: tokens, cost: tokens.map { Double($0) / 100 },
        models: ["claude-opus-5": InsightModelUsage(tokens: tokens ?? 0, costUSD: tokens.map { Double($0) / 100 })]))
      history.append(Self.entry(.openAI, day, tokens: 500, cost: 1,
        models: ["gpt-5.6-sol": InsightModelUsage(tokens: 500, costUSD: 1)]))
    }
    let model = Self.build(history: history, options: UsageShareOptions(periodDays: 7))
    let usage = try! #require(model.usage)
    #expect(usage.metric == .cost)
    #expect(usage.periodLabel == "Last 7 days")
    #expect(usage.bars.count == 7)
    #expect(usage.bars[2].segments.map(\.kind) == [.openAI])
    #expect(usage.providers.count == 2)
    #expect(usage.models.map(\.name).contains("claude-opus-5"))
    #expect(usage.models.map(\.name).contains("gpt-5.6-sol"))
    #expect(usage.tokenMix != nil)
    #expect(usage.cacheSavingsUSD != nil)
    #expect(usage.activeDays == 7)
    #expect(usage.peakTitle == "Peak day")
    #expect(usage.peakLabel != nil)
    #expect(usage.averagePerActiveDay != nil)
    let text = model.plainText()
    #expect(text.contains("Usage · Last 7 days"))
    #expect(text.contains("By provider:"))
    #expect(text.contains("Top models:"))
    #expect(text.contains("Token mix:"))
  }

  @Test func turningCostOffRemovesEveryDollarFigure() {
    let keys = Self.keys(7)
    let history = keys.map { Self.entry(.anthropic, $0, tokens: 2_000, cost: 25,
      models: ["claude-opus-5": InsightModelUsage(tokens: 2_000, costUSD: 25)]) }
    let model = Self.build(history: history, options: UsageShareOptions(periodDays: 7, includesCost: false))
    let usage = try! #require(model.usage)
    #expect(usage.metric == .tokens)
    #expect(usage.costUSD == nil)
    #expect(usage.cacheSavingsUSD == nil)
    #expect(usage.providers.allSatisfy { $0.costUSD == nil })
    #expect(usage.models.allSatisfy { $0.costUSD == nil })
    #expect(!model.plainText().contains("$"))
  }

  @Test func unpricedProvidersAreNamedNotPricedAtZero() {
    let keys = Self.keys(7)
    let history = keys.flatMap { [
      Self.entry(.anthropic, $0, tokens: 1_000, cost: 10),
      Self.entry(.cursor, $0, tokens: 5_000, cost: nil),
    ] }
    let usage = try! #require(Self.build(history: history, options: UsageShareOptions(periodDays: 7)).usage)
    #expect(usage.metric == .cost)
    #expect(usage.costUSD == 70)
    #expect(usage.unpricedNames == [ProviderID.cursor.neutralDisplayName])
    // Cost bars only draw fully priced providers.
    #expect(usage.bars.allSatisfy { $0.segments.allSatisfy { $0.kind == .anthropic } })
  }

  @Test func narrowingToOneProviderDropsTheOthers() {
    let keys = Self.keys(7)
    let history = keys.flatMap { [
      Self.entry(.anthropic, $0, tokens: 1_000, cost: 10),
      Self.entry(.openAI, $0, tokens: 3_000, cost: 5),
    ] }
    let accounts = [
      UsageShareAccount(provider: .anthropic, planName: "Max", windows: [
        UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10)], checkedAt: Self.now),
      UsageShareAccount(provider: .openAI, planName: "Pro", windows: [
        UsageWindow(id: "weekly", label: "Weekly", usedPercent: 50)], checkedAt: Self.now),
    ]
    let model = Self.build(
      accounts: accounts, history: history,
      options: UsageShareOptions(periodDays: 7, provider: .openAI))
    #expect(model.plans.map(\.kind) == [.openAI])
    #expect(model.usage?.providers.map(\.kind) == [.openAI])
    #expect(model.usage?.costUSD == 35)
    let hidden = Self.build(
      accounts: accounts, history: history,
      options: UsageShareOptions(periodDays: 7, includesLimits: false, includesModels: false))
    #expect(hidden.plans.isEmpty)
    #expect(hidden.usage?.models.isEmpty == true)
  }

  @Test func sectionsWithoutDataAreLeftOff() {
    // A quiet week and an account with a plan name but no limit.
    let history = Self.keys(7).map { Self.entry(.anthropic, $0, tokens: 0, cost: 0) }
    let accounts = [
      UsageShareAccount(provider: .anthropic, planName: "Max", windows: [], checkedAt: Self.now),
      UsageShareAccount(provider: .openAI, planName: "Pro", windows: [
        UsageWindow(id: "weekly", label: "Weekly", usedPercent: 20)], checkedAt: nil),
    ]
    let model = Self.build(accounts: accounts, history: history, options: UsageShareOptions(periodDays: 7))
    #expect(model.usage == nil)
    #expect(model.plans.map(\.kind) == [.openAI])
    let text = model.plainText()
    #expect(!text.contains("unknown"))
    #expect(!text.contains("unavailable"))
    #expect(!text.contains("Usage ·"))
    #expect(!text.contains("$0"))
    #expect(text.contains("Weekly limit: 80% left"))
    // One provider: no zero rows for the providers that did nothing.
    let mixed = Self.keys(7).flatMap { [
      Self.entry(.anthropic, $0, tokens: 1_000, cost: 1),
      Self.entry(.openAI, $0, tokens: 0, cost: 0),
    ] }
    let usage = try! #require(Self.build(history: mixed, options: UsageShareOptions(periodDays: 7)).usage)
    #expect(usage.providers.map(\.kind) == [.anthropic])
    #expect(usage.bars.allSatisfy { $0.segments.allSatisfy { $0.value > 0 } })
    #expect(Self.build(history: nil).isEmpty)
  }

  @Test func nonfiniteAndHugeValuesStayFinite() {
    let keys = Self.keys(30)
    let history = keys.map { Self.entry(.anthropic, $0, tokens: .max, cost: .infinity) }
    let model = Self.build(history: history, options: UsageShareOptions(periodDays: 30))
    let usage = try! #require(model.usage)
    #expect(usage.tokens == .max)
    #expect(usage.costUSD == nil)
    #expect(!model.plainText().contains("inf"))
    #expect(!model.plainText().contains("nan"))
  }
}
