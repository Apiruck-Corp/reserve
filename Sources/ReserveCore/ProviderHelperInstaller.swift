import Foundation

public struct ProviderHelperDefinition: Sendable, Equatable {
  public let provider: ProviderID
  public let executable: String
  public let displayName: String
  public let installerURL: URL
  public let updateArguments: [String]

  public init(
    provider: ProviderID,
    executable: String,
    displayName: String,
    installerURL: URL,
    updateArguments: [String]
  ) {
    self.provider = provider
    self.executable = executable
    self.displayName = displayName
    self.installerURL = installerURL
    self.updateArguments = updateArguments
  }
}

public enum ProviderHelperCatalog {
  /// Nil for providers connected with an API key, which have no helper.
  public static func definition(for provider: ProviderID) -> ProviderHelperDefinition? {
    ProviderDescriptor.forProvider(provider).helper
  }
}

public enum ProviderHelperInstallerError: LocalizedError, Sendable, Equatable {
  case invalidResponse(String)
  case installFailed(String)
  case helperNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let message): message
    case .installFailed(let message): message
    case .helperNotFound(let name):
      "\(name) could not be found after setup finished."
    }
  }
}

/// Installs only the fixed, official provider helpers that Reserve knows
/// how to use. The remote script is downloaded first, bounded and checked as a
/// shell script, then run from a private temporary directory. It never receives
/// the app's environment, which may contain unrelated API keys.
public final class ProviderHelperInstaller: @unchecked Sendable {
  static let maximumInstallerBytes = 1_048_576

  private let session: URLSession

  public init(session: URLSession? = nil) {
    self.session = session ?? ProviderHTTPSession.make(requestTimeout: 30, resourceTimeout: 60)
  }

  public func install(_ provider: ProviderID) async throws {
    guard ProviderDescriptor.forProvider(provider).supportsAutomaticHelperInstallation,
      let definition = ProviderHelperCatalog.definition(for: provider)
    else {
      throw ProviderHelperInstallerError.installFailed("Install \(provider.displayName) from its official download page, then return to Reserve.")
    }
    var request = URLRequest(url: definition.installerURL)
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("text/plain, text/x-shellscript, */*", forHTTPHeaderField: "Accept")

    let (data, response) = try await ProviderHTTPSession.boundedData(
      for: request, using: self.session, maximumBytes: Self.maximumInstallerBytes)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let host = definition.installerURL.host ?? "the provider"
      throw ProviderHelperInstallerError.invalidResponse(
        "\(definition.displayName) could not be downloaded from \(host).")
    }
    guard response.url?.scheme?.lowercased() == "https",
      response.url?.host?.lowercased() == definition.installerURL.host?.lowercased()
    else {
      throw ProviderHelperInstallerError.invalidResponse(
        "\(definition.displayName) download left the provider's official address.")
    }
    try Self.validateInstallerFormat(data)

    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("reserve-provider-setup-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? fileManager.removeItem(at: directory) }

    let script = directory.appendingPathComponent("install.sh")
    try data.write(to: script, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path)

    do {
      _ = try await ProcessRunner.output(
        executable: "/bin/bash",
        arguments: ["--noprofile", "--norc", script.path],
        environment: Self.installerEnvironment(),
        timeout: .seconds(180))
    } catch {
      throw ProviderHelperInstallerError.installFailed(
        "\(definition.displayName) setup did not finish. \(error.localizedDescription)")
    }
    guard BinaryLocator.find(definition.executable) != nil else {
      throw ProviderHelperInstallerError.helperNotFound(definition.displayName)
    }
  }

  public func update(_ provider: ProviderID) async throws {
    // A helper without an update command must not be launched bare: that
    // would start its interactive session, not an update.
    guard ProviderDescriptor.forProvider(provider).supportsAutomaticHelperUpdate,
      let definition = ProviderHelperCatalog.definition(for: provider)
    else {
      throw ProviderHelperInstallerError.installFailed("Update \(provider.displayName) using its official installation instructions, then return to Reserve.")
    }
    if provider.isAnthropic {
      try await self.updateClaudeCode(definition)
      return
    }
    guard let executable = BinaryLocator.find(definition.executable) else {
      throw ProviderHelperInstallerError.helperNotFound(definition.displayName)
    }
    do {
      _ = try await ProcessRunner.output(
        executable: executable,
        arguments: definition.updateArguments,
        environment: BinaryLocator.environment(Self.installerEnvironment(), launching: executable),
        timeout: .seconds(180))
    } catch {
      throw ProviderHelperInstallerError.installFailed(
        "\(definition.displayName) could not be updated. \(error.localizedDescription)")
    }
    guard BinaryLocator.find(definition.executable) != nil else {
      throw ProviderHelperInstallerError.helperNotFound(definition.displayName)
    }
  }

  /// Claude Code updates itself with `claude update`, but an old npm copy in
  /// a system folder often cannot (no write access), and a Homebrew copy
  /// leaves it to `brew`. When the copy Reserve would sign in with is still
  /// too old afterwards, the official installer puts a current native build
  /// in `~/.local/bin`, which the version check then picks.
  private func updateClaudeCode(_ definition: ProviderHelperDefinition) async throws {
    let selection = await ClaudeCodeHelper.select()
    if case .tooOld(let path, _) = selection {
      _ = try? await ProcessRunner.output(
        executable: path,
        arguments: definition.updateArguments,
        environment: BinaryLocator.environment(Self.installerEnvironment(), launching: path),
        standardInput: FileHandle.nullDevice,
        timeout: .seconds(180))
    }
    switch await ClaudeCodeHelper.select() {
    case .ready: return
    case .missing, .tooOld: try await self.install(definition.provider)
    }
    if case .tooOld(_, let version) = await ClaudeCodeHelper.select() {
      throw ProviderHelperInstallerError.installFailed(
        "Claude Code is still \(version) after updating. Reserve needs \(ClaudeCodeHelper.minimumSignInVersionText) or newer.")
    }
  }

  /// This is a format guard, not a claim that arbitrary shell code is safe.
  /// Trust comes from the fixed HTTPS origin and same-host redirect policy.
  static func validateInstallerFormat(_ data: Data) throws {
    guard !data.isEmpty, data.count <= Self.maximumInstallerBytes,
      !data.contains(0),
      let text = String(data: data, encoding: .utf8),
      text.hasPrefix("#!"),
      text.prefix(160).localizedCaseInsensitiveContains("sh")
    else {
      throw ProviderHelperInstallerError.invalidResponse(
        "The provider did not return a valid installer.")
    }
  }

  private static func installerEnvironment() -> [String: String] {
    let source = ProcessInfo.processInfo.environment
    var environment: [String: String] = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      "SHELL": "/bin/zsh",
      "NO_COLOR": "1",
    ]
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"] {
      if let value = source[key], !value.isEmpty { environment[key] = value }
    }
    return environment
  }
}
