import Foundation

/// What a usage surface may state about one period, derived only from
/// published history. A figure Reserve cannot back is absent rather than shown
/// as zero, and one that covers only part of the period says so.
public struct UsageGlance: Equatable, Sendable {
  /// Cost leads when at least one provider has a known API price for every
  /// active day. Providers without one are named, never priced at zero.
  public enum Lead: Equatable, Sendable { case cost, tokens }

  public struct Line: Equatable, Sendable {
    public var label: String
    public var provider: ProviderID?
    public var tokens: Int64
    /// Nil unless every active day of this line's provider is priced.
    public var costUSD: Double?
    /// Fraction of the period total in the glance's lead metric. Nil when the
    /// line has no value in that metric.
    public var share: Double?
  }

  public var tokens: Int64
  /// API-price estimate for the fully priced providers. Nil when there are none.
  public var costUSD: Double?
  /// Active providers left out of `costUSD` because some usage has no price.
  public var unpricedProviders: [ProviderID]
  public var lead: Lead
  public var activeDays: Int
  /// Provider-days with a published sample, active or not.
  public var coveredDays: Int
  public var providers: [Line]
  /// Named models, ranked. Usage no record names a model for is in `unattributed`.
  public var models: [Line]
  public var unattributed: [Line]
  /// Token types from the days that recorded them. Nil when none did.
  public var tokenMix: TokenMix?
  /// Active provider-days with token types, out of all active provider-days.
  public var tokenMixDays: (detailed: Int, active: Int)
  public var cacheSavingsUSD: Double?
  public var cacheSavingsIsPartial: Bool

  public var hasUsage: Bool { self.tokens > 0 }
  public var tokenMixIsPartial: Bool { self.tokenMixDays.detailed < self.tokenMixDays.active }

  public init(report: InsightReport, modelLimit: Int = .max) {
    let active = report.entries.filter { ($0.day.tokens ?? 0) > 0 }
    self.tokens = report.tokens
    self.activeDays = report.activeDays
    self.coveredDays = report.coveredDays
    var activeProviders: [ProviderID] = []
    for entry in active where !activeProviders.contains(entry.provider) {
      activeProviders.append(entry.provider)
    }
    let priced = Set(activeProviders.filter { provider in
      active.allSatisfy { $0.provider != provider || Self.isPrice($0.day.costUSD) }
    })
    self.unpricedProviders = activeProviders.filter { !priced.contains($0) }
    let pricedCost = InsightReport(entries: report.entries.filter { priced.contains($0.provider) }).costUSD
    self.costUSD = priced.isEmpty ? nil : pricedCost
    self.lead = (self.costUSD ?? 0) > 0 ? .cost : .tokens

    let detailed = active.filter { $0.day.detail != nil }
    self.tokenMixDays = (detailed.count, active.count)
    let mix = report.tokenMix
    let mixHasTokens = mix.uncachedInput > 0 || mix.cachedInput > 0 || mix.cacheWrite > 0 || mix.output > 0
    self.tokenMix = detailed.isEmpty || !mixHasTokens ? nil : mix
    if let mix = self.tokenMix, mix.cachedInput > 0, let savings = report.cacheSavingsUSD {
      self.cacheSavingsUSD = savings
      self.cacheSavingsIsPartial = report.unpricedCacheReads > 0 || detailed.count < active.count
    } else {
      self.cacheSavingsUSD = nil
      self.cacheSavingsIsPartial = false
    }

    let lead = self.lead
    let total = lead == .cost ? (self.costUSD ?? 0) : Double(self.tokens)
    func line(_ row: InsightReport.Row) -> Line {
      let isPriced = row.provider.map(priced.contains) ?? false
      let cost = isPriced && row.pricedSamples == row.samples ? row.costUSD : nil
      let value = lead == .cost ? cost : Double(row.tokens)
      return Line(label: row.label, provider: row.provider, tokens: row.tokens, costUSD: cost,
        share: total > 0 ? value.map { $0 / total } : nil)
    }
    func ordered(_ rows: [InsightReport.Row]) -> [Line] {
      rows.filter { $0.tokens > 0 }.map(line).sorted {
        let a = lead == .cost ? ($0.costUSD ?? -1) : Double($0.tokens)
        let b = lead == .cost ? ($1.costUSD ?? -1) : Double($1.tokens)
        if a != b { return a > b }
        if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
        return ($0.label, $0.provider?.rawValue ?? "") < ($1.label, $1.provider?.rawValue ?? "")
      }
    }
    self.providers = ordered(report.providerRows)
    let models = ordered(report.modelRows)
    self.models = Array(models.filter { $0.label != InsightReport.unknownModelLabel }
      .prefix(max(0, modelLimit)))
    self.unattributed = models.filter { $0.label == InsightReport.unknownModelLabel }
  }

  public static func == (lhs: UsageGlance, rhs: UsageGlance) -> Bool {
    lhs.tokens == rhs.tokens && lhs.costUSD == rhs.costUSD
      && lhs.unpricedProviders == rhs.unpricedProviders
      && lhs.lead == rhs.lead && lhs.activeDays == rhs.activeDays && lhs.coveredDays == rhs.coveredDays
      && lhs.providers == rhs.providers && lhs.models == rhs.models
      && lhs.unattributed == rhs.unattributed && lhs.tokenMix == rhs.tokenMix
      && lhs.tokenMixDays == rhs.tokenMixDays && lhs.cacheSavingsUSD == rhs.cacheSavingsUSD
      && lhs.cacheSavingsIsPartial == rhs.cacheSavingsIsPartial
  }

  private static func isPrice(_ value: Double?) -> Bool {
    value.map { $0.isFinite && $0 >= 0 } ?? false
  }
}
