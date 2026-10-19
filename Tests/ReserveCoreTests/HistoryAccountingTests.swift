import Foundation
import Testing
@testable import ReserveCore

@Suite("Local history accounting")
struct HistoryAccountingTests {
  @Test func alreadyPricedLegacyRecordsBackfillTokenSplitAndModelsOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-19T12:00:00Z")
    let claude = #"{"timestamp":"2026-10-19T10:00:00Z","type":"assistant","requestId":"r","message":{"id":"m","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":5}}}"# + "\n"
    try Data(claude.utf8).write(to: fixture.claude.appendingPathComponent("session.jsonl"))
    try fixture.writeCodex("session.jsonl", input: 200, writes: 10, output: 5, at: now)
    let codexFile = fixture.codex.appendingPathComponent("session.jsonl")
    let context = #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"# + "\n"
    try (Data(context.utf8) + Data(contentsOf: codexFile)).write(to: codexFile)
    _ = try await fixture.scanner(zone: "UTC").scan(now: now, providers: [.anthropic, .openAI])
    // Simulate the actual installed preview's cache: priced and current, but
    // predating model dictionaries and the daily detail envelope.
    var object = try fixture.index()
    func legacy(_ value: Any) -> Any {
      if var dict = value as? [String: Any] {
        for name in ["models", "detail", "insightDetailsVersion"] { dict.removeValue(forKey: name) }
        for (key, item) in dict { dict[key] = legacy(item) }
        return dict
      }
      if let array = value as? [Any] { return array.map(legacy) }
      return value
    }
    object = legacy(object) as! [String: Any]
    try fixture.writeIndex(object)
    let scanner = fixture.scanner(zone: "UTC")
    let cached = await scanner.cachedHistory(now: now, providers: [.anthropic, .openAI])
    #expect(cached[.anthropic]?.days.last?.detail?.cached == 100)
    #expect(cached[.anthropic]?.days.last?.detail?.models.isEmpty == true)
    let result = try await scanner.scan(now: now, providers: [.anthropic, .openAI])
    #expect(result[.anthropic]?.totalTokens == 135)
    let history = await scanner.cachedHistory(now: now, providers: [.anthropic, .openAI])
    #expect(history[.anthropic]?.days.last?.detail?.models["claude-opus-5"]?.tokens == 135)
    #expect(history[.openAI]?.days.last?.detail?.models["gpt-5.4"]?.tokens == 205)
    #expect(history[.anthropic]?.days.last?.detail?.cacheWrite == 20)
    #expect(await scanner.scanMetrics.filesParsed == 2)
    _ = try await scanner.scan(now: now, providers: [.anthropic, .openAI])
    #expect(await scanner.scanMetrics.filesParsed == 2)
    let reloaded = await fixture.scanner(zone: "UTC").cachedHistory(now: now, providers: [.anthropic, .openAI])
    #expect(reloaded == history)
  }

  @Test func historyAboveTheOldStorageLimitPublishesReloadsAndDeduplicates() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-19T12:00:00Z")
    let fileCount = 384
    let rowsPerFile = 128
    func line(file: Int, row: Int, input: Int = 10) -> String {
      let message = String(repeating: "m", count: 48) + "-\(file)-\(row)"
      let request = String(repeating: "r", count: 48) + "-\(file)-\(row)"
      return #"{"timestamp":"2026-10-19T12:00:00Z","type":"assistant","requestId":"\#(request)","message":{"id":"\#(message)","model":"claude-opus-5","usage":{"input_tokens":\#(input),"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":1}}}"#
    }
    for file in 0..<fileCount {
      let lines = (0..<rowsPerFile).map { line(file: file, row: $0) }
      try Data((lines.joined(separator: "\n") + "\n").utf8).write(
        to: fixture.claude.appendingPathComponent("session-\(file).jsonl"))
    }
    let expected = Int64(fileCount * rowsPerFile * 131)
    let legacy = fixture.scanner(zone: "UTC")
    await legacy.testingSetMaximumIndexBytes(12 * 1024 * 1024)
    await legacy.testingSetBudget(maximumDuration: .seconds(60))
    await #expect(throws: LocalHistoryStorageError.capacityExceeded) {
      _ = try await legacy.scan(now: now, providers: [.anthropic])
    }
    #expect(await legacy.testingCheckpointExists())
    let scanner = fixture.scanner(zone: "UTC")
    // This fixture isolates storage capacity from the per-pass time budget.
    await scanner.testingSetBudget(maximumDuration: .seconds(60))
    let first = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(first[.anthropic]?.totalTokens == expected)
    #expect(await scanner.scanMetrics.resumes == 1)
    let published = try Data(contentsOf: fixture.cache)
    #expect(published.count > 12 * 1024 * 1024)
    #expect(published.count <= LocalHistoryStorageLimits.indexBytes)
    #expect(await scanner.testingHasResidentIndex() == false)

    let restarted = fixture.scanner(zone: "UTC")
    let cached = try await restarted.cachedUsage(now: now, providers: [.anthropic])
    #expect(cached[.anthropic]?.totalTokens == expected)
    let history = await restarted.cachedHistory(now: now, providers: [.anthropic])
    #expect(history[.anthropic]?.days.last?.tokens == expected)

    // A revised streaming row replaces its persisted contribution after a
    // restart instead of being counted twice or losing its original tokens.
    let session = fixture.claude.appendingPathComponent("session-0.jsonl")
    let handle = try FileHandle(forWritingTo: session)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line(file: 0, row: 127, input: 25) + "\n").utf8))
    try handle.close()
    await restarted.testingSetBudget(maximumDuration: .seconds(60))
    let revised = try await restarted.scan(now: now, providers: [.anthropic])
    #expect(revised[.anthropic]?.totalTokens == expected + 15)
    #expect(await restarted.testingCheckpointExists() == false)
  }

  @Test func capacityFailurePreservesThePublishedHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-19T12:00:00Z")
    try await fixture.seedLegacyClaude(now: now)
    let published = try Data(contentsOf: fixture.cache)
    let scanner = fixture.scanner(zone: "UTC")
    await scanner.testingSetMaximumIndexBytes(published.count + 512)
    let lines = (0..<128).map { row in
      Fixture.claudeLine(stamp: "2026-10-19T12:00:00Z", input: 20)
        .replacingOccurrences(of: "m1", with: "message-\(row)")
    }
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(
      to: fixture.claude.appendingPathComponent("new.jsonl"))
    await #expect(throws: LocalHistoryStorageError.capacityExceeded) {
      _ = try await scanner.scan(now: now, providers: [.anthropic])
    }
    #expect(try Data(contentsOf: fixture.cache) == published)
    #expect(await scanner.testingCheckpointExists())
    let cached = try await fixture.scanner(zone: "UTC").cachedUsage(
      now: now, providers: [.anthropic])
    #expect(cached[.anthropic]?.todayTokens == 11)
  }

  @Test func storedRowsKeepTheirDeduplicationKeyInTheTable() throws {
    let key = "message-id:request-id"
    let row = CachedRow(key: key, dayKey: "2026-10-08",
      totals: UsageTotals(input: 10, output: 1), previousDayKey: "2026-10-09")
    let encoded = try JSONEncoder().encode([key: row])
    let table = try JSONDecoder().decode([String: CachedRow].self, from: encoded)
    let stored = try #require(table[key])
    #expect(stored.key == nil)
    #expect(stored.dayKey == row.dayKey && stored.previousDayKey == row.previousDayKey)
    #expect(stored.totals == row.totals)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(text.components(separatedBy: key).count == 2)
    // Previous versions wrote the duplicate inside the value. They still read.
    let legacy = Data(#"{"key":"message-id:request-id","dayKey":"2026-10-08","totals":{"input":10,"output":1}}"#.utf8)
    #expect(try JSONDecoder().decode(CachedRow.self, from: legacy).key == key)
  }

  @Test func compactTotalsKeepDefaultValuesAndSavingsKnowledge() throws {
    let totals = [
      UsageTotals(),
      UsageTotals(input: 10, output: 2, costUSD: 1, estimated: true),
      UsageTotals(cached: 10, cacheSavingsUSD: 0.2, cacheSavingsKnown: true),
      UsageTotals(cacheSavingsKnown: true),
      UsageTotals(cached: 10, cacheSavingsKnown: false),
      UsageTotals(cached: 10),
    ]
    for value in totals {
      let data = try JSONEncoder().encode(value)
      #expect(try JSONDecoder().decode(UsageTotals.self, from: data) == value)
    }
    let empty = try JSONEncoder().encode(UsageTotals())
    #expect(String(decoding: empty, as: UTF8.self) == "{}")
  }

  @Test func aLargerTemporaryCheckpointCanResume() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    try await fixture.seedLegacyClaude(now: now)
    let object = try #require(JSONSerialization.jsonObject(
      with: Data(contentsOf: fixture.cache)) as? [String: Any])
    var records = try JSONSerialization.data(withJSONObject: try #require(object["records"]))
    // JSON whitespace keeps the decoded fixture small while its base64
    // envelope exercises the separate migration-file allowance.
    records.append(Data(repeating: 32, count: 20 * 1024 * 1024 - records.count))
    let checkpoint = LocalHistoryCheckpoint(
      version: 1,
      anchor: LocalHistoryIndexFile.anchor(url: fixture.cache, maximumBytes: 12 * 1024 * 1024),
      removedKeys: [], needsFinalize: false, retainedKeys: [],
      dirtyProviders: [ProviderID.anthropic.rawValue], pruneProviders: [], tokens: [:],
      recordsJSON: records)
    #expect(try LocalHistoryCheckpointStore.save(
      checkpoint, cacheURL: fixture.cache,
      maximumBytes: LocalHistoryStorageLimits.checkpointBytes,
      fileManager: .default))
    #expect(try Data(contentsOf: LocalHistoryCheckpoint.url(for: fixture.cache)).count
      > 24 * 1024 * 1024)
    let scanner = fixture.scanner(zone: "America/New_York")
    let usage = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(usage[.anthropic]?.totalTokens == 11)
    #expect(await scanner.scanMetrics.resumes == 1)
    #expect(await scanner.testingCheckpointExists() == false)
  }

  @Test func anExhaustedSharedBudgetCheckpointsCompleteClaudeLines() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    let session = try await fixture.seedLegacyClaude(now: now)
    let prefix = try Data(contentsOf: session)
    let replacement = Fixture.claudeLine(
      stamp: ISO8601DateFormatter().string(from: now), input: 20)
    try (prefix + Data((replacement + "\n").utf8)).write(to: session)
    let saved = try Data(contentsOf: fixture.cache)
    let partial = fixture.scanner(zone: "America/New_York")
    await partial.testingSetBudget(maximumBytes: prefix.count)
    await #expect(throws: UsageProviderError.self) {
      _ = try await partial.scan(now: now, providers: [.anthropic])
    }
    #expect(await partial.scanMetrics.filesParsed == 1)
    #expect(await partial.scanMetrics.checkpoints == 1)
    #expect(await partial.testingCheckpointExists())
    #expect(try Data(contentsOf: fixture.cache) == saved)
    let resumed = fixture.scanner(zone: "America/New_York")
    let usage = try await resumed.scan(now: now, providers: [.anthropic])
    #expect(usage[.anthropic]?.todayTokens == 21)
    #expect(await resumed.scanMetrics.resumes == 1)
    #expect(await resumed.testingCheckpointExists() == false)
  }

  @Test func cachedTotalsStayReadableDuringAnInterruptedMigration() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    try await fixture.seedLegacyClaude(now: now)
    let saved = try Data(contentsOf: fixture.cache)
    let scanner = fixture.scanner(zone: "America/New_York")
    let before = try await scanner.cachedUsage(now: now, providers: [.anthropic])
    #expect(before[.anthropic]?.totalTokens == 11)
    await scanner.testingSetMaximumBytesPerFile(1)
    await #expect(throws: UsageProviderError.self) {
      _ = try await scanner.scan(now: now, providers: [.anthropic])
    }
    let parsed = await scanner.scanMetrics.filesParsed
    let during = try await scanner.cachedUsage(now: now, providers: [.anthropic])
    #expect(during == before)
    #expect(await scanner.scanMetrics.filesParsed == parsed)
    #expect(try Data(contentsOf: fixture.cache) == saved)
    #expect(await scanner.testingCheckpointExists())
    let restarted = fixture.scanner(zone: "America/New_York")
    #expect(try await restarted.cachedUsage(now: now, providers: [.anthropic]) == before)
    #expect(await restarted.scanMetrics.filesParsed == 0)
  }

  @Test func cachedTotalsRespectThePeriodAndDoNotNeedSessionRoots() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-08T17:00:00Z")
    try fixture.writeCodex(
      "old.jsonl", input: 2_000, writes: 200, output: 40,
      at: Fixture.date("2026-09-08T17:00:00Z"))
    try fixture.writeCodex("current.jsonl", input: 1_000, writes: 100, output: 20, at: now)
    _ = try await fixture.scanner(zone: "UTC").scan(periodDays: 90, now: now, providers: [.openAI])
    let saved = try Data(contentsOf: fixture.cache)
    let reader = LocalUsageScanner(
      roots: .init(
        codex: fixture.root.appendingPathComponent("missing-codex"),
        claude: fixture.root.appendingPathComponent("missing-claude"),
        grok: fixture.root.appendingPathComponent("missing-grok")),
      cacheURL: fixture.cache, timeZone: TimeZone(identifier: "UTC"))
    let usage = try await reader.cachedUsage(now: now, providers: [.openAI, .grok])
    #expect(usage[.openAI]?.totalTokens == 1_020)
    #expect(usage[.openAI]?.todayTokens == 1_020)
    #expect(usage[.openAI]?.dailyTokens.count == 30)
    #expect(usage[.openAI]?.fetchedAt == now)
    #expect(usage[.grok] == nil)
    #expect(await reader.scanMetrics.filesParsed == 0)
    #expect(try Data(contentsOf: fixture.cache) == saved)
  }

  @Test(arguments: [
    ("America/New_York", "2026-10-09T01:30:00Z", "2026-10-08"),
    ("America/New_York", "2026-11-01T05:30:00Z", "2026-11-01"),
    ("America/New_York", "2026-11-01T06:30:00Z", "2026-11-01"),
    ("Pacific/Auckland", "2026-10-08T12:30:00Z", "2026-10-09"),
    ("UTC", "2026-10-09T01:30:00Z", "2026-10-09"),
  ])
  func claudeUsesTheLocalCivilDay(zone: String, stamp: String, day: String) throws {
    let line = Fixture.claudeLine(stamp: stamp, input: 10)
    let timeZone = try #require(TimeZone(identifier: zone))
    let row = try #require(LocalUsageScanner.parseClaudeLine(
      Data(line.utf8), timeZone: timeZone))
    #expect(row.dayKey == day)
    #expect(row.totals.totalTokens(provider: .anthropic) == 11)
    #expect(LocalUsageScanner.parseClaudeLine(Data(
      Fixture.claudeLine(stamp: "2026-99-99Tbad", input: 10).utf8)) == nil)
  }

  @Test func oldOpenAIArchivesAreRepairedWithoutReparsingOrWritingDuringARead() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-08T17:00:00Z")
    try fixture.writeCodex("first.jsonl", input: 1_000, writes: 100, output: 20, at: now)
    try fixture.writeCodex("second.jsonl", input: 2_000, writes: 200, output: 40, at: now)
    _ = try await fixture.scanner(zone: "UTC").scan(now: now, providers: [.openAI])
    try fixture.editArchive(.openAI) { archive in
      archive["2026-10-08"]?.tokens = 3_360
      archive["2026-09-01"] = ArchivedDay(tokens: 777, costUSD: 1, fetchedAt: now)
    }
    let before = try Data(contentsOf: fixture.cache)
    let scanner = fixture.scanner(zone: "UTC", watchChanges: true)
    await scanner.testingSimulateWatch()
    let read = await scanner.cachedHistory(now: now, providers: [.openAI])
    #expect(read[.openAI]?.days.first { $0.day == "2026-10-08" }?.tokens == 3_060)
    #expect(try Data(contentsOf: fixture.cache) == before)
    let usage = try await scanner.scan(now: now, providers: [.openAI])
    #expect(usage[.openAI]?.todayTokens == 3_060)
    #expect(usage[.openAI]?.totalTokens == 3_060)
    #expect(await scanner.scanMetrics.filesParsed == 0)
    #expect(try fixture.archive(.openAI)["2026-10-08"]?.tokens == 3_060)
    #expect(try fixture.archive(.openAI)["2026-09-01"]?.tokens == 777)
    let settled = try Data(contentsOf: fixture.cache)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(try Data(contentsOf: fixture.cache) == settled)
    #expect(await scanner.scanMetrics.filesParsed == 0)
  }

  @Test func unmatchedOpenAIArchiveIsPreserved() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-08T17:00:00Z")
    try fixture.writeCodex("session.jsonl", input: 1_000, writes: 100, output: 20, at: now)
    _ = try await fixture.scanner(zone: "UTC").scan(now: now, providers: [.openAI])
    try fixture.editArchive(.openAI) { archive in
      archive["2026-10-08"]?.tokens = 50_000
    }
    let saved = try Data(contentsOf: fixture.cache)
    let scanner = fixture.scanner(zone: "UTC")
    let history = await scanner.cachedHistory(now: now, providers: [.openAI])
    #expect(history[.openAI]?.days.first { $0.day == "2026-10-08" }?.tokens == 50_000)
    #expect(try Data(contentsOf: fixture.cache) == saved)
    _ = try await scanner.scan(now: now, providers: [.openAI])
    #expect(try fixture.archive(.openAI)["2026-10-08"]?.tokens == 50_000)
  }

  @Test func legacyClaudeDaysAreRebucketedOnceAndArchiveOnlyDaysSurvive() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    try await fixture.seedLegacyClaude(now: now)
    let scanner = fixture.scanner(zone: "America/New_York", watchChanges: true)
    await scanner.testingSimulateWatch()
    let usage = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(usage[.anthropic]?.todayTokens == 11)
    #expect(usage[.anthropic]?.dailyTokens.last == DailyUsage(day: "2026-10-08", tokens: 11))
    let archive = try fixture.archive(.anthropic)
    #expect(archive["2026-10-08"]?.tokens == 11)
    #expect(archive["2026-10-09"] == nil)
    #expect(archive["2026-09-01"]?.tokens == 777)
    let history = await scanner.cachedHistory(now: now, providers: [.anthropic])
    #expect(history[.anthropic]?.days.first { $0.day == "2026-10-08" }?.tokens == 11)
    #expect(history[.anthropic]?.days.reduce(Int64(0)) { $0 + ($1.tokens ?? 0) } == 788)
    #expect(await scanner.scanMetrics.filesParsed == 1)
    let saved = try Data(contentsOf: fixture.cache)
    _ = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(await scanner.scanMetrics.filesParsed == 1)
    #expect(try Data(contentsOf: fixture.cache) == saved)
    #expect(String(decoding: saved, as: UTF8.self).contains("rebucketedFromDays") == false)
  }

  @Test func interruptedDayMigrationKeepsPublishedHistoryAndResumesAfterRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    try await fixture.seedLegacyClaude(now: now)
    let saved = try Data(contentsOf: fixture.cache)
    let interrupted = fixture.scanner(zone: "America/New_York")
    await interrupted.testingSetMaximumBytesPerFile(1)
    await #expect(throws: UsageProviderError.self) {
      _ = try await interrupted.scan(now: now, providers: [.anthropic])
    }
    #expect(await interrupted.scanIncomplete)
    #expect(try Data(contentsOf: fixture.cache) == saved)
    let restarted = fixture.scanner(zone: "America/New_York")
    let usage = try await restarted.scan(now: now, providers: [.anthropic])
    #expect(usage[.anthropic]?.todayTokens == 11)
    #expect(try fixture.archive(.anthropic)["2026-10-08"]?.tokens == 11)
    #expect(try fixture.archive(.anthropic)["2026-09-01"]?.tokens == 777)
    #expect(await restarted.scanIncomplete == false)
    #expect(await restarted.testingCheckpointExists() == false)
  }

  @Test func unreadableDayMigrationKeepsTheArchiveUntilRecovery() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    let session = try await fixture.seedLegacyClaude(now: now)
    let saved = try Data(contentsOf: fixture.cache)
    let scanner = fixture.scanner(zone: "America/New_York")
    await scanner.testingSetMaximumBytesPerFile(1)
    await #expect(throws: UsageProviderError.self) {
      _ = try await scanner.scan(now: now, providers: [.anthropic])
    }
    await scanner.testingSetMaximumBytesPerFile(8 * 1024 * 1024)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: session.path)
    _ = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(try Data(contentsOf: fixture.cache) == saved)
    #expect(await scanner.scanIncomplete)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.path)
    let recovered = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(recovered[.anthropic]?.todayTokens == 11)
    #expect(try fixture.archive(.anthropic)["2026-09-01"]?.tokens == 777)
  }

  @Test func aTimeZoneChangeRebucketsPreviouslyMigratedClaudeHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    try await fixture.seedLegacyClaude(now: now)
    _ = try await fixture.scanner(zone: "America/New_York").scan(now: now, providers: [.anthropic])
    let utc = fixture.scanner(zone: "UTC")
    let usage = try await utc.scan(now: now, providers: [.anthropic])
    #expect(usage[.anthropic]?.todayTokens == 11)
    #expect(usage[.anthropic]?.dailyTokens.last?.day == "2026-10-09")
    #expect(try fixture.archive(.anthropic)["2026-10-08"] == nil)
    #expect(try fixture.archive(.anthropic)["2026-10-09"]?.tokens == 11)
    #expect(try fixture.archive(.anthropic)["2026-09-01"]?.tokens == 777)
  }

  @Test func aParsedPrefixAndReplacementRowResumeWithoutDuplicatingUsage() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    let session = try await fixture.seedLegacyClaude(now: now)
    let prefix = try Data(contentsOf: session)
    let replacement = Fixture.claudeLine(
      stamp: ISO8601DateFormatter().string(from: now), input: 20)
    try (prefix + Data((replacement + "\n").utf8)).write(to: session)
    let saved = try Data(contentsOf: fixture.cache)
    let partial = fixture.scanner(zone: "America/New_York")
    await partial.testingSetMaximumBytesPerFile(prefix.count)
    await #expect(throws: UsageProviderError.self) {
      _ = try await partial.scan(now: now, providers: [.anthropic])
    }
    #expect(try Data(contentsOf: fixture.cache) == saved)
    let resumed = fixture.scanner(zone: "America/New_York")
    let usage = try await resumed.scan(now: now, providers: [.anthropic])
    #expect(usage[.anthropic]?.todayTokens == 21)
    #expect(try fixture.archive(.anthropic)["2026-10-08"]?.tokens == 21)
    #expect(try fixture.archive(.anthropic)["2026-10-09"] == nil)
    #expect(await resumed.scanMetrics.resumes == 1)
  }

  @Test func missingRootAndCancellationLeaveAnInterruptedMigrationPublishedStateAlone() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    try await fixture.seedLegacyClaude(now: now)
    let saved = try Data(contentsOf: fixture.cache)
    let scanner = fixture.scanner(zone: "America/New_York", watchChanges: true)
    await scanner.testingSimulateWatch()
    await scanner.testingSetMaximumBytesPerFile(1)
    await #expect(throws: UsageProviderError.self) {
      _ = try await scanner.scan(now: now, providers: [.anthropic])
    }
    let cancelled = Task {
      _ = try await scanner.scan(now: now, providers: [.anthropic])
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try Data(contentsOf: fixture.cache) == saved)
    let moved = fixture.root.appendingPathComponent("claude-moved")
    try FileManager.default.moveItem(at: fixture.claude, to: moved)
    _ = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(try Data(contentsOf: fixture.cache) == saved)
    #expect(await scanner.testingCheckpointExists())
    try FileManager.default.moveItem(at: moved, to: fixture.claude)
    await scanner.testingSetMaximumBytesPerFile(8 * 1024 * 1024)
    let recovered = try await scanner.scan(now: now, providers: [.anthropic])
    #expect(recovered[.anthropic]?.todayTokens == 11)
    #expect(try fixture.archive(.anthropic)["2026-09-01"]?.tokens == 777)
  }

  @Test func rebucketingKeepsAnArchivedRemainderFromUnavailableSources() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-10T17:00:00Z")
    try await fixture.seedLegacyClaude(now: Fixture.date("2026-10-09T01:30:00Z"))
    try fixture.editArchive(.anthropic) { archive in
      archive["2026-10-09"]?.tokens = 111
      archive["2026-10-09"]?.costUSD = nil
    }
    _ = try await fixture.scanner(zone: "America/New_York").scan(now: now, providers: [.anthropic])
    let archive = try fixture.archive(.anthropic)
    #expect(archive["2026-10-08"]?.tokens == 11)
    #expect(archive["2026-10-09"]?.tokens == 100)
    #expect(archive["2026-10-09"]?.costUSD == nil)
    #expect(archive["2026-09-01"]?.tokens == 777)
    #expect(archive.values.reduce(Int64(0)) { $0 + $1.tokens } == 888)
  }

  @Test func changingTimeZoneDuringAMigrationKeepsTheOriginalSourceDayGrouping() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Fixture.date("2026-10-09T01:30:00Z")
    try await fixture.seedLegacyClaude(now: now)
    try fixture.editArchive(.anthropic) { archive in
      archive["2026-10-08"] = ArchivedDay(tokens: 100, costUSD: nil, fetchedAt: now)
    }
    let interrupted = fixture.scanner(zone: "America/New_York")
    await interrupted.testingSetMaximumBytesPerFile(1)
    await #expect(throws: UsageProviderError.self) {
      _ = try await interrupted.scan(now: now, providers: [.anthropic])
    }
    _ = try await fixture.scanner(zone: "Pacific/Auckland").scan(now: now, providers: [.anthropic])
    let archive = try fixture.archive(.anthropic)
    #expect(archive["2026-10-08"]?.tokens == 100)
    #expect(archive["2026-10-09"]?.tokens == 11)
    #expect(archive["2026-09-01"]?.tokens == 777)
  }

  private struct ArchivedDay: Codable {
    var tokens: Int64
    var costUSD: Double?
    var fetchedAt: Date
  }

  private struct Fixture {
    let root: URL
    let codex: URL
    let claude: URL
    let grok: URL
    let cache: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      codex = root.appendingPathComponent("codex")
      claude = root.appendingPathComponent("claude")
      grok = root.appendingPathComponent("grok")
      cache = root.appendingPathComponent("index.json")
      for directory in [codex, claude, grok] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func scanner(zone: String, watchChanges: Bool = false) -> LocalUsageScanner {
      LocalUsageScanner(roots: .init(codex: codex, claude: claude, grok: grok),
        cacheURL: cache, watchChanges: watchChanges, timeZone: TimeZone(identifier: zone)!)
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func claudeLine(stamp: String, input: Int64) -> String {
      #"{"timestamp":"\#(stamp)","type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":\#(input),"output_tokens":1}}}"#
    }

    func writeCodex(_ name: String, input: Int64, writes: Int64, output: Int64, at now: Date) throws {
      let stamp = ISO8601DateFormatter().string(from: now)
      let line = #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cache_write_input_tokens":\#(writes),"output_tokens":\#(output)}}}}"#
      try Data((line + "\n").utf8).write(to: codex.appendingPathComponent(name))
    }

    @discardableResult
    func seedLegacyClaude(now: Date) async throws -> URL {
      let session = claude.appendingPathComponent("session.jsonl")
      let line = Self.claudeLine(stamp: ISO8601DateFormatter().string(from: now), input: 10)
      try Data((line + "\n").utf8).write(to: session)
      _ = try await scanner(zone: "UTC").scan(now: now, providers: [.anthropic])
      var object = try index()
      var records = try #require(object["records"] as? [String: [String: Any]])
      for key in records.keys { records[key]?.removeValue(forKey: "dayTimeZone") }
      object["records"] = records
      try writeIndex(object)
      try editArchive(.anthropic) { archive in
        archive["2026-09-01"] = ArchivedDay(tokens: 777, costUSD: 1, fetchedAt: now)
      }
      return session
    }

    func index() throws -> [String: Any] {
      try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
    }

    func writeIndex(_ object: [String: Any]) throws {
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: cache)
    }

    func archives(_ object: [String: Any]) throws -> [ProviderID: [String: ArchivedDay]] {
      let data = try JSONSerialization.data(withJSONObject: #require(object["dailyHistory"]))
      return try JSONDecoder().decode([ProviderID: [String: ArchivedDay]].self, from: data)
    }

    func archive(_ provider: ProviderID) throws -> [String: ArchivedDay] {
      try archives(index())[provider] ?? [:]
    }

    func editArchive(_ provider: ProviderID, edit: (inout [String: ArchivedDay]) -> Void) throws {
      var object = try index()
      var history = try archives(object)
      var days = history[provider] ?? [:]
      edit(&days)
      history[provider] = days
      object["dailyHistory"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(history))
      try writeIndex(object)
    }
  }
}
