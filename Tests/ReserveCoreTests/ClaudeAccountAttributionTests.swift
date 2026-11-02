import Foundation
import Testing
@testable import ReserveCore

/// Claude history and status-line readings belong to the account whose
/// folder produced them: PO's personal Max in `~/.claude`, the Nimbus Team
/// seat in Reserve's managed folder and in T3 Code's `~/.claude_nimbus_team`.
@Suite struct ClaudeAccountAttributionTests {
  private static let team = ProviderID(rawValue: "anthropic@56148cb5")!
  private static let personalOrg = StableIdentifier.notificationComponent("org-personal")
  private static let teamOrg = StableIdentifier.notificationComponent("org-team")

  private struct Fixture {
    let root: URL
    let now = ISO8601DateFormatter().date(from: "2026-10-19T10:35:00Z")!
    var home: URL { self.root.appendingPathComponent("home", isDirectory: true) }
    var defaultHome: URL { self.home.appendingPathComponent(".claude", isDirectory: true) }
    var managed: URL { self.home.appendingPathComponent(".claude-accounts/56148cb5", isDirectory: true) }
    var t3: URL { self.home.appendingPathComponent(".claude_nimbus_team", isDirectory: true) }
    var colleague: URL { self.home.appendingPathComponent(".claude_colleague", isDirectory: true) }
    var codex: URL { self.root.appendingPathComponent("codex", isDirectory: true) }

    init() throws {
      self.root = FileManager.default.temporaryDirectory
        .appendingPathComponent("reserve-attribution-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
      for folder in [self.defaultHome, self.managed, self.t3, self.colleague] {
        try FileManager.default.createDirectory(
          at: folder.appendingPathComponent("projects/p", isDirectory: true), withIntermediateDirectories: true)
      }
      try FileManager.default.createDirectory(at: self.codex, withIntermediateDirectories: true)
      try Self.profile(self.home.appendingPathComponent(".claude.json"), "org-personal", "po")
      try Self.profile(self.managed.appendingPathComponent(".claude.json"), "org-team", "po")
      try Self.profile(self.t3.appendingPathComponent(".claude.json"), "org-team", "po")
      try Self.profile(self.colleague.appendingPathComponent(".claude.json"), "org-team", "colleague")
    }

    func remove() { try? FileManager.default.removeItem(at: self.root) }

    static func profile(_ url: URL, _ organization: String, _ member: String) throws {
      let json = #"{"oauthAccount":{"organizationUuid":"\#(organization)","accountUuid":"\#(member)"}}"#
      try Data(json.utf8).write(to: url)
    }

    var bindings: [ClaudeAccountBinding] {
      [
        ClaudeAccountBinding(account: .anthropic, folder: nil, verifiedOrganization: personalOrg),
        ClaudeAccountBinding(
          account: team, folder: ClaudeConfigDirectory(path: self.managed.path), verifiedOrganization: teamOrg),
      ]
    }

    func session(_ folder: URL, name: String = "s.jsonl", input: Int, id: String = "m") throws {
      let line = #"{"timestamp":"2026-10-19T10:00:00Z","type":"assistant","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"claude-opus-5","usage":{"input_tokens":\#(input),"output_tokens":0}}}"# + "\n"
      let file = folder.appendingPathComponent("projects/p/\(name)")
      try Data(line.utf8).write(to: file)
      try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: file.path)
    }

    func projects(_ folder: URL) -> URL { folder.appendingPathComponent("projects", isDirectory: true) }

    func scanner() -> LocalUsageScanner {
      LocalUsageScanner(
        roots: .init(codex: self.codex, claude: self.projects(self.defaultHome), grok: self.root),
        cacheURL: self.root.appendingPathComponent("index.json"), timeZone: .gmt)
    }

