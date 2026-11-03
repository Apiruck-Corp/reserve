import Foundation

/// Which installed Claude Code can run Reserve's sign-in.
///
/// `claude auth login --claudeai` first shipped in Claude Code 2.1.79. Older
/// builds fail before any browser opens: 2.1.40 to 2.1.78 stop with
/// "unknown option '--claudeai'", and builds before 2.1.40 have no `auth`
/// command at all and take the words as a prompt. A Mac often keeps an old
/// copy next to a current one (an npm install left in `/usr/local/bin` after
/// switching to the native installer in `~/.local/bin`), and the trusted
/// search order puts the old one first. So each candidate's version is read,
/// and the first one new enough wins.
public enum ClaudeCodeHelper {
  static let minimumSignInVersion = SemanticVersion(2, 1, 79)
  public static var minimumSignInVersionText: String { Self.minimumSignInVersion.headerValue }

  public enum Selection: Equatable, Sendable {
    /// A Claude Code that supports Reserve's sign-in.
    case ready(String)
    /// Claude Code is installed, but every copy that reports a version is
    /// older than `minimumSignInVersion`. `version` is the newest one found.
    case tooOld(path: String, version: String)
    case missing
  }

  public static func select(
    candidates: [String] = BinaryLocator.candidates("claude"),
    version: @Sendable (String) async -> String? = Self.reportedVersion
  ) async -> Selection {
    guard let first = candidates.first else { return .missing }
    var newestOld: (path: String, version: SemanticVersion)?
    for candidate in candidates {
      guard let text = await version(candidate), let parsed = SemanticVersion.first(in: text)
      else { continue }
      if parsed >= Self.minimumSignInVersion { return .ready(candidate) }
      if newestOld.map({ parsed > $0.version }) ?? true { newestOld = (candidate, parsed) }
    }
    if let newestOld {
      return .tooOld(path: newestOld.path, version: newestOld.version.headerValue)
    }
    // No copy answered `--version`. Starting the first one, as before, lets
    // its own failure be reported instead of guessing that it is too old.
    return .ready(first)
  }

  /// `claude --version`, run without stdin and without Reserve's environment.
  @Sendable public static func reportedVersion(_ executable: String) async -> String? {
    let environment = BinaryLocator.environment(
      BinaryLocator.minimalChildEnvironment(keeping: ["CLAUDE_CONFIG_DIR"]),
      launching: executable)
    return try? await ProcessRunner.output(
      executable: executable, arguments: ["--version"], environment: environment,
      standardInput: FileHandle.nullDevice, timeout: .seconds(10))
  }
}
