import Foundation
import Testing
@testable import ReserveCore

/// `claude.ai/install.sh` redirects to `downloads.claude.ai`, and
/// `chatgpt.com/codex/install.sh` to `releases.openai.com` (checked
/// 2026-11-03). Refusing every cross-host redirect made "Install and
/// continue" fail for both with "could not be downloaded".
struct InstallerDownloadTests {
  private static let script = Data("#!/bin/bash\necho setup\n".utf8)

  @Test(arguments: [ProviderID.anthropic, .openAI])
  func theOfficialInstallerIsFollowedToItsDownloadHost(_ provider: ProviderID) async throws {
    let definition = try #require(ProviderHelperCatalog.definition(for: provider))
    let data = try await ProviderHelperInstaller(session: RedirectingInstallerProtocol.session())
      .downloadInstaller(definition)
    #expect(data == Self.script)
  }

  @Test(arguments: [
    "https://claude.ai/install.sh?to=https://claude.ai.example.com/install.sh",
    "https://claude.ai/install.sh?to=https://notclaude.ai/install.sh",
    "https://claude.ai/install.sh?to=http://downloads.claude.ai/install.sh",
  ])
  func aRedirectAnywhereElseIsRefused(_ address: String) async throws {
    let official = try #require(ProviderHelperCatalog.definition(for: .anthropic))
    let definition = ProviderHelperDefinition(
      provider: .anthropic, executable: official.executable, displayName: official.displayName,
      installerURL: try #require(URL(string: address)), installerDomains: official.installerDomains,
      updateArguments: official.updateArguments)
    await #expect(throws: ProviderHelperInstallerError.self) {
      _ = try await ProviderHelperInstaller(session: RedirectingInstallerProtocol.session())
        .downloadInstaller(definition)
    }
    // Refused before it is requested, not fetched and thrown away afterwards.
    let destination = try #require(
      URLComponents(string: address)?.queryItems?.first { $0.name == "to" }?.value)
    #expect(!RedirectingInstallerProtocol.requested.contains(destination))
  }

  @Test func onlyTheProvidersOwnDomainsCount() throws {
    let claude = try #require(ProviderHelperCatalog.definition(for: .anthropic))
    #expect(claude.isOfficialInstallerAddress(URL(string: "https://claude.ai/install.sh")))
    #expect(claude.isOfficialInstallerAddress(URL(string: "https://downloads.claude.ai/x/bootstrap.sh")))
    #expect(!claude.isOfficialInstallerAddress(URL(string: "http://downloads.claude.ai/x/bootstrap.sh")))
    #expect(!claude.isOfficialInstallerAddress(URL(string: "https://evilclaude.ai/install.sh")))
    #expect(!claude.isOfficialInstallerAddress(URL(string: "https://claude.ai.example.com/install.sh")))
    #expect(!claude.isOfficialInstallerAddress(URL(string: "https://releases.openai.com/codex/install.sh")))
    let grok = try #require(ProviderHelperCatalog.definition(for: .grok))
    // No domains listed: only the installer's own host.
    #expect(grok.isOfficialInstallerAddress(URL(string: "https://x.ai/cli/install.sh")))
    #expect(!grok.isOfficialInstallerAddress(URL(string: "https://downloads.x.ai/cli/install.sh")))
  }
}

/// Answers the two official installer addresses with the redirects they
/// really send, `?to=` with a redirect to that address, and anything else
/// with the script.
private final class RedirectingInstallerProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestedAddresses: Set<String> = []
  static var requested: Set<String> { Self.lock.withLock { Self.requestedAddresses } }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RedirectingInstallerProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = self.request.url else { return }
    _ = Self.lock.withLock { Self.requestedAddresses.insert(url.absoluteString) }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    let target: String? = switch (url.host, url.path) {
    case _ where query?.first(where: { $0.name == "to" }) != nil:
      query?.first(where: { $0.name == "to" })?.value
    case ("claude.ai", "/install.sh"): "https://downloads.claude.ai/claude-code-releases/bootstrap.sh"
    case ("chatgpt.com", "/codex/install.sh"): "https://releases.openai.com/codex/install.sh"
    default: nil
    }
    if let target, let destination = URL(string: target),
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])
    {
      self.client?.urlProtocol(
        self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocolDidFinishLoading(self)
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    self.client?.urlProtocol(self, didLoad: Data("#!/bin/bash\necho setup\n".utf8))
    self.client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
