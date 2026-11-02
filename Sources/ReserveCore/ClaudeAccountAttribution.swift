import Foundation

/// One Claude account Reserve tracks, reduced to what deciding "whose
/// sessions are these?" needs.
public struct ClaudeAccountBinding: Sendable, Equatable {
  public let account: ProviderID
  /// The account's own Claude Code folder. Nil for the first card, which
  /// owns Claude Code's ordinary home (`~/.claude`, profile `~/.claude.json`).
  public let folder: ClaudeConfigDirectory?
  /// The hashed organization a successful limits read verified for this
  /// account, if Reserve stored one.
  public let verifiedOrganization: String?

  public init(account: ProviderID, folder: ClaudeConfigDirectory?, verifiedOrganization: String?) {
    self.account = account
    self.folder = folder
    self.verifiedOrganization = verifiedOrganization.flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// Who a Claude Code folder is signed in as, hashed. Read from the folder's
/// `.claude.json` profile only; credentials are never read for this.
public struct ClaudeFolderIdentity: Sendable, Equatable {
  public let organization: String?
  public let member: String?

  public init(organization: String?, member: String?) {
    self.organization = organization
    self.member = member
  }
}

/// A Claude Code `projects` folder whose transcripts count toward `account`.
public struct ClaudeHistorySource: Sendable, Equatable, Hashable {
  public let account: ProviderID
  public let projects: URL

  public init(account: ProviderID, projects: URL) {
    self.account = account
    self.projects = projects
  }
}

/// Decides which tracked Claude account a Claude Code folder belongs to.
///
/// Claude Code transcripts do not name the organization that paid for them,
/// but every folder is one sign-in. A folder belongs to an account when it is
/// that account's own folder, or when its profile is signed in as the same
/// person in the same organization the account is bound to. While Reserve
/// tracks several Claude accounts, the organization must be one a limits read
/// verified, so a folder that merely sits on disk cannot claim a card.
public enum ClaudeAccountAttribution {
  public struct HistoryPlan: Sendable, Equatable {
    public var sources: [ClaudeHistorySource]
    /// The first card's folder is scanned, but while several Claude accounts
    /// are tracked its sign-in could not be matched to the first card's
    /// verified organization. Its history then stays a device total.
    public var defaultHistoryUnattributed: Bool

    public init(sources: [ClaudeHistorySource], defaultHistoryUnattributed: Bool) {
      self.sources = sources
      self.defaultHistoryUnattributed = defaultHistoryUnattributed
    }
  }

  /// Bounds the home-folder discovery; a real Mac has a handful at most.
  static let maximumDiscoveredFolders = 32

  /// Claude Code keeps the default home's profile beside the folder, in
  /// `~/.claude.json`; any other folder keeps it inside.
  public static func profileURL(forFolder folder: URL, homeDirectory: URL) -> URL {
    if Self.resolved(folder) == Self.resolved(Self.defaultHome(homeDirectory)) {
      return homeDirectory.appendingPathComponent(".claude.json")
    }
    return folder.appendingPathComponent(".claude.json")
  }

  /// The hashed sign-in of a profile file, or nil when it names none.
  public static func liveIdentity(profileURL: URL) -> ClaudeFolderIdentity? {
    guard let profile = ClaudeAccountProfile.load(from: profileURL) else { return nil }
    let identity = ClaudeFolderIdentity(
      organization: profile.organizationIdentifier, member: profile.memberIdentifier)
    return identity.organization == nil ? nil : identity
  }

  /// The tracked account whose sessions `folder` holds, or nil when none can
  /// be proven. `identity` reads a profile URL; tests pass a fixture.
  /// `requiresVerifiedOrganization` defaults to "an added Claude account
  /// exists". The app passes its sticky flag instead: once a Mac has tracked
  /// two Claude accounts, the default folder may hold either one's past.
  public static func owner(
    ofFolder folder: URL,
    accounts: [ClaudeAccountBinding],
    homeDirectory: URL,
    requiresVerifiedOrganization: Bool? = nil,
    identity: (URL) -> ClaudeFolderIdentity?
  ) -> ProviderID? {
    let claude = accounts.filter(\.account.isAnthropic)
    let path = Self.resolved(folder)
    // An added account's own folder is its sign-in by construction; its
    // limits read already refuses a folder signed in elsewhere.
    if let own = claude.first(where: { $0.account.isAdded && $0.folder?.resolvedPath == path }) {
      return own.account
    }
    let first = claude.first { $0.account.isDefault }
    let isDefaultHome = path == Self.resolved(Self.defaultHome(homeDirectory))
    let homeProfile = homeDirectory.appendingPathComponent(".claude.json")
    guard requiresVerifiedOrganization ?? claude.contains(where: \.account.isAdded) else {
      // One Claude account: nothing to mix up with. Another folder still has
      // to be the same person in the same organization as the first card.
      guard let first else { return nil }
      if isDefaultHome { return first.account }
      guard let mine = identity(Self.profileURL(forFolder: folder, homeDirectory: homeDirectory)),
        let theirs = identity(homeProfile), Self.samePerson(mine, theirs)
      else { return nil }
      return first.account
    }
    guard let mine = identity(Self.profileURL(forFolder: folder, homeDirectory: homeDirectory)),
      let organization = mine.organization
    else { return nil }
    let matches = claude.filter { binding in
      let own = identity(binding.folder?.accountProfileURL ?? homeProfile)
      // The first card follows whatever Claude Code last signed in to, so
      // only an organization a limits read verified counts for it.
      let expected = binding.verifiedOrganization ?? (binding.account.isAdded ? own?.organization : nil)
      guard let expected, expected == organization else { return false }
      if let a = mine.member, let b = own?.member, a != b { return false }
      return true
    }
    // As for limits: when both cards name one organization, the added card,
    // signed in on purpose, keeps it.
    return matches.first(where: \.account.isAdded)?.account ?? matches.first?.account
  }

  /// Every Claude `projects` folder whose sessions belong to a tracked
  /// account, each counted once even when two folders lead to the same files.
  public static func historyPlan(
    accounts: [ClaudeAccountBinding],
    homeDirectory: URL,
    discovered: [URL],
    requiresVerifiedOrganization: Bool? = nil,
    identity: (URL) -> ClaudeFolderIdentity?
  ) -> HistoryPlan {
    let claude = accounts.filter(\.account.isAnthropic)
    let defaultHome = Self.defaultHome(homeDirectory)
    var folders = [defaultHome]
    folders += claude.compactMap { $0.account.isAdded ? $0.folder?.url : nil }
    folders += discovered
    var seenFolders: Set<String> = []
    var roots: [String] = []
    var plan = HistoryPlan(sources: [], defaultHistoryUnattributed: false)
    for folder in folders {
      guard seenFolders.insert(Self.resolved(folder)).inserted else { continue }
      let projects = folder.appendingPathComponent("projects", isDirectory: true)
      let root = Self.resolved(projects)
      // A folder linked to, into or around another one reaches the same
      // transcripts. The first one listed keeps them.
      guard !roots.contains(where: { Self.overlaps(root, $0) }) else { continue }
      var account = Self.owner(
        ofFolder: folder, accounts: claude, homeDirectory: homeDirectory,
        requiresVerifiedOrganization: requiresVerifiedOrganization, identity: identity)
      if account == nil, folder == defaultHome, let first = claude.first(where: \.account.isDefault) {
        // Unproven: keep counting it once, as the device total it was before.
        account = first.account
        plan.defaultHistoryUnattributed = true
      }
      guard let account else { continue }
      roots.append(root)
      plan.sources.append(ClaudeHistorySource(account: account, projects: projects))
    }
    return plan
  }

  /// Claude Code folders in the home folder (`~/.claude*`) and Reserve's
  /// managed account folders, other than the default home. A candidate needs
  /// a profile and a `projects` folder; whose it is gets decided elsewhere.
  public static func discoverFolders(
    homeDirectory: URL, fileManager: FileManager = .default
  ) -> [URL] {
    var parents: [(URL, (String) -> Bool)] = [
      (homeDirectory, { $0.hasPrefix(".claude") && $0 != ".claude" })
    ]
    if let managed = AccountFolder.managedRoot(for: .anthropic, homeDirectory: homeDirectory) {
      parents.append((managed, { !$0.hasPrefix(".") }))
    }
    var found: [URL] = []
    for (parent, accepts) in parents {
      guard let names = try? fileManager.contentsOfDirectory(atPath: parent.path) else { continue }
      for name in names.sorted() where accepts(name) {
        guard found.count < Self.maximumDiscoveredFolders else { return found }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          fileManager.fileExists(atPath: folder.appendingPathComponent(".claude.json").path),
          fileManager.fileExists(
            atPath: folder.appendingPathComponent("projects").path, isDirectory: &isDirectory),
          isDirectory.boolValue
        else { continue }
        found.append(folder)
      }
    }
    return found
  }

  /// The Claude accounts Reserve's settings describe. The status-line
  /// receiver runs as a bare command and has no store, so it reads the same
  /// keys the app writes.
  /// The app's sticky "several Claude accounts" flag, read the same way.
  public static func requiresVerifiedOrganization(defaults: UserDefaults) -> Bool {
    defaults.bool(forKey: "anthropic.historyIncludesMultipleAccounts")
  }

  public static func bindings(defaults: UserDefaults) -> [ClaudeAccountBinding] {
    var accounts = [ClaudeAccountBinding(
      account: .anthropic, folder: nil,
      verifiedOrganization: defaults.string(forKey: "anthropic.organizationIdentifier"))]
    var seen: Set<ProviderID> = [.anthropic]
    for raw in defaults.stringArray(forKey: "accounts.added") ?? [] {
      guard let account = ProviderID(rawValue: raw), account.isAnthropic, account.isAdded,
        seen.insert(account).inserted
      else { continue }
      accounts.append(ClaudeAccountBinding(
        account: account,
        folder: defaults.string(forKey: "\(raw).configDirectory").flatMap(ClaudeConfigDirectory.init(path:)),
        verifiedOrganization: defaults.string(forKey: "\(raw).organizationIdentifier")))
    }
    return accounts
  }

  static func defaultHome(_ homeDirectory: URL) -> URL {
    homeDirectory.appendingPathComponent(".claude", isDirectory: true)
  }

  static func resolved(_ url: URL) -> String {
    ClaudeConfigDirectory.resolvedPath(of: url)
  }

  private static func samePerson(_ lhs: ClaudeFolderIdentity, _ rhs: ClaudeFolderIdentity) -> Bool {
    guard let organization = lhs.organization, organization == rhs.organization else { return false }
    if let a = lhs.member, let b = rhs.member { return a == b }
    return true
  }

  static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
  }
}
