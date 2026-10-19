import Foundation
import Testing

@testable import ReserveCore

/// Several keys per API provider: each one an account with its own Keychain
/// item, while the first account keeps the item it always had.
@Suite struct APIAccountTests {
  @Test func firstAccountKeepsItsExistingNames() throws {
    #expect(APIAccountID.anthropic.rawValue == "anthropic")
    #expect(APIConsumptionKeychain.account(for: .anthropic) == "api-consumption.anthropic")
    let added = try #require(APIAccountID(provider: .anthropic, instance: "ab12cd34"))
    #expect(added.rawValue == "anthropic@ab12cd34")
    #expect(APIConsumptionKeychain.account(for: added) == "api-consumption.anthropic@ab12cd34")
    #expect(APIAccountID(rawValue: "anthropic@ab12cd34") == added)
    #expect(APIAccountID(rawValue: "anthropic") == .anthropic)
    #expect(APIAccountID(rawValue: "typeface") == nil)
    #expect(APIAccountID(rawValue: "anthropic@bad/instance") == nil)
    #expect(APIAccountID(provider: .anthropic, instance: "") == nil)
  }

  @Test func accountsSortByProviderThenFirstAccount() throws {
    let added = try #require(APIAccountID(provider: .openAI, instance: "zz"))
    #expect([APIAccountID.anthropic, added, .openAI].sorted() == [.openAI, added, .anthropic])
  }

  @Test func labelsNameTheAccount() throws {
    let added = try #require(APIAccountID(provider: .anthropic, instance: "label-test"))
    APIAccountLabels.set("Nimbus", for: added)
    defer { APIAccountLabels.set(nil, for: added) }
    #expect(added.displayName == "Anthropic · Nimbus")
    APIAccountLabels.set("  ", for: added)
    #expect(added.displayName == "Anthropic · added account")
    #expect(added.keyKind == "API key" && added.keyHint == "sk-ant-api03-…")
  }
}
