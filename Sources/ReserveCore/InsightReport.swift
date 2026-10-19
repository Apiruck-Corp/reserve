import Foundation

/// Range-scoped report built from already published days. It never reads logs.
public struct InsightReport: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public var provider: ProviderID
    public var day: CachedUsageDay
    public init(provider: ProviderID, day: CachedUsageDay) { self.provider = provider; self.day = day }
  }
  public struct Row: Equatable, Sendable {
    public var label: String
    public var provider: ProviderID?
    public var tokens: Int64 = 0
    public var costUSD: Double?
    public var pricedSamples = 0
    public var samples = 0
  }
  public let entries: [Entry]
  public init(entries: [Entry]) { self.entries = entries }

  /// The model row for tokens no source record names a model for.
  public static let unknownModelLabel = "Model unavailable"

  public var tokens: Int64 { Self.sum(self.entries.compactMap { $0.day.tokens }) }
  public var coveredDays: Int { self.entries.filter { $0.day.tokens != nil }.count }
  public var pricedDays: Int { self.entries.filter { Self.cost($0.day.costUSD) != nil }.count }
  public var costUSD: Double? { Self.costSum(self.entries.compactMap { Self.cost($0.day.costUSD) }) }
  public var activeDays: Int { Set(self.entries.filter { ($0.day.tokens ?? 0) > 0 }.map { $0.day.day }).count }
  public var detailDays: Int { self.entries.filter { $0.day.detail != nil }.count }
  public var tokenMix: TokenMix {
    let details = self.entries.compactMap { entry -> TokenMix? in
      guard let d = entry.day.detail else { return nil }
      // The summary owns provider-specific cache inclusion rules.
      return LocalUsageSummary(provider: entry.provider, periodDays: 1, inputTokens: d.input,
        cachedInputTokens: d.cached, cacheWriteInputTokens: d.cacheWrite,
        outputTokens: d.output, apiEquivalentCostUSD: 0).tokenMix
    }
    return TokenMix(uncachedInput: Self.sum(details.map(\.uncachedInput)),
      cachedInput: Self.sum(details.map(\.cachedInput)), cacheWrite: Self.sum(details.map(\.cacheWrite)),
      output: Self.sum(details.map(\.output)))
  }
  public var cacheSavingsUSD: Double? {
    Self.costSum(self.entries.compactMap { Self.cost($0.day.detail?.cacheSavingsUSD) })
  }
  public var unpricedCacheReads: Int64 { Self.sum(self.entries.compactMap { $0.day.detail?.unpricedCacheReads }) }

  public var providerRows: [Row] { self.group { ($0.provider.rawValue, $0.provider) } }
  public var dailyRows: [Row] { self.group { ($0.day.day, nil) }.sorted { $0.label > $1.label } }
  public var modelRows: [Row] {
    var grouped: [String: Row] = [:]
    for entry in self.entries where entry.day.tokens != nil {
      var represented: Int64 = 0
      for (name, usage) in entry.day.detail?.models ?? [:] {
        let key = entry.provider.rawValue + ":" + name
        var row = grouped[key] ?? Row(label: name, provider: entry.provider)
        Self.add(tokens: usage.tokens, cost: entry.day.costUSD == nil ? nil : usage.costUSD, to: &row)
        grouped[key] = row
        represented = Self.sum([represented, usage.tokens])
      }
      let unknown = max(0, (entry.day.tokens ?? 0) - represented)
      if unknown > 0 {
        let key = entry.provider.rawValue + ":unknown"
        var row = grouped[key] ?? Row(label: Self.unknownModelLabel, provider: entry.provider)
        Self.add(tokens: unknown, cost: represented == 0 ? entry.day.costUSD : nil, to: &row)
        grouped[key] = row
      }
    }
    return Array(grouped.values)
  }
  private func group(_ key: (Entry) -> (String, ProviderID?)) -> [Row] {
    var grouped: [String: Row] = [:]
    for entry in self.entries where entry.day.tokens != nil || entry.day.costUSD != nil {
      let (name, provider) = key(entry)
      var row = grouped[name] ?? Row(label: name, provider: provider)
      Self.add(tokens: entry.day.tokens ?? 0, cost: entry.day.costUSD, to: &row)
      grouped[name] = row
    }
    return Array(grouped.values)
  }
  private static func add(tokens: Int64, cost: Double?, to row: inout Row) {
    row.tokens = Self.sum([row.tokens, tokens]); row.samples += 1
    if let cost = Self.cost(cost) {
      row.costUSD = Self.costSum([row.costUSD ?? 0, cost]); row.pricedSamples += 1
    }
  }
  public static func sum(_ values: [Int64]) -> Int64 {
    values.reduce(0) { value, next in
      let (sum, overflow) = value.addingReportingOverflow(max(0, next))
      return overflow ? .max : sum
    }
  }
  private static func cost(_ value: Double?) -> Double? {
    value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
  private static func costSum(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sum = values.reduce(0, +)
    return sum.isFinite ? sum : nil
  }
}
