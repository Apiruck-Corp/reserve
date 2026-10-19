import Foundation

public struct HourlyUsagePoint: Codable, Equatable, Sendable {
  public let start: Date
  public let tokens: Int64
  public let costUSD: Double?
  public let detail: UsageDayDetail?

  public init(start: Date, tokens: Int64, costUSD: Double?, detail: UsageDayDetail? = nil) {
    self.start = start
    self.detail = detail
    self.tokens = max(0, tokens)
    self.costUSD = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
}

/// Timestamped local records only. Daily account totals are never distributed
/// across hours. The final hour is incomplete as of `observedAt`.
public struct HourlyUsageHistory: Codable, Equatable, Sendable {
  public let provider: ProviderID
  public let dayStart: Date
  public let observedAt: Date
  public let hours: [HourlyUsagePoint]

  public init(provider: ProviderID, dayStart: Date, observedAt: Date, hours: [HourlyUsagePoint]) {
    self.provider = provider
    self.dayStart = dayStart
    self.observedAt = observedAt
    self.hours = hours
  }

  /// The same timestamped records drive Today's headline, token mix and model
  /// rows. They can be published before historical model backfill completes.
  public func dailyUsage(timeZone: TimeZone = .current) -> CachedUsageDay {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var totals = UsageTotals()
    for hour in self.hours {
      guard let detail = hour.detail else { continue }
      totals.add(UsageTotals(input: detail.input, cached: detail.cached, cacheWrite: detail.cacheWrite,
        output: detail.output, costUSD: hour.costUSD ?? 0, estimated: hour.costUSD == nil,
        cacheSavingsUSD: detail.cacheSavingsUSD ?? 0, cacheSavingsKnown: detail.cacheSavingsUSD != nil,
        cacheSavingsUnpricedTokens: detail.unpricedCacheReads, models: detail.models))
    }
    let detail = self.hours.allSatisfy { $0.detail != nil } ? UsageDayDetail(
      input: totals.input, cached: totals.cached, cacheWrite: totals.cacheWrite, output: totals.output,
      cacheSavingsUSD: totals.pricedSavings, unpricedCacheReads: totals.unpricedCacheReads,
      models: totals.models ?? [:]) : nil
    let sum = self.hours.compactMap(\.costUSD).reduce(0, +)
    return CachedUsageDay(day: CachedUsageHistory.dayKey(for: self.dayStart, calendar: calendar),
      tokens: InsightReport.sum(self.hours.map(\.tokens)),
      costUSD: self.hours.allSatisfy { $0.costUSD != nil } && sum.isFinite ? sum : nil,
      fetchedAt: self.observedAt, detail: detail)
  }

  /// Actual hour intervals preserve both repeated hours on a fall-back day.
  /// No future hours are returned, including on 23- and 25-hour civil days.
  public static func hourStarts(now: Date, timeZone: TimeZone = .current) -> [Date] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = calendar.startOfDay(for: now)
    var result: [Date] = []
    var hour = start
    while hour <= now, result.count < 25 {
      result.append(hour)
      hour = hour.addingTimeInterval(3600)
    }
    return result
  }
}
