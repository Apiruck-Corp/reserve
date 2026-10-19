import CryptoKit
import Darwin
import Foundation

/// A separate resumable index keeps hourly migration from changing the daily
/// index or assigning cumulative session totals to a single hour. Only today's
/// modified Claude/Codex files are considered; complete files are read once,
/// then only appended lines. Paths and transcript text are never persisted.
public actor LocalHourlyUsageScanner {
  private struct Row: Codable {
    var hour: String
    var totals: UsageTotals
  }
  private struct Record: Codable {
    var provider: ProviderID
    var anchor: LocalHistoryFileAnchor
    var offset: UInt64 = 0
    var discarding = false
    var hours: [String: UsageTotals] = [:]
    var recent: [String: Row] = [:]
    var order: [String] = []
    var model = ""
    var cumulative: UsageTotals?
    var consumedTailHash: String?
  }
  private struct Index: Codable {
    var version = 3
    var dayStart: Date
    var timeZone: String
    var records: [String: Record] = [:]
    var published: [ProviderID: HourlyUsageHistory] = [:]
  }

  private let roots: LocalUsageScanner.Roots
  private let cacheURL: URL
  private let timeZoneOverride: TimeZone?
  private var timeZone: TimeZone { self.timeZoneOverride ?? .current }
  private var index: Index?
  public private(set) var scanIncomplete = false
  public private(set) var checkpoints = 0
  // Per-pass bounds; persisted offsets let the next pass continue.
  var maximumBytesPerScan = 64 * 1024 * 1024
  var maximumScanDuration: Duration = .seconds(8)

  public init(roots: LocalUsageScanner.Roots = .defaults(), cacheURL: URL? = nil,
              timeZone: TimeZone? = nil) {
    self.roots = roots
    self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Reserve/hourly-usage-index.json")
    self.timeZoneOverride = timeZone
  }

  func setTestingBudget(bytes: Int) { self.maximumBytesPerScan = bytes }

  private func load(now: Date) -> Index {
    let start = HourlyUsageHistory.hourStarts(now: now, timeZone: self.timeZone)[0]
    if let index = self.index, index.dayStart == start, index.timeZone == self.timeZone.identifier {
      return index
    }
    if let data = BoundedFileReader.read(self.cacheURL, maximumBytes: LocalHistoryStorageLimits.indexBytes),
      let saved = try? JSONDecoder().decode(Index.self, from: data), saved.version == 3,
      saved.dayStart == start, saved.timeZone == self.timeZone.identifier,
      saved.records.count <= 5000,
      saved.records.values.allSatisfy({ $0.hours.count <= 25 && $0.recent.count <= 128 && $0.order.count <= 128 }) {
      self.index = saved
      return saved
    }
    let empty = Index(dayStart: start, timeZone: self.timeZone.identifier)
    self.index = empty
    return empty
  }

  public func cachedHistory(now: Date = Date()) -> [ProviderID: HourlyUsageHistory] {
    self.load(now: now).published.filter { $0.value.observedAt <= now }
  }

  @discardableResult
  public func scan(now: Date = Date(), providers: Set<ProviderID> = [.openAI, .anthropic]) throws
    -> [ProviderID: HourlyUsageHistory] {
    var next = self.load(now: now)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = self.timeZone
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: next.dayStart)!
    let started = ContinuousClock.now
    var remaining = self.maximumBytesPerScan
    var incomplete = false
    var progressed = false
    var seen: Set<String> = []
    var available: Set<ProviderID> = []
    let supported = providers.intersection([.openAI, .anthropic])
    for provider in supported.sorted(by: { $0.rawValue < $1.rawValue }) {
      let root = provider == .openAI ? self.roots.codex : self.roots.claude
      guard FileManager.default.fileExists(atPath: root.path) else { continue }
      var enumerationFailed = false
      guard let walker = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
        continue
      }
      available.insert(provider)
      var visited = 0
      while let file = walker.nextObject() as? URL {
        try Task.checkCancellation()
        visited += 1
        guard visited <= 50_000 else { throw LocalHistoryStorageError.capacityExceeded }
        if started.duration(to: .now) >= self.maximumScanDuration { incomplete = true; break }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey])
        if values.isSymbolicLink == true { walker.skipDescendants(); continue }
        guard values.isDirectory != true, file.pathExtension == "jsonl",
          (values.contentModificationDate ?? .distantPast) >= next.dayStart else { continue }
        let digest = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
        let key = provider.rawValue + ":" + digest.map { String(format: "%02x", $0) }.joined()
        seen.insert(key)
        guard seen.count <= 5000 else { throw LocalHistoryStorageError.capacityExceeded }
        guard let opened = DescriptorBoundFile.open(file) else {
          throw UsageProviderError.invalidResponse("hourly history file unavailable")
        }
        defer { opened.close() }
        var info = stat()
        guard fstat(opened.handle.fileDescriptor, &info) == 0 else { throw POSIXError(.EIO) }
        let anchor = LocalHistoryFileAnchor(info)
        var record = next.records[key] ?? Record(provider: provider, anchor: anchor)
        let oldOffset = record.offset
        var tailChanged = false
        if record.offset > 0, record.offset <= anchor.size, record.anchor != anchor {
          tailChanged = record.consumedTailHash != (try Self.tailHash(opened, offset: record.offset))
        }
        if tailChanged || record.anchor.device != anchor.device || record.anchor.inode != anchor.inode
          || anchor.size < record.offset
          || (anchor.size == record.anchor.size && record.anchor != anchor) {
          record = Record(provider: provider, anchor: anchor)
        }
        if record.offset < anchor.size {
          try opened.handle.seek(toOffset: record.offset)
          let buffer = BoundedLineBuffer(discardingOversizedLine: record.discarding)
          var readOffset = record.offset
          while readOffset < anchor.size, remaining > 0,
            started.duration(to: .now) < self.maximumScanDuration {
            try Task.checkCancellation()
            let count = min(64 * 1024, remaining, Int(clamping: anchor.size - Int64(readOffset)))
            guard let data = try opened.handle.read(upToCount: count), !data.isEmpty else { break }
            readOffset += UInt64(data.count)
            remaining -= data.count
            let batch = buffer.append(data)
            for line in batch.lines {
              autoreleasepool { Self.consume(line, record: &record, dayStart: next.dayStart, dayEnd: dayEnd) }
            }
            record.offset += UInt64(batch.consumedBytes)
            record.discarding = batch.discardingOversizedLine
          }
          // An unfinished final JSON line is retried after the writer appends
          // its newline. It does not prevent publishing other complete events.
          if readOffset < anchor.size { incomplete = true }
        }
        if record.offset != oldOffset || next.records[key] == nil { progressed = true }
        if record.offset != oldOffset || tailChanged || record.consumedTailHash == nil {
          record.consumedTailHash = try Self.tailHash(opened, offset: record.offset)
        }
        record.anchor = anchor
        next.records[key] = record
        if incomplete { break }
      }
      if enumerationFailed { throw UsageProviderError.invalidResponse("hourly history directory unavailable") }
      if incomplete { break }
    }
    if !incomplete {
      next.records = next.records.filter { !supported.contains($0.value.provider) || seen.contains($0.key) }
      for provider in supported {
        next.published[provider] = nil
        guard available.contains(provider) else { continue }
        var hours: [String: UsageTotals] = [:]
        for record in next.records.values where record.provider == provider {
          for (hour, totals) in record.hours { hours[hour, default: UsageTotals()].add(totals) }
        }
        let points = HourlyUsageHistory.hourStarts(now: now, timeZone: self.timeZone).map { hour in
          let totals = hours[Self.hourKey(hour, dayStart: next.dayStart)] ?? UsageTotals()
          let priced = totals.totalTokens(provider: provider) == 0
            || (totals.models != nil && totals.models!.values.allSatisfy { $0.costUSD != nil })
          return HourlyUsagePoint(start: hour, tokens: totals.totalTokens(provider: provider),
            costUSD: priced ? totals.costUSD : nil,
            detail: UsageDayDetail(input: totals.input, cached: totals.cached, cacheWrite: totals.cacheWrite,
              output: totals.output, cacheSavingsUSD: totals.pricedSavings,
              unpricedCacheReads: totals.unpricedCacheReads, models: totals.models ?? [:]))
        }
        next.published[provider] = HourlyUsageHistory(provider: provider, dayStart: next.dayStart,
          observedAt: now, hours: points)
      }
    }
    let data = try JSONEncoder().encode(next)
    guard data.count <= LocalHistoryStorageLimits.indexBytes else { throw LocalHistoryStorageError.capacityExceeded }
    try BoundedFileReader.writeRestricted(data, to: self.cacheURL)
    self.index = next
    self.scanIncomplete = incomplete
    if progressed || !incomplete { self.checkpoints += 1 }
    if incomplete { throw UsageProviderError.timedOut("hourly history scan") }
    return next.published
  }

  /// Validate the consumed boundary before accepting an append. This catches
  /// truncation/rewrite followed by growth between scans, as well as rotation.
  private static func tailHash(_ file: DescriptorBoundFile, offset: UInt64) throws -> String {
    let count = min(offset, 4096)
    try file.handle.seek(toOffset: offset - count)
    let data = try file.handle.read(upToCount: Int(count)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func hourKey(_ date: Date, dayStart: Date) -> String {
    String(Int64(dayStart.timeIntervalSince1970 + floor(date.timeIntervalSince(dayStart) / 3600) * 3600))
  }

  private static func consume(_ line: Data, record: inout Record, dayStart: Date, dayEnd: Date) {
    let marker = record.provider == .anthropic ? "assistant" : "token_count"
    guard line.range(of: Data(marker.utf8)) != nil
      || (record.provider == .openAI && line.range(of: Data("turn_context".utf8)) != nil) else { return }
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
    if record.provider == .anthropic {
      guard let row = LocalUsageScanner.parseClaudeObject(object),
        let stamp = object["timestamp"] as? String,
        let timestamp = LocalUsageScanner.parseDate(stamp), timestamp >= dayStart, timestamp < dayEnd else { return }
      let hour = Self.hourKey(timestamp, dayStart: dayStart)
      if let key = row.key {
        if let previous = record.recent[key] {
          record.hours[previous.hour]?.subtract(previous.totals)
          record.order.removeAll { $0 == key }
        }
        record.recent[key] = Row(hour: hour, totals: row.totals)
        record.order.append(key)
        if record.order.count > 128 { record.recent.removeValue(forKey: record.order.removeFirst()) }
      }
      record.hours[hour, default: UsageTotals()].add(row.totals)
      return
    }
    guard let payload = object["payload"] as? [String: Any] else { return }
    if object["type"] as? String == "turn_context" {
      record.model = String((payload["model"] as? String ?? "").prefix(128))
      return
    }
    guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
      let info = payload["info"] as? [String: Any],
      let usage = info["total_token_usage"] as? [String: Any] else { return }
    func counters(_ value: [String: Any]) -> UsageTotals {
      func number(_ name: String) -> Int64 { max(0, (value[name] as? NSNumber)?.int64Value ?? 0) }
      return UsageTotals(input: number("input_tokens"), cached: number("cached_input_tokens"),
        cacheWrite: number("cache_write_input_tokens"), output: number("output_tokens"))
    }
    let current = counters(usage)
    let previous = record.cumulative
    record.cumulative = current
    // Repeated notifications are snapshots, not new usage. A fresh session or
    // reset may inherit totals; its last-request counters are the safer delta.
    if let previous, current.input == previous.input, current.cached == previous.cached,
      current.cacheWrite == previous.cacheWrite, current.output == previous.output { return }
    var delta = current
    if let previous, current.input >= previous.input, current.output >= previous.output {
      delta.subtract(previous)
    } else if let last = info["last_token_usage"] as? [String: Any] {
      delta = counters(last)
    }
    guard let stamp = object["timestamp"] as? String,
      let timestamp = LocalUsageScanner.parseDate(stamp), timestamp >= dayStart, timestamp < dayEnd else { return }
    let priced = Pricing.totals(provider: .openAI, model: record.model, input: delta.input,
      cached: delta.cached, cacheWrite: delta.cacheWrite, output: delta.output, estimated: false)
    record.hours[Self.hourKey(timestamp, dayStart: dayStart), default: UsageTotals()].add(priced)
  }
}
