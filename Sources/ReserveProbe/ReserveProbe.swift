import Darwin
import Foundation
import ReserveCore

@main
struct ReserveProbe {
  static func main() async {
    let appDefaults = UserDefaults(suiteName: "com.pocarles.reserve")
    let allowClaudeKeychainRead =
      appDefaults?.bool(forKey: "anthropic.keychainReadAllowed") ?? false
    let allowCursorKeychainRead =
      appDefaults?.bool(forKey: "cursor.keychainReadAllowed") ?? false
    let arguments = Array(CommandLine.arguments.dropFirst())
    let includeInsights = arguments.contains("--insights")
    let argument = arguments.first(where: { !$0.hasPrefix("--") })
    if argument?.lowercased() == "local" {
      await self.printLocalUsage()
      return
    }
    if argument?.lowercased() == "claude-history" {
      await self.printClaudeHistory()
      return
    }
    let selected: [ProviderID]
    switch argument?.lowercased() {
    case "openai": selected = [.openAI]
    case "anthropic", "claude": selected = [.anthropic]
    // An added Claude account, read from the folder named by --claude-config-dir.
    case "anthropic2", "claude2": selected = [ProviderID(kind: .anthropic, instance: "probe")!]
    case "grok": selected = [.grok]
    case "cursor": selected = [.cursor]
    case "copilot": selected = [.copilot]
    case "zai", "z.ai": selected = [.zai]
    case "kimi": selected = [.kimi]
    case "gemini", "agy", "antigravity": selected = [.gemini]
    case nil, "all":
      // Key-connected plans are probed only when a key is saved, so "all"
      // does not report an unconfigured plan as a failure.
      selected = ProviderID.defaults.filter {
        !ProviderDescriptor.forProvider($0).usesAPIKey || PlanKeyKeychain.hasKey(for: $0)
      }
    default:
      FileHandle.standardError.write(
        Data("Usage: reserve-probe [openai|anthropic|claude2|grok|cursor|copilot|zai|kimi|gemini|local|all] [--insights] [--claude-config-dir=PATH]\n".utf8))
      exit(64)
    }

    var snapshots: [UsageSnapshot] = []
    var failures: [String: String] = [:]
    for provider in selected {
      let fetcher: any UsageProvider =
        switch provider.kind {
        case .openAI: OpenAIProvider(includeAccountActivity: includeInsights)
        case .anthropic:
          AnthropicProvider(
            id: provider,
            configDirectory: provider.isAdded
              ? arguments.first(where: { $0.hasPrefix("--claude-config-dir=") })
                .map { String($0.dropFirst("--claude-config-dir=".count)) }
                .flatMap(ClaudeConfigDirectory.init(path:))
              : nil,
            allowKeychainRead: allowClaudeKeychainRead)
        case .grok: GrokProvider()
        case .cursor: CursorProvider(allowKeychainRead: allowCursorKeychainRead, includeAccountUsage: includeInsights)
        case .copilot: CopilotProvider()
        case .zai: ZaiProvider()
        case .kimi: KimiProvider()
        case .gemini: GeminiProvider()
        }
      do {
        snapshots.append(try await fetcher.fetch())
      } catch {
        failures[provider.rawValue] = error.localizedDescription
      }
    }

    let output = ProbeOutput(snapshots: snapshots, failures: failures)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(output)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    if !failures.isEmpty { exit(1) }
  }

  private static func printLocalUsage() async {
    do {
      let summaries = try await LocalUsageScanner().scan(periodDays: 30)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let values = summaries.keys.sorted().compactMap { summaries[$0] }
      FileHandle.standardOutput.write(try encoder.encode(values))
      FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
      FileHandle.standardError.write(Data("Local usage scan failed: \(error)\n".utf8))
      exit(1)
    }
  }
}

