import Foundation
import Testing
@testable import ReserveCore

/// A ChatGPT Business seat can be metered by workspace credits and a personal
/// spend cap instead of time windows. That reply is real usage, not a failure.
struct OpenAIBusinessUsageTests {
  /// A Codex helper that answers the limit read with `rateLimits` and every
  /// other request with an empty result.
  static func helper(rateLimits: String) -> String {
    """
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
      [ -n "$id" ] || continue
      case "$line" in
        *rateLimits*)
          printf '{"id":%s,"result":{"rateLimits":\(rateLimits)}}\\n' "$id" ;;
        *) printf '{"id":%s,"result":{}}\\n' "$id" ;;
      esac
    done
    """
  }

  static let business = #"""
    {"planType":"business","primary":null,"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"120"},"individualLimit":{"used":"12","limit":"50","remainingPercent":76,"resetsAt":1800000000}}
    """#

  /// Runs a real fetch against the helper. The sandbox removes the helper
  /// when it goes away, so it is kept alive until the fetch ends.
  private func fetch(rateLimits: String) async throws -> UsageSnapshot {
    let sandbox = try BinaryLocatorTrustTests.Sandbox()
    defer { withExtendedLifetime(sandbox) {} }
    let path = try sandbox.executable("bin/codex")
    try Self.helper(rateLimits: rateLimits).write(toFile: path, atomically: false, encoding: .utf8)
    let provider = OpenAIProvider(environment: ["PATH": "/usr/bin:/bin"], executableLocator: { _ in [path] })
    return try await provider.fetch()
  }

  @Test func businessSeatWithoutWindowsShowsCreditsAndSpendCap() async throws {
    let snapshot = try await self.fetch(rateLimits: Self.business)

    #expect(snapshot.planName == "Business")
    // No window means no percentage meter: nothing is invented.
    #expect(snapshot.windows.isEmpty)
    let byLabel = Dictionary(uniqueKeysWithValues: snapshot.details.map { ($0.label, $0.value) })
    #expect(byLabel["Credits"] == "120 left")
    #expect(byLabel["Spend cap"]?.hasPrefix("12 of 50 used · 76% left · resets") == true)
    #expect(snapshot.details.allSatisfy { !$0.isPersonal })
  }

  @Test func spendCapAloneIsEnough() async throws {
    let snapshot = try await self.fetch(
      rateLimits: #"{"planType":"business","individualLimit":{"used":"3","limit":"25"}}"#
    )

    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.details.map(\.label) == ["Spend cap"])
    #expect(snapshot.details.first?.value == "3 of 25 used")
  }

  @Test func windowsStillLeadWhenCreditsComeWithThem() async throws {
    let snapshot = try await self.fetch(
      rateLimits: #"{"planType":"plus","primary":{"usedPercent":30,"windowDurationMins":300},"credits":{"hasCredits":true,"balance":"5"}}"#
    )

    #expect(snapshot.planName == "Plus")
    #expect(snapshot.windows.map(\.usedPercent) == [30])
    #expect(snapshot.details.map(\.label) == ["Credits"])
  }

  /// Without windows, an empty or unusable credit block is not usage: the
  /// card must keep saying usage is unavailable rather than look connected.
  @Test func replyWithNothingUsableIsStillUnavailable() async throws {
    for rateLimits in [
      #"{"planType":"business"}"#,
      #"{"planType":"business","credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}"#,
      #"{"planType":"business","credits":"weird","individualLimit":7}"#,
    ] {
      do {
        _ = try await self.fetch(rateLimits: rateLimits)
        Issue.record("fetch accepted \(rateLimits)")
      } catch UsageProviderError.unavailable {
      } catch {
        Issue.record("unexpected error for \(rateLimits): \(error)")
      }
    }
  }

  @Test func limitFactsIgnoreIdentityAndActivity() throws {
    let empty = OpenAIRateLimitSnapshot()
    #expect(!OpenAIDetails.hasLimitFacts(empty))

    let blocked = try JSONDecoder().decode(
      OpenAIRateLimitSnapshot.self,
      from: Data(#"{"rateLimitReachedType":"workspace_member_credits_depleted"}"#.utf8))
    #expect(OpenAIDetails.hasLimitFacts(blocked))

    let unlimited = try JSONDecoder().decode(
      OpenAIRateLimitSnapshot.self, from: Data(#"{"credits":{"unlimited":true}}"#.utf8))
    #expect(OpenAIDetails.hasLimitFacts(unlimited))
  }
}
