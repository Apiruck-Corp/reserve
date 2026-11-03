import Darwin
import Foundation
import Testing
@testable import ReserveCore

/// Claude sign-in runs `claude auth login --claudeai`, which Claude Code
/// before 2.1.79 rejects before any browser opens (checked against the npm
/// releases 2.1.40 to 2.1.78: "error: unknown option '--claudeai'").
struct ClaudeCodeSignInTests {
  private static func versions(_ table: [String: String?]) -> @Sendable (String) async -> String? {
    { path in table[path] ?? nil }
  }

  @Test func anOldCopyAheadInTheSearchOrderIsSkipped() async {
    let selection = await ClaudeCodeHelper.select(
      candidates: ["/usr/local/bin/claude", "/Users/me/.local/bin/claude"],
      version: Self.versions([
        "/usr/local/bin/claude": "2.1.70 (Claude Code)",
        "/Users/me/.local/bin/claude": "2.1.316 (Claude Code)",
      ]))
    #expect(selection == .ready("/Users/me/.local/bin/claude"))
  }

  @Test func theFirstCopyThatIsNewEnoughWins() async {
    let selection = await ClaudeCodeHelper.select(
      candidates: ["/opt/homebrew/bin/claude", "/Users/me/.local/bin/claude"],
      version: Self.versions([
        "/opt/homebrew/bin/claude": "2.1.79 (Claude Code)",
        "/Users/me/.local/bin/claude": "2.1.316 (Claude Code)",
      ]))
    #expect(selection == .ready("/opt/homebrew/bin/claude"))
  }

  @Test func onlyOldCopiesAskForAnUpdateNamingTheNewestOne() async {
    let selection = await ClaudeCodeHelper.select(
      candidates: ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"],
      version: Self.versions([
        "/usr/local/bin/claude": "2.0.76 (Claude Code)",
        "/opt/homebrew/bin/claude": "2.1.78 (Claude Code)",
      ]))
    #expect(selection == .tooOld(path: "/opt/homebrew/bin/claude", version: "2.1.78"))
  }

  @Test func aCopyThatCannotReportItsVersionIsNotTheOneChosen() async {
    let selection = await ClaudeCodeHelper.select(
      candidates: ["/usr/local/bin/claude", "/Users/me/.local/bin/claude"],
      version: Self.versions([
        "/usr/local/bin/claude": nil,
        "/Users/me/.local/bin/claude": "2.1.316 (Claude Code)",
      ]))
    #expect(selection == .ready("/Users/me/.local/bin/claude"))
  }

  @Test func whenNoCopyReportsAVersionTheFirstIsStillTried() async {
    let selection = await ClaudeCodeHelper.select(
      candidates: ["/usr/local/bin/claude"], version: Self.versions([:]))
    #expect(selection == .ready("/usr/local/bin/claude"))
  }

  @Test func noCopyIsMissing() async {
    #expect(await ClaudeCodeHelper.select(candidates: [], version: Self.versions([:])) == .missing)
  }

  @Test func theRealVersionCommandIsRead() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-claude-version-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("claude").path
    #expect(FileManager.default.createFile(
      atPath: script, contents: Data("#!/bin/sh\necho '2.1.70 (Claude Code)'\n".utf8)))
    #expect(chmod(script, 0o755) == 0)
    let selection = await ClaudeCodeHelper.select(candidates: [script])
    #expect(selection == .tooOld(path: script, version: "2.1.70"))
  }

  // MARK: Claude desktop app's bundled Claude Code

  @Test func currentDesktopLayoutWithABuildFolderIsFound() throws {
    let home = try Self.home()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let root = "\(home)/Library/Application Support/Claude/claude-code"
    let finished = try Self.bundle(at: "\(root)/2.1.309/5af865b9901c", verified: true)
    _ = try Self.bundle(at: "\(root)/2.1.310/0000aaaa", verified: false)
    _ = try Self.bundle(at: "\(root)/2.1.308/a93ded4b1b47", verified: true)
    // 2.1.310 never finished downloading, so the newest verified build wins.
    #expect(BinaryLocator.bundledClaudeExecutable(home: home) == finished)
  }

  @Test func earlierDesktopLayoutIsStillFound() throws {
    let home = try Self.home()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let binary = try Self.bundle(
      at: "\(home)/Library/Application Support/Claude/claude-code/2.1.200", verified: false)
    #expect(BinaryLocator.bundledClaudeExecutable(home: home) == binary)
  }

  private static func home() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let canonical = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(canonical) }
    return String(cString: canonical)
  }

  private static func bundle(at folder: String, verified: Bool) throws -> String {
    let macOS = "\(folder)/claude.app/Contents/MacOS"
    try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
    let binary = "\(macOS)/claude"
    #expect(FileManager.default.createFile(atPath: binary, contents: Data("#!/bin/sh\n".utf8)))
    #expect(chmod(binary, 0o755) == 0)
    if verified {
      #expect(FileManager.default.createFile(atPath: "\(folder)/.verified", contents: Data()))
    }
    return binary
  }

  // MARK: The helper's own reason

  @Test func theHelpersErrorLineIsKept() {
    #expect(SignInOutput.failureReason(in: "error: unknown option '--claudeai'\n")
      == "error: unknown option '--claudeai'")
  }

  @Test func promptsLinksAndColoursAreLeftOut() {
    let output = """
      Opening browser to sign in…
      If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=abc
      \u{1B}[31mOAuth error: Request failed with status code 403\u{1B}[0m
      Paste code here if prompted >\u{20}
      """
    #expect(SignInOutput.failureReason(in: output) == "OAuth error: Request failed with status code 403")
  }

  @Test func outputWithOnlyThePromptHasNoReason() {
    let output = "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/x\nPaste code here if prompted > "
    #expect(SignInOutput.failureReason(in: output) == nil)
  }
}