extension ReserveProbe {
  /// Which Claude folders count toward which account on this Mac, and each
  /// account's local tokens for the last 30 days. Scans into a throwaway index
  /// so the app's own history is never touched. Prints home-relative folders
  /// and account labels only: no emails, organization ids or credentials.
  fileprivate static func printClaudeHistory() async {
    let appDefaults = UserDefaults(suiteName: "com.pocarles.reserve") ?? .standard
    let home = FileManager.default.homeDirectoryForCurrentUser
    let accounts = ClaudeAccountAttribution.bindings(defaults: appDefaults)
    let plan = ClaudeAccountAttribution.historyPlan(
      accounts: accounts, homeDirectory: home,
      discovered: ClaudeAccountAttribution.discoverFolders(homeDirectory: home),
      requiresVerifiedOrganization: ClaudeAccountAttribution.requiresVerifiedOrganization(defaults: appDefaults),
      identity: { ClaudeAccountAttribution.liveIdentity(profileURL: $0) })
    func name(_ account: ProviderID) -> String {
      "\(appDefaults.string(forKey: "\(account.rawValue).label") ?? "unnamed") (\(account.rawValue))"
    }
    func short(_ url: URL) -> String {
      url.path.hasPrefix(home.path + "/") ? "~/" + url.path.dropFirst(home.path.count + 1) : url.lastPathComponent
    }
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-claude-history-probe-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let now = Date()
    func scan(_ sources: [ClaudeHistorySource]) async throws -> [ProviderID: LocalUsageSummary] {
      let scanner = LocalUsageScanner(cacheURL: scratch.appendingPathComponent("\(UUID().uuidString).json"))
      await scanner.setClaudeSources(sources)
      for _ in 0..<200 {
        do {
          return try await scanner.scan(periodDays: 30, now: now, providers: Set(accounts.map(\.account)))
        } catch UsageProviderError.timedOut {
          guard await scanner.scanIncomplete else { throw UsageProviderError.timedOut("probe scan") }
        }
      }
      throw UsageProviderError.timedOut("probe scan did not finish")
    }
    print("Claude folders that count (first card's home unattributed: \(plan.defaultHistoryUnattributed))")
    do {
      for source in plan.sources {
        let alone = try await scan([source])[source.account]
        print("  \(short(source.projects)) -> \(name(source.account)): \(alone?.totalTokens ?? 0) tokens, input \(alone?.inputTokens ?? 0), output \(alone?.outputTokens ?? 0) (30 days, this folder alone)")
      }
      let split = try await scan(plan.sources)
      print("Per account, all its folders together (30 days)")
      for account in accounts.map(\.account) {
        let usage = split[account]
        print("  \(name(account)): \(usage?.totalTokens ?? 0) tokens, today \(usage?.todayTokens ?? 0), input \(usage?.inputTokens ?? 0), output \(usage?.outputTokens ?? 0)")
      }
    } catch {
      FileHandle.standardError.write(Data("Claude history probe failed: \(error)\n".utf8))
      exit(1)
    }
    print("Status line routing (no reading is written)")
    let requested = ClaudeStatuslineBridge.cacheURL(provider: .anthropic)
    var sessions: [(String, [String: String])] = [("plain `claude`", [:])]
    for source in plan.sources where source.account.isAdded || !short(source.projects).hasPrefix("~/.claude/") {
      let folder = source.projects.deletingLastPathComponent()
      sessions.append(("CLAUDE_CONFIG_DIR=\(short(folder))", ["CLAUDE_CONFIG_DIR": folder.path]))
    }
    for (label, environment) in sessions {
      let routed = ClaudeStatuslineBridge.routedCacheURL(
        requested: requested, environment: environment, accounts: accounts,
        requiresVerifiedOrganization: ClaudeAccountAttribution.requiresVerifiedOrganization(defaults: appDefaults))
      print("  \(label) -> \(routed?.lastPathComponent ?? "dropped")")
    }
  }
}

private struct ProbeOutput: Encodable {
  let snapshots: [UsageSnapshot]
  let failures: [String: String]
}
