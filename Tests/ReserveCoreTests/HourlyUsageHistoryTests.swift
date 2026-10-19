import Foundation
import Testing
@testable import ReserveCore

@Suite struct HourlyUsageHistoryTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = ISO8601DateFormatter().date(from: "2026-10-19T10:35:00Z")!
    var codex: URL { root.appendingPathComponent("codex") }
    var claude: URL { root.appendingPathComponent("claude") }
    var cache: URL { root.appendingPathComponent("hourly.json") }
    init() throws {
      for path in [codex, claude] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func scanner(zone: TimeZone = .gmt) -> LocalHourlyUsageScanner {
      LocalHourlyUsageScanner(roots: .init(codex: codex, claude: claude, grok: root), cacheURL: cache, timeZone: zone)
    }
    func write(_ text: String, to file: URL, append: Bool = false) throws {
      let data = Data(text.utf8)
      if append {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
      } else { try data.write(to: file) }
      try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
    static func claude(hour: String, input: Int, id: String = "m", model: String = "claude-sonnet-4-5") -> String {
      #"{"type":"assistant","timestamp":"2026-10-19T\#(hour):00Z","requestId":"r","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":0}}}"# + "\n"
    }
    static func codex(stamp: String, input: Int, output: Int = 0, last: Int? = nil) -> String {
      let lastField = last.map { #", "last_token_usage":{"input_tokens":\#($0),"output_tokens":0}"# } ?? ""
      return #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"output_tokens":\#(output)}\#(lastField)}}}"# + "\n"
    }
  }

  @Test func claudeCorrectionsMoveBetweenHoursAndAppendSurvivesReload() async throws {
    let f = try Fixture(); defer { f.remove() }
    let file = f.claude.appendingPathComponent("session.jsonl")
    try f.write(Fixture.claude(hour: "01:10", input: 100) + Fixture.claude(hour: "02:05", input: 150), to: file)
    let scanner = f.scanner()
    let initial = try #require(try await scanner.scan(now: f.now)[.anthropic])
    #expect(initial.hours.count == 11)
    #expect(initial.hours[1].tokens == 0)
    #expect(initial.hours[2].tokens == 150)
    #expect(initial.hours[2].costUSD != nil)
    let daily = initial.dailyUsage(timeZone: .gmt)
    #expect(daily.tokens == 150 && daily.detail?.input == 150)
    #expect(daily.detail?.models["claude-sonnet-4-5"]?.tokens == 150)
    #expect(initial.hours.last?.start == f.now.addingTimeInterval(-35 * 60))
    try f.write(Fixture.claude(hour: "03:15", input: 50, id: "next"), to: file, append: true)
    let reloaded = f.scanner()
    #expect(await reloaded.cachedHistory(now: f.now)[.anthropic] == initial)
    let updated = try #require(try await reloaded.scan(now: f.now)[.anthropic])
    #expect(updated.hours.reduce(0) { $0 + $1.tokens } == 200)
    #expect(updated.hours[3].tokens == 50)
    #expect(try await reloaded.scan(now: f.now)[.anthropic] == updated)
  }

  @Test func codexUsesDeltasIgnoresRepeatsAndHandlesInheritedCountersResetsAndModels() async throws {
    let f = try Fixture(); defer { f.remove() }
    let file = f.codex.appendingPathComponent("session.jsonl")
    let model = #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"# + "\n"
    let text = model
      + Fixture.codex(stamp: "2026-10-18T23:55:00Z", input: 1000)
      + Fixture.codex(stamp: "2026-10-19T01:10:00Z", input: 1100, output: 10)
      + Fixture.codex(stamp: "2026-10-19T02:10:00Z", input: 1100, output: 10)
      + Fixture.codex(stamp: "2026-10-19T02:15:00Z", input: 1500, output: 30)
      + Fixture.codex(stamp: "2026-10-19T03:10:00Z", input: 40, last: 40)
    try f.write(text, to: file)
    let scanner = f.scanner()
    let history = try #require(try await scanner.scan(now: f.now)[.openAI])
    #expect(history.hours[0].tokens == 0)
    #expect(history.hours[1].tokens == 110)
    #expect(history.hours[2].tokens == 420)
    #expect(history.hours[3].tokens == 40)
    #expect(history.hours.reduce(0) { $0 + $1.tokens } == 570)
    #expect(history.hours[2].costUSD != nil)
    let second = f.codex.appendingPathComponent("inherited.jsonl")
    try f.write(model + Fixture.codex(stamp: "2026-10-19T04:00:00Z", input: 50_000, last: 25), to: second)
    #expect(try await scanner.scan(now: f.now)[.openAI]?.hours[4].tokens == 25)
    let reloaded = f.scanner()
    try f.write(Fixture.codex(stamp: "2026-10-19T04:30:00Z", input: 50_000, last: 25)
      + Fixture.codex(stamp: "2026-10-19T05:00:00Z", input: 50_100, last: 100), to: second, append: true)
    #expect(try await reloaded.scan(now: f.now)[.openAI]?.hours[4].tokens == 25)
    #expect(try await reloaded.scan(now: f.now)[.openAI]?.hours[5].tokens == 100)
  }

  @Test func boundedPassesResumeAcrossLaunchesAndNeverPublishPartialTotals() async throws {
    let f = try Fixture(); defer { f.remove() }
    let file = f.claude.appendingPathComponent("session.jsonl")
    try f.write((0..<200).map { Fixture.claude(hour: "03:15", input: 10, id: "m\($0)") }.joined(), to: file)
    var scanner = f.scanner()
    await scanner.setTestingBudget(bytes: 3000)
    do { try await scanner.scan(now: f.now); Issue.record("expected a bounded pass") }
    catch UsageProviderError.timedOut { }
    #expect(await scanner.scanIncomplete)
    #expect(await scanner.cachedHistory(now: f.now).isEmpty)
    scanner = f.scanner()
    let complete = try #require(try await scanner.scan(now: f.now)[.anthropic])
    #expect(complete.hours[3].tokens == 2000)
    // A later partial pass must keep the last complete snapshot.
    try f.write((200..<400).map { Fixture.claude(hour: "04:15", input: 10, id: "m\($0)") }.joined(), to: file, append: true)
    await scanner.setTestingBudget(bytes: 3000)
    do { try await scanner.scan(now: f.now); Issue.record("expected a bounded pass") }
    catch UsageProviderError.timedOut { }
    #expect(await scanner.cachedHistory(now: f.now)[.anthropic] == complete)
    scanner = f.scanner()
    let final = try #require(try await scanner.scan(now: f.now)[.anthropic])
    #expect(final.hours[3].tokens == 2000)
    #expect(final.hours[4].tokens == 2000)
    #expect(final.hours.reduce(0) { $0 + $1.tokens } == 4000)
  }

  @Test func incompleteLinesRewriteDeletionAndMissingPricesStayHonest() async throws {
    let f = try Fixture(); defer { f.remove() }
    let file = f.claude.appendingPathComponent("session.jsonl")
    let line = Fixture.claude(hour: "01:10", input: 100, model: "unknown-model")
    try f.write(String(line.dropLast(10)), to: file)
    let scanner = f.scanner()
    #expect(try await scanner.scan(now: f.now)[.anthropic]?.hours[1].tokens == 0)
    try f.write(String(line.suffix(10)), to: file, append: true)
    let history = try #require(try await scanner.scan(now: f.now)[.anthropic])
    #expect(history.hours[1].tokens == 100)
    #expect(history.hours[1].costUSD == nil)
    #expect(history.hours[0].costUSD == 0)
    try f.write(Fixture.claude(hour: "05:10", input: 20), to: file)
    #expect(try await scanner.scan(now: f.now)[.anthropic]?.hours[1].tokens == 0)
    #expect(try await scanner.scan(now: f.now)[.anthropic]?.hours[5].tokens == 20)
    try FileManager.default.removeItem(at: file)
    #expect(try await scanner.scan(now: f.now)[.anthropic]?.hours.allSatisfy { $0.tokens == 0 } == true)
    #expect(await scanner.cachedHistory(now: f.now.addingTimeInterval(86400)).isEmpty)
  }

  @Test func nestedToolFieldsCannotChangeAssistantIdentityOrModel() async throws {
    let f = try Fixture(); defer { f.remove() }
    func line(tool: String, input: Int) -> String {
      #"{"type": "assistant", "timestamp": "2026-10-19T03:10:00Z", "requestId": "request", "message": {"content": [{"id": "\#(tool)", "type": "tool_use", "input": {"model": "fake-tool-model", "timestamp": "2000-01-01T00:00:00Z"}}], "id": "message", "model": "claude-sonnet-4-5", "usage": {"input_tokens": \#(input), "output_tokens": 0}}}"# + "\n"
    }
    try f.write(line(tool: "first-tool", input: 100) + line(tool: "second-tool", input: 200),
      to: f.claude.appendingPathComponent("session.jsonl"))
    let history = try #require(try await f.scanner().scan(now: f.now)[.anthropic])
    let day = history.dailyUsage(timeZone: .gmt)
    #expect(day.tokens == 200)
    #expect(day.detail?.models["claude-sonnet-4-5"]?.tokens == 200)
    #expect(day.detail?.models["fake-tool-model"] == nil)
    #expect(history.hours[3].tokens == 200)
  }

  @Test func laterHoursAreRetainedButNeverPlottedBeforeTheirTime() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(Fixture.claude(hour: "11:10", input: 400), to: f.claude.appendingPathComponent("session.jsonl"))
    let scanner = f.scanner()
    let first = try #require(try await scanner.scan(now: f.now)[.anthropic])
    #expect(first.hours.count == 11)
    #expect(first.hours.reduce(0) { $0 + $1.tokens } == 0)
    // A line written while a pass runs must not be discarded just because
    // its timestamp is later than the pass's original clock reading.
    let later = try #require(try await scanner.scan(now: f.now.addingTimeInterval(3600))[.anthropic])
    #expect(later.hours.count == 12)
    #expect(later.hours[11].tokens == 400)
  }

  @Test func localHourBoundariesIncludeDSTAndHalfHourTimeZones() async throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let parser = ISO8601DateFormatter()
    let spring = try #require(parser.date(from: "2026-03-09T03:59:00Z"))
    let autumn = try #require(parser.date(from: "2026-11-02T04:59:00Z"))
    #expect(HourlyUsageHistory.hourStarts(now: spring, timeZone: zone).count == 23)
    let repeated = HourlyUsageHistory.hourStarts(now: autumn, timeZone: zone)
    #expect(repeated.count == 25)
    #expect(Set(repeated).count == 25)
    let f = try Fixture(); defer { f.remove() }
    let india = try #require(TimeZone(identifier: "Asia/Kolkata"))
    try f.write(Fixture.claude(hour: "00:10", input: 100) + Fixture.claude(hour: "00:40", input: 200, id: "next"),
      to: f.claude.appendingPathComponent("session.jsonl"))
    let result = try #require(try await f.scanner(zone: india).scan(now: f.now)[.anthropic])
    #expect(result.hours[5].tokens == 100) // 05:40 local
    #expect(result.hours[6].tokens == 200) // 06:10 local
    #expect(result.hours.reduce(0) { $0 + $1.tokens } == 300)
    // Account-only and aggregate-only sources never acquire invented hours.
    #expect(try await f.scanner().scan(now: f.now)[.grok] == nil)
  }
}
