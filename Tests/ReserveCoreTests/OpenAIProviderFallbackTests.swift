import Foundation
import Testing
@testable import ReserveCore

/// A Codex install that passes validation but cannot start must not hide a
/// working one later in the search order.
struct OpenAIProviderFallbackTests {
  /// Reads the first request, then exits, as an npm wrapper whose platform
  /// binary is missing does.
  static let brokenHelper = """
    #!/bin/sh
    read -r _
    echo "spawn codex ENOENT" >&2
    exit 1
    """

  /// Answers every request, and reports one weekly window for the limit read.
  static let workingHelper = """
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
      [ -n "$id" ] || continue
      case "$line" in
        *rateLimits*)
          printf '{"id":%s,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":42,"windowDurationMins":10080}}}}\\n' "$id" ;;
        *) printf '{"id":%s,"result":{}}\\n' "$id" ;;
      esac
    done
    """

  private func script(_ body: String, at relative: String, in sandbox: BinaryLocatorTrustTests.Sandbox)
    throws -> String
  {
    let path = try sandbox.executable(relative)
    try body.write(toFile: path, atomically: false, encoding: .utf8)
    return path
  }

  @Test func brokenFirstInstallFallsBackToTheNextOne() async throws {
    let sandbox = try BinaryLocatorTrustTests.Sandbox()
    let broken = try script(Self.brokenHelper, at: "homebrew/bin/codex", in: sandbox)
    let working = try script(Self.workingHelper, at: "npm-global/bin/codex", in: sandbox)
    let provider = OpenAIProvider(
      environment: ["PATH": "/usr/bin:/bin"], executableLocator: { _ in [broken, working] })

    let snapshot = try await provider.fetch()

    #expect(snapshot.planName == "Pro")
    #expect(snapshot.windows.map(\.usedPercent) == [42])
  }

  @Test func everyInstallBrokenReportsTheFirstFailure() async throws {
    let sandbox = try BinaryLocatorTrustTests.Sandbox()
    let first = try script(Self.brokenHelper, at: "a/codex", in: sandbox)
    let second = try script(Self.brokenHelper, at: "b/codex", in: sandbox)
    let provider = OpenAIProvider(
      environment: ["PATH": "/usr/bin:/bin"], executableLocator: { _ in [first, second] })

    await #expect(throws: UsageProviderError.self) { try await provider.fetch() }
  }

  /// An npm install of Codex is a `#!/usr/bin/env node` script. Opened from the
  /// Dock, Reserve's PATH is only the system folders, which hold no Node, so
  /// the helper must still find the Node installed beside it.
  static let nodeScriptHelper = """
    #!/usr/bin/env node
    require('../lib/codex.js')
    """

  @Test func npmInstallFindsTheNodeBesideIt() async throws {
    let sandbox = try BinaryLocatorTrustTests.Sandbox()
    _ = try script(Self.workingHelper, at: "local/bin/node", in: sandbox)
    let codex = try script(Self.nodeScriptHelper, at: "local/bin/codex", in: sandbox)
    let provider = OpenAIProvider(
      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], executableLocator: { _ in [codex] })

    let snapshot = try await provider.fetch()

    #expect(snapshot.windows.map(\.usedPercent) == [42])
  }

  /// nvm keeps Node beside its `bin/codex` link, which points on to the real
  /// script elsewhere; a link in another folder (such as `~/.local/bin`) may
  /// point to that link.
  @Test func linkedNpmInstallFindsTheNodeBesideItsTarget() async throws {
    let sandbox = try BinaryLocatorTrustTests.Sandbox()
    _ = try script(Self.workingHelper, at: "nvm/bin/node", in: sandbox)
    _ = try script(Self.nodeScriptHelper, at: "nvm/lib/node_modules/codex/bin/codex.js", in: sandbox)
    try sandbox.link("nvm/bin/codex", to: "../lib/node_modules/codex/bin/codex.js")
    try sandbox.link("links/codex", to: sandbox.path("nvm/bin/codex"))
    let link = sandbox.path("links/codex")
    let provider = OpenAIProvider(
      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], executableLocator: { _ in [link] })

    let snapshot = try await provider.fetch()

    #expect(snapshot.windows.map(\.usedPercent) == [42])
  }

  /// A terminal launch already has the user's PATH; it must stay first, as is.
  @Test func helperFoldersComeAfterTheInheritedPath() throws {
    let sandbox = try BinaryLocatorTrustTests.Sandbox()
    let codex = try script(Self.nodeScriptHelper, at: "local/bin/codex", in: sandbox)
    let inherited = "/custom/node/bin::/usr/bin:\(sandbox.path("local/bin"))"

    #expect(BinaryLocator.environment(["PATH": inherited], launching: codex)["PATH"] == inherited)
    #expect(
      BinaryLocator.environment(["PATH": "/custom/node/bin:/usr/bin"], launching: codex)["PATH"]
        == "/custom/node/bin:/usr/bin:\(sandbox.path("local/bin"))")
  }

  @Test func noInstallIsReportedAsMissing() async {
    let provider = OpenAIProvider(environment: [:], executableLocator: { _ in [] })
    do {
      _ = try await provider.fetch()
      Issue.record("fetch succeeded without a Codex install")
    } catch UsageProviderError.executableNotFound {
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }
}
