import Foundation
import Testing
@testable import ReserveCore

/// Issue #83: Cursor sign-in opened an "incomplete or expired" link, and the
/// status check failed on Cursor CLIs that predate `status --format`.
struct CursorSignInTests {
  private let hosts: Set<String> = ["cursor.com", "auth.cursor.com", "www.cursor.com"]
  private let challenge = "Q2hhbGxlbmdlLXRlc3QtdmFsdWUtNDMtY2hhcnMtX0A"
  private let uuid = "123e4567-e89b-12d3-a456-426614174000"

  private var link: String {
    "https://cursor.com/loginDeepControl?challenge=\(challenge)&uuid=\(uuid)"
      + "&mode=login&redirectTarget=cli&supportsSelectedTeamLogin=true"
  }

  private var printed: String {
    "Starting login process...\nWaiting for browser authentication...\n"
      + "Open a browser and navigate to this link: \(link)\n"
  }

  /// Hard-wraps every line at `width` columns, as a terminal renderer does
  /// with a long word when it writes to a pipe.
  private func wrapped(_ text: String, width: Int) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      var pieces: [Substring] = []
      var rest = Substring(line)
      while rest.count > width {
        pieces.append(rest.prefix(width))
        rest = rest.dropFirst(width)
      }
      pieces.append(rest)
      return pieces.joined(separator: "\n")
    }.joined(separator: "\n")
  }

  @Test func challengeFixtureHasPKCELength() {
    #expect(challenge.count == 43)
  }

  @Test func completeLinkKeepsEveryQueryParameter() throws {
    let url = try #require(CursorLoginLink.url(in: printed, trustedHosts: hosts))
    #expect(url.absoluteString == link)
  }

  @Test func linkWrappedAcrossLinesIsJoined() throws {
    for width in [40, 60, 80, 100] {
      let url = try #require(
        CursorLoginLink.url(in: wrapped(printed, width: width), trustedHosts: hosts),
        "width \(width)")
      #expect(url.absoluteString == link, "width \(width)")
    }
  }

  @Test func wrappedLinkInsideABoxIsJoined() throws {
    let output = wrapped(printed, width: 76)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "│ \($0.padding(toLength: 76, withPad: " ", startingAt: 0)) │" }
      .joined(separator: "\n") + "\n"
    let url = try #require(CursorLoginLink.url(in: output, trustedHosts: hosts))
    #expect(url.absoluteString == link)
  }

  @Test func partialReadIsNotOpenedUntilTheLinkIsComplete() throws {
    // Every prefix of the output, as a pipe could deliver it, yields either
    // nothing or the whole link: never a fragment.
    let output = wrapped(printed, width: 80)
    var opened: URL?
    for end in output.indices {
      if let url = CursorLoginLink.url(in: String(output[..<end]), trustedHosts: hosts) {
        #expect(url.absoluteString == link)
        opened = url
        break
      }
    }
    if opened == nil {
      opened = CursorLoginLink.url(in: output, trustedHosts: hosts)
    }
    #expect(opened?.absoluteString == link)
  }

  @Test func linkAtTheEndOfTheOutputWaitsForMore() {
    let partial = "Open a browser and navigate to this link: \(link)"
    #expect(CursorLoginLink.url(in: partial, trustedHosts: hosts) == nil)
    #expect(CursorLoginLink.url(in: partial + "\n", trustedHosts: hosts)?.absoluteString == link)
  }

  @Test func truncatedLinksAreRejected() {
    let truncated = [
      "https://cursor.com/loginDeepControl?challenge=\(challenge.prefix(20))\n",
      "https://cursor.com/loginDeepControl?challenge=\(challenge)&uuid=\(uuid.prefix(20))\n",
      "https://cursor.com/loginDeepControl?challenge=\(challenge)\n",
      "https://cursor.com/loginDeep\n",
    ]
    for output in truncated {
      #expect(CursorLoginLink.url(in: output, trustedHosts: hosts) == nil, "\(output)")
    }
  }

  @Test func untrustedHostsAreRejected() {
    let query = "?challenge=\(challenge)&uuid=\(uuid)&mode=login&redirectTarget=cli\n"
    for host in ["cursor.com.example.org", "example.org", "evilcursor.com"] {
      #expect(
        CursorLoginLink.url(in: "https://\(host)/loginDeepControl\(query)", trustedHosts: hosts)
          == nil, "\(host)")
    }
    #expect(
      CursorLoginLink.url(in: "http://cursor.com/loginDeepControl\(query)", trustedHosts: hosts)
        == nil)
  }

  @Test func terminalColoursAndHyperlinksAreIgnored() throws {
    let coloured = "\u{1B}[1mOpen a browser and navigate to this link:\u{1B}[0m "
      + "\u{1B}]8;;\(link)\u{07}\u{1B}[36m\(link)\u{1B}[39m\u{1B}]8;;\u{07}\n"
    let url = try #require(CursorLoginLink.url(in: coloured, trustedHosts: hosts))
    #expect(url.absoluteString == link)
  }

  @Test func linkPrintedWithoutSchemeIsOpenedOverHTTPS() throws {
    let bare = String(link.dropFirst("https://".count))
    let url = try #require(
      CursorLoginLink.url(in: "Go to: \(bare)\nWaiting for authorization...\n", trustedHosts: hosts))
    #expect(url.absoluteString == link)
  }

  // MARK: - Status check

  private actor Calls {
    var arguments: [[String]] = []
    func record(_ value: [String]) { self.arguments.append(value) }
  }

  @Test func currentCLIUsesJSONStatusOnly() async throws {
    let calls = Calls()
    try await CursorProvider.checkStatus(executable: "/usr/bin/true", environment: [:]) {
      _, arguments, _ in
      await calls.record(arguments)
      return #"{"status":"authenticated","isAuthenticated":true,"hasAccessToken":true}"#
    }
    #expect(await calls.arguments == [["status", "--format", "json"]])
  }

  @Test func olderCLIWithoutFormatOptionFallsBackToTextStatus() async throws {
    let calls = Calls()
    try await CursorProvider.checkStatus(executable: "/usr/bin/true", environment: [:]) {
      _, arguments, _ in
      await calls.record(arguments)
      if arguments.contains("--format") {
        // cursor-agent 2026.01.23: "error: unknown option '--format'"
        throw UsageProviderError.processFailed("cursor-agent exited with status 1.")
      }
      return "\u{1B}[32m✓\u{1B}[0m Logged in as person@example.com"
    }
    #expect(await calls.arguments == [["status", "--format", "json"], ["status"]])
  }

  @Test func olderCLISignedOutAsksForSignIn() async {
    await #expect(throws: UsageProviderError.self) {
      try await CursorProvider.checkStatus(executable: "/usr/bin/true", environment: [:]) {
        _, arguments, _ in
        if arguments.contains("--format") {
          throw UsageProviderError.processFailed("cursor-agent exited with status 1.")
        }
        return "Not logged in"
      }
    }
    do {
      try CursorProvider.validateStatusText("Not logged in")
      Issue.record("signed-out text status was accepted")
    } catch let error as UsageProviderError {
      #expect(error.requiresConnection)
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func textStatusIsStrict() {
    for invalid in ["", "signed in", "Logged in", "✗ Not logged in as anyone",
      "Logged in as person@example.com\nNot logged in"]
    {
      #expect(throws: UsageProviderError.self, "\(invalid)") {
        try CursorProvider.validateStatusText(invalid)
      }
    }
    #expect(throws: Never.self) {
      try CursorProvider.validateStatusText("✓ Logged in as person@example.com")
    }
  }

  @Test func timeoutIsNotRetriedAsAnOlderCLI() async {
    let calls = Calls()
    await #expect(throws: UsageProviderError.timedOut("cursor-agent")) {
      try await CursorProvider.checkStatus(executable: "/usr/bin/true", environment: [:]) {
        _, arguments, _ in
        await calls.record(arguments)
        throw UsageProviderError.timedOut("cursor-agent")
      }
    }
    #expect(await calls.arguments.count == 1)
  }
}
