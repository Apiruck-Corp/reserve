import Foundation

/// Detail observed in cached source records. Absent on older archive days.
public struct UsageDayDetail: Codable, Equatable, Sendable {
  public var input: Int64
  public var cached: Int64
  public var cacheWrite: Int64
  public var output: Int64
  public var cacheSavingsUSD: Double?
  public var unpricedCacheReads: Int64
  public var models: [String: InsightModelUsage]

  public init(input: Int64, cached: Int64, cacheWrite: Int64, output: Int64,
              cacheSavingsUSD: Double?, unpricedCacheReads: Int64,
              models: [String: InsightModelUsage] = [:]) {
    self.input = max(0, input)
    self.cached = max(0, cached)
    self.cacheWrite = max(0, cacheWrite)
    self.output = max(0, output)
    self.cacheSavingsUSD = cacheSavingsUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    self.unpricedCacheReads = max(0, unpricedCacheReads)
    self.models = Dictionary(uniqueKeysWithValues: models.sorted { $0.key < $1.key }.prefix(128).map { ($0.key, $0.value) })
  }
}

public struct InsightModelUsage: Codable, Equatable, Sendable {
  public var tokens: Int64
  public var costUSD: Double?

  public init(tokens: Int64, costUSD: Double?) {
    self.tokens = max(0, tokens)
    self.costUSD = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }

  public mutating func add(_ other: Self) {
    let (sum, overflow) = self.tokens.addingReportingOverflow(other.tokens)
    self.tokens = overflow ? .max : sum
    if let a = self.costUSD, let b = other.costUSD, (a + b).isFinite {
      self.costUSD = a + b
    } else { self.costUSD = nil }
  }

  mutating func subtract(_ other: Self) {
    self.tokens = max(0, self.tokens - other.tokens)
    if let a = self.costUSD, let b = other.costUSD { self.costUSD = max(0, a - b) }
    else { self.costUSD = nil }
  }
}
