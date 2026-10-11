import Foundation

/// The home folder of an added account whose helper keeps one sign-in per
/// folder (see `ProviderDescriptor.AccountIsolation.homeFolder`). The path is
/// normalised the way Claude's is, so the same folder is always the same
/// string: the helper receives exactly this string in its environment
/// variable, and Claude Code and Codex both name their Keychain item after it.
public struct AccountFolder: Sendable, Equatable, Hashable {
  public let path: String

  /// Fails for an empty, relative, root or oversized path.
  public init?(path input: String) {
    guard let normalized = ClaudeConfigDirectory(path: input) else { return nil }
    self.path = normalized.path
  }

  public var url: URL { URL(fileURLWithPath: self.path, isDirectory: true) }

  /// Where the path really leads once symbolic links are followed. Used only
  /// to tell folders apart; the helper always receives `path`.
  public var resolvedPath: String { ClaudeConfigDirectory.resolvedPath(of: self.url) }

  /// True when this folder is the helper's own default home, or a link to it:
  /// pointed there, the added account would sign in over the default one.
  public func isDefaultHome(
    for kind: ProviderKind,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    guard case .homeFolder(_, let folderName, _) = ProviderDescriptor.forKind(kind).accountIsolation,
      let home = AccountFolder(path: homeDirectory.appendingPathComponent(folderName).path)
    else { return false }
    return self == home || self.resolvedPath == home.resolvedPath
  }

  /// Variables that name a credential file directly and would win over the
  /// home folder, so an inherited one would put every account on one sign-in.
  static func overridingKeys(for kind: ProviderKind) -> [String] {
    kind == .grok ? ["GROK_AUTH_PATH"] : []
  }

  /// The helper's environment with its home variable pointing here, and any
  /// inherited override of the credential file removed.
  public func environment(for kind: ProviderKind, from base: [String: String]) -> [String: String] {
    var environment = base
    for key in Self.overridingKeys(for: kind) { environment.removeValue(forKey: key) }
    if let key = ProviderDescriptor.forKind(kind).homeFolderEnvironmentKey {
      environment[key] = self.path
    }
    return environment
  }

  /// Where Reserve keeps the folders of the accounts it adds for a kind, such
  /// as `~/.codex-accounts`. Hidden like the helper's own home.
  public static func managedRoot(
    for kind: ProviderKind,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL? {
    guard case .homeFolder(_, _, let managed) = ProviderDescriptor.forKind(kind).accountIsolation
    else { return nil }
    return homeDirectory.appendingPathComponent(managed, isDirectory: true)
  }

  /// The error an added account reports until its folder is chosen.
  public static func missing(for kind: ProviderKind) -> UsageProviderError {
    if kind == .anthropic { return AnthropicProvider.configDirectoryMissing }
    let helper = ProviderDescriptor.forKind(kind).helper?.displayName ?? kind.displayName
    return .credentialsNotFound("Choose this account's \(helper) folder in Settings > Providers.")
  }
}
