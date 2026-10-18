import Foundation
import ReserveCore

/// One cached day Insights may chart. Missing days stay absent; a present day
/// with zero tokens is a real zero.
struct InsightHistoryDay: Equatable, Sendable {
  var day: String
  var tokens: Int64?
  var costUSD: Double?
  var detail: UsageDayDetail? = nil
}

struct InsightHistorySeries: Equatable, Sendable {
  var provider: ProviderID
  var days: [InsightHistoryDay]
  /// Days in the selected range that actually have a cached sample.
  var coveredDays: Int
  var requestedDays: Int
  /// False when neither local daily history nor provider account days are supported.
  var available: Bool
  var origin: UsageInsightOrigin = .localDevice
}

enum InsightHistoryRange {
  /// Reads only `published`. Never opens session files and never scans.
  static func series(
    provider: ProviderID,
    days: Int,
    now: Date,
    published: [ProviderID: [InsightHistoryDay]],
    accountDays: [DailyUsage] = []
  ) -> InsightHistorySeries {
    let supported = ProviderDescriptor.forProvider(provider).capabilities.contains(.localHistory)
    guard supported || !accountDays.isEmpty else {
      return InsightHistorySeries(
        provider: provider, days: [], coveredDays: 0, requestedDays: days, available: false)
    }
    let keys = Self.dayKeys(count: days, now: now)
    let selectedKeys = Set(keys)
    let useAccount = !(published[provider] ?? []).contains { selectedKeys.contains($0.day) && $0.tokens != nil }
      && !accountDays.isEmpty
    var byDay: [String: InsightHistoryDay] = [:]
    if useAccount {
      for day in accountDays { byDay[day.day] = InsightHistoryDay(day: day.day, tokens: day.tokens, costUSD: nil) }
    } else {
      for day in published[provider] ?? [] { byDay[day.day] = day }
    }
    let rows = keys.map { key -> InsightHistoryDay in
      if let sample = byDay[key] {
        return InsightHistoryDay(day: key, tokens: sample.tokens, costUSD: sample.costUSD, detail: sample.detail)
      }
      return InsightHistoryDay(day: key, tokens: nil, costUSD: nil)
    }
    let covered = rows.filter { $0.tokens != nil }.count
    return InsightHistorySeries(
      provider: provider, days: rows, coveredDays: covered, requestedDays: days, available: true, origin: useAccount ? .providerAccount : .localDevice)
  }

  /// Calendar dates, oldest first, ending today. Future dates are excluded.
  static func dayKeys(count: Int, now: Date, calendar: Calendar = .current) -> [String] {
    var civil = Calendar(identifier: .gregorian)
    civil.timeZone = calendar.timeZone
    let calendar = civil
    let count = min(90, max(1, count))
    let start = calendar.startOfDay(for: now)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return (0..<count).reversed().compactMap { offset in
      calendar.date(byAdding: .day, value: -offset, to: start).map { formatter.string(from: $0) }
    }
  }
}