    func plan(requiresVerifiedOrganization: Bool? = nil, bindings: [ClaudeAccountBinding]? = nil)
      -> ClaudeAccountAttribution.HistoryPlan
    {
      ClaudeAccountAttribution.historyPlan(
        accounts: bindings ?? self.bindings, homeDirectory: self.home,
        discovered: ClaudeAccountAttribution.discoverFolders(homeDirectory: self.home),
        requiresVerifiedOrganization: requiresVerifiedOrganization,
        identity: { ClaudeAccountAttribution.liveIdentity(profileURL: $0) })
    }
  }

  private func accounts(_ plan: ClaudeAccountAttribution.HistoryPlan, _ folder: URL) -> [ProviderID] {
    let target = ClaudeConfigDirectory.resolvedPath(of: folder.appendingPathComponent("projects"))
    return plan.sources.filter { ClaudeConfigDirectory.resolvedPath(of: $0.projects) == target }.map(\.account)
  }

  @Test func eachFolderCountsTowardTheAccountItIsSignedInAs() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let plan = fixture.plan()
    #expect(!plan.defaultHistoryUnattributed)
    #expect(self.accounts(plan, fixture.defaultHome) == [.anthropic])
    #expect(self.accounts(plan, fixture.managed) == [Self.team])
    #expect(self.accounts(plan, fixture.t3) == [Self.team])
    // Same Team organization, another person's seat: not PO's quota.
    #expect(self.accounts(plan, fixture.colleague).isEmpty)
  }

  @Test func firstCardNeedsItsVerifiedOrganizationWhileSeveralAccountsAreTracked() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    // ~/.claude signed in to the Team seat today proves nothing about the
    // transcripts already there: never moved to Team, kept as a device total.
    try Fixture.profile(fixture.home.appendingPathComponent(".claude.json"), "org-team", "po")
    let switched = fixture.plan()
    #expect(self.accounts(switched, fixture.defaultHome) == [.anthropic] && switched.defaultHistoryUnattributed)
    // Its status line does belong to Team: that reading is Team's quota.
    #expect(ClaudeStatuslineBridge.routedCacheURL(
      requested: fixture.root.appendingPathComponent("claude-statusline.json"), environment: [:],
      accounts: fixture.bindings, homeDirectory: fixture.home)?.lastPathComponent
      == "claude-statusline-anthropic-56148cb5.json")

    // Signed in somewhere no card verified: kept once, as a device total.
    try Fixture.profile(fixture.home.appendingPathComponent(".claude.json"), "org-elsewhere", "po")
    let unproven = fixture.plan()
    #expect(unproven.defaultHistoryUnattributed)
    #expect(self.accounts(unproven, fixture.defaultHome) == [.anthropic])

    // No verified organization yet for the first card: same.
    try Fixture.profile(fixture.home.appendingPathComponent(".claude.json"), "org-personal", "po")
    let unverified = [ClaudeAccountBinding(account: .anthropic, folder: nil, verifiedOrganization: nil)]
      + fixture.bindings.dropFirst()
    #expect(fixture.plan(bindings: unverified).defaultHistoryUnattributed)
    // The sticky flag keeps that rule after the second account is removed.
    let alone = [ClaudeAccountBinding(account: .anthropic, folder: nil, verifiedOrganization: nil)]
    #expect(fixture.plan(requiresVerifiedOrganization: true, bindings: alone).defaultHistoryUnattributed)
    #expect(!fixture.plan(requiresVerifiedOrganization: false, bindings: alone).defaultHistoryUnattributed)
  }

  @Test func oneAccountOnlyClaimsFoldersOfTheSamePerson() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let alone = [ClaudeAccountBinding(account: .anthropic, folder: nil, verifiedOrganization: nil)]
    let plan = fixture.plan(bindings: alone)
    #expect(self.accounts(plan, fixture.defaultHome) == [.anthropic])
    #expect(self.accounts(plan, fixture.t3).isEmpty)
    #expect(self.accounts(plan, fixture.managed).isEmpty)
  }

  @Test func foldersReachingTheSameTranscriptsCountOnce() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let manager = FileManager.default
    // A link to the T3 folder, and a folder whose projects is a link into it.
    try manager.createSymbolicLink(
      at: fixture.home.appendingPathComponent(".claude_alias"), withDestinationURL: fixture.t3)
    let nested = fixture.home.appendingPathComponent(".claude_nested", isDirectory: true)
    try manager.createDirectory(at: nested, withIntermediateDirectories: true)
    try Fixture.profile(nested.appendingPathComponent(".claude.json"), "org-team", "po")
    try manager.createSymbolicLink(
      at: nested.appendingPathComponent("projects"),
      withDestinationURL: fixture.t3.appendingPathComponent("projects/p"))
    let plan = fixture.plan()
    let roots = plan.sources.map { ClaudeConfigDirectory.resolvedPath(of: $0.projects) }
    #expect(Set(roots).count == roots.count)
    #expect(!roots.contains { $0.hasPrefix(ClaudeConfigDirectory.resolvedPath(of: fixture.t3) + "/projects/") })
  }

  @Test func historyIsSplitPerAccountAndKeepsWhatWasRecorded() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.session(fixture.defaultHome, input: 100, id: "personal")
    try fixture.session(fixture.t3, input: 7, id: "t3")
    try fixture.session(fixture.managed, input: 5, id: "managed")
    try fixture.session(fixture.colleague, input: 1_000, id: "colleague")
    let scanner = fixture.scanner()

    // Before any folder list: the default folder only, as before.
    let before = try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(before[.anthropic]?.inputTokens == 100)
    #expect(before[Self.team] == nil)

    await scanner.setClaudeSources(fixture.plan().sources)
    let split = try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(split[.anthropic]?.inputTokens == 100)
    #expect(split[Self.team]?.inputTokens == 12)
    let cached = try await scanner.cachedUsage(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(cached[.anthropic]?.inputTokens == 100 && cached[Self.team]?.inputTokens == 12)
    let history = await scanner.cachedHistory(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(history[.anthropic]?.days.map(\.tokens) == [100])
    #expect(history[Self.team]?.days.map(\.tokens) == [12])
    #expect(history[Self.team]?.days.first?.detail?.input == 12)

    // A folder that stops counting keeps its records; it is not counted
    // twice when it comes back, and the first card never absorbs it.
    await scanner.setClaudeSources([ClaudeHistorySource(account: .anthropic, projects: fixture.projects(fixture.defaultHome))])
    let alone = try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(alone[.anthropic]?.inputTokens == 100 && alone[Self.team] == nil)
    await scanner.setClaudeSources(fixture.plan().sources)
    let back = try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(back[.anthropic]?.inputTokens == 100 && back[Self.team]?.inputTokens == 12)

    // The recorded day outlives its transcript, also after a reload.
    try FileManager.default.removeItem(at: fixture.t3.appendingPathComponent("projects/p/s.jsonl"))
    _ = try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])
    let reloaded = fixture.scanner()
    await reloaded.setClaudeSources(fixture.plan().sources)
    let kept = await reloaded.cachedHistory(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(kept[Self.team]?.days.map(\.tokens) == [12])
    #expect(kept[.anthropic]?.days.map(\.tokens) == [100])
  }

  @Test func addedClaudeAccountsReachInsights() {
    #expect(ProviderDescriptor.forProvider(Self.team).capabilities.contains(.localHistory))
    let codex = ProviderID(kind: .openAI, instance: "aaaa1111")!
    #expect(!ProviderDescriptor.forProvider(codex).capabilities.contains(.localHistory))
  }

  @Test func hourlyHistoryDropsAnAccountThatLostItsFolders() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.session(fixture.t3, input: 7, id: "t3")
    let scanner = LocalHourlyUsageScanner(
      roots: .init(codex: fixture.codex, claude: fixture.projects(fixture.defaultHome), grok: fixture.root),
      cacheURL: fixture.root.appendingPathComponent("hourly.json"), timeZone: .gmt)
    await scanner.setClaudeSources(fixture.plan().sources)
    #expect(try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])[Self.team] != nil)
    await scanner.setClaudeSources([ClaudeHistorySource(account: .anthropic, projects: fixture.projects(fixture.defaultHome))])
    let after = try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(after[Self.team] == nil)
    #expect(after[.anthropic]?.dailyUsage(timeZone: .gmt).tokens == 0)
  }

  @Test func hourlyHistoryIsSplitPerAccount() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.session(fixture.defaultHome, input: 100, id: "personal")
    try fixture.session(fixture.t3, input: 7, id: "t3")
    let scanner = LocalHourlyUsageScanner(
      roots: .init(codex: fixture.codex, claude: fixture.projects(fixture.defaultHome), grok: fixture.root),
      cacheURL: fixture.root.appendingPathComponent("hourly.json"), timeZone: .gmt)
    await scanner.setClaudeSources(fixture.plan().sources)
    let hours = try await scanner.scan(now: fixture.now, providers: [.anthropic, Self.team])
    #expect(hours[.anthropic]?.dailyUsage(timeZone: .gmt).tokens == 100)
    #expect(hours[Self.team]?.dailyUsage(timeZone: .gmt).tokens == 7)
  }

  @Test func statusLineReadingsGoToTheSessionsAccount() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let requested = fixture.root.appendingPathComponent("caches/claude-statusline.json")
    func route(_ environment: [String: String], _ bindings: [ClaudeAccountBinding]? = nil) -> String? {
      ClaudeStatuslineBridge.routedCacheURL(
        requested: requested, environment: environment, accounts: bindings ?? fixture.bindings,
        homeDirectory: fixture.home)?.lastPathComponent
    }
    // Existing installs: a plain Claude Code session still writes the default cache.
    #expect(route([:]) == "claude-statusline.json")
    // T3 Code's Nimbus folder shares the settings file, so the same command;
    // its reading goes to the Team card, never the personal one.
    #expect(route(["CLAUDE_CONFIG_DIR": fixture.t3.path]) == "claude-statusline-anthropic-56148cb5.json")
    #expect(route(["CLAUDE_CONFIG_DIR": fixture.managed.path]) == "claude-statusline-anthropic-56148cb5.json")
    #expect(route(["CLAUDE_CONFIG_DIR": fixture.colleague.path]) == nil)
    // With one account, another organization's session is dropped, not
    // written over the only card.
    let alone = [ClaudeAccountBinding(account: .anthropic, folder: nil, verifiedOrganization: nil)]
    #expect(route([:], alone) == "claude-statusline.json")
    #expect(route(["CLAUDE_CONFIG_DIR": fixture.t3.path], alone) == nil)
    #expect(ClaudeStatuslineBridge.routedCacheURL(
      requested: requested, environment: [:], accounts: fixture.bindings, homeDirectory: fixture.home)?
      .deletingLastPathComponent() == requested.deletingLastPathComponent())
  }

  @Test func bindingsAreReadFromReserveSettings() throws {
    let suite = "reserve-attribution-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["anthropic@56148cb5", "openai@aaaa1111"], forKey: "accounts.added")
    defaults.set("/tmp/nimbus", forKey: "anthropic@56148cb5.configDirectory")
    defaults.set(Self.teamOrg, forKey: "anthropic@56148cb5.organizationIdentifier")
    defaults.set(Self.personalOrg, forKey: "anthropic.organizationIdentifier")
    let bindings = ClaudeAccountAttribution.bindings(defaults: defaults)
    #expect(bindings.map(\.account) == [.anthropic, Self.team])
    #expect(bindings[0].verifiedOrganization == Self.personalOrg && bindings[0].folder == nil)
    #expect(bindings[1].folder?.path == "/tmp/nimbus" && bindings[1].verifiedOrganization == Self.teamOrg)
  }
}
