import Foundation
import Testing

@testable import ReserveCore

/// How each provider keeps several accounts apart, and what "Add Account…"
/// does with that.
@Suite struct AccountIsolationTests {
  private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

  @Test func everyKindDeclaresHowItsAccountsAreKeptApart() {
    #expect(ProviderDescriptor.forKind(.anthropic).homeFolderEnvironmentKey == "CLAUDE_CONFIG_DIR")
    #expect(ProviderDescriptor.forKind(.openAI).homeFolderEnvironmentKey == "CODEX_HOME")
    #expect(ProviderDescriptor.forKind(.grok).homeFolderEnvironmentKey == "GROK_HOME")
    #expect(ProviderDescriptor.forKind(.zai).accountIsolation == .apiKey)
    #expect(ProviderDescriptor.forKind(.kimi).accountIsolation == .apiKey)
    // Fixed Keychain names (Cursor, Copilot) or no home variable (Antigravity).
    for kind in [ProviderKind.cursor, .copilot, .gemini] {
      #expect(ProviderDescriptor.forKind(kind).accountIsolation == .single)
      #expect(!kind.supportsAddedAccounts)
    }
    for kind in [ProviderKind.anthropic, .openAI, .grok, .zai, .kimi] {
      #expect(kind.supportsAddedAccounts)
    }
  }

  @Test func addingConnectsTheEmptyDefaultFirstAndRefusesSingleSignIns() {
    #expect(AccountAddition.action(for: .openAI, defaultConnected: false) == .connectDefault)
    #expect(AccountAddition.action(for: .cursor, defaultConnected: false) == .connectDefault)
    #expect(AccountAddition.action(for: .openAI, defaultConnected: true) == .addAccount)
    #expect(AccountAddition.action(for: .zai, defaultConnected: true) == .addAccount)
    guard case .unavailable(let reason) = AccountAddition.action(for: .gemini, defaultConnected: true) else {
      Issue.record("Gemini offered a second account")
      return
    }
    #expect(reason.contains("one sign-in per Mac"))
    // Every kind appears once, subscriptions before key plans.
    #expect(AccountAddition.subscriptionKinds + AccountAddition.keyPlanKinds
      == [.openAI, .anthropic, .grok, .cursor, .copilot, .gemini, .zai, .kimi])
  }

  @Test func accountFoldersLiveUnderTheKindsManagedRoot() throws {
    #expect(AccountFolder.managedRoot(for: .openAI, homeDirectory: self.home)?.path == "/Users/example/.codex-accounts")
    #expect(AccountFolder.managedRoot(for: .grok, homeDirectory: self.home)?.path == "/Users/example/.grok-accounts")
    #expect(AccountFolder.managedRoot(for: .anthropic, homeDirectory: self.home)?.path == "/Users/example/.claude-accounts")
    #expect(AccountFolder.managedRoot(for: .cursor, homeDirectory: self.home) == nil)
    #expect(AccountFolder.managedRoot(for: .zai, homeDirectory: self.home) == nil)

    let folder = try #require(AccountFolder(path: "/Users/example/.codex-accounts/ab12cd34/"))
    #expect(folder.path == "/Users/example/.codex-accounts/ab12cd34")
    #expect(folder.environment(for: .openAI, from: ["PATH": "/bin"])
      == ["PATH": "/bin", "CODEX_HOME": "/Users/example/.codex-accounts/ab12cd34"])
    #expect(folder.environment(for: .cursor, from: ["PATH": "/bin"]) == ["PATH": "/bin"])
    #expect(!folder.isDefaultHome(for: .openAI, homeDirectory: self.home))
    #expect(try #require(AccountFolder(path: "/Users/example/.codex")).isDefaultHome(for: .openAI, homeDirectory: self.home))
    #expect(try #require(AccountFolder(path: "/Users/example/.grok/")).isDefaultHome(for: .grok, homeDirectory: self.home))
    #expect(AccountFolder(path: "relative") == nil)
    #expect(AccountFolder(path: "/") == nil)
  }

  @Test func aDefaultHomeReachedThroughALinkIsStillTheDefault() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reserve-account-folder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("codex-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: codexHome)
    let folder = try #require(AccountFolder(path: link.path))
    #expect(folder.isDefaultHome(for: .openAI, homeDirectory: root))
  }

  @Test func missingFolderNamesTheKindsHelper() {
    #expect(AccountFolder.missing(for: .anthropic) == AnthropicProvider.configDirectoryMissing)
    #expect(AccountFolder.missing(for: .openAI).localizedDescription.contains("Codex helper"))
  }

  @Test func readingsAreCreditedToTheAccountThatAskedForThem() throws {
    let added = try #require(ProviderID(kind: .openAI, instance: "ab12cd34"))
    let snapshot = UsageSnapshot(
      provider: .openAI, planName: "Pro",
      windows: [UsageWindow(id: "five", label: "5 hours", usedPercent: 40)], source: "Codex")
    let credited = snapshot.attributed(to: added)
    #expect(credited.provider == added)
    #expect(credited.planName == "Pro" && credited.windows == snapshot.windows && credited.source == "Codex")
    #expect(snapshot.attributed(to: .openAI) == snapshot)
  }

  @Test func keyPlanAccountsKeepTheirOwnKeychainItem() throws {
    let added = try #require(ProviderID(kind: .zai, instance: "ab12cd34"))
    #expect(PlanKeyKeychain.account(for: .zai) == "plan-key.zai")
    #expect(PlanKeyKeychain.account(for: added) == "plan-key.zai@ab12cd34")
    #expect(ZaiProvider(id: added).id == added)
    #expect(KimiProvider().id == .kimi)
  }
}
