import Foundation
import Testing
@testable import ReserveCore

@Suite("API consumption details for an opened row")
struct APIConsumptionDetailsTests {
  /// 2025-09-17 00:00 UTC: the 17th, so a full seven-day window exists.
  private static let now = Date(timeIntervalSince1970: 1_758_067_200)

  private actor Sent {
    var value: [URLRequest] = []
    func add(_ request: URLRequest) { self.value.append(request) }
  }

  private func client(_ body: String) -> APIConsumptionClient {
    APIConsumptionClient(
      requestHandler: { request in
        (
          Data(body.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      },
      now: { Self.now })
  }

  private func byLabel(_ snapshot: APIConsumptionSnapshot) -> [String: String] {
    Dictionary(uniqueKeysWithValues: snapshot.details.map { ($0.label, $0.value) })
  }

  @Test func openRouterShowsKeyLimitOwnKeysAndFreeModels() async throws {
    let snapshot = try await self.client(
      #"""
      {"data":{"label":"laptop","usage":40.5,"usage_daily":1.5,"usage_weekly":6,
      "usage_monthly":12.34,"limit":50,"limit_remaining":9.5,"limit_reset":"monthly",
      "include_byok_in_limit":true,"byok_usage":3.2,"byok_usage_monthly":1.1,
      "is_free_tier":true,"expires_at":"2026-01-01T00:00:00Z",
      "free_model_daily_requests":{"used":12,"limit":50,"remaining":38}}}
      """#
    ).fetch(.openRouter, apiKey: "sk-or-test")
    let details = self.byLabel(snapshot)
    #expect(details["Key"] == "laptop")
    #expect(details["All time"] == "$40.50")
    #expect(details["Credit limit"] == "$50.00 · resets monthly · includes your own keys")
    #expect(details["Your own provider keys"] == "$1.10 this month · $3.20 all time")
    #expect(details["Free-model requests today"] == "12 of 50")
    #expect(details["Tier"] == "Free")
    #expect(details["Key expires"] != nil)
    // The windows the row already shows are unchanged.
    #expect(snapshot.windows.map(\.id) == ["today", "week", "month", "credits"])
  }

  @Test func openRouterWithoutACapSaysSo() async throws {
    let snapshot = try await self.client(
      #"{"data":{"usage":2,"usage_daily":0,"usage_weekly":0,"usage_monthly":2,"limit":null}}"#
    ).fetch(.openRouter, apiKey: "sk-or-test")
    #expect(self.byLabel(snapshot)["Credit limit"] == "None")
    #expect(self.byLabel(snapshot)["Your own provider keys"] == nil)
  }

  @Test func typeSafeListsEveryModelWithItsReleaseDate() async throws {
    let snapshot = try await self.client(
      #"""
      {"models":[{"name":"jev-latest","description":"Flagship System One model","release_date":"2026-05-01"},
                 {"name":"jev-preview","description":null,"release_date":null},
                 {"name":"  "}]}
      """#
    ).fetch(.typeSafe, apiKey: "ts-test")
    let details = self.byLabel(snapshot)
    #expect(snapshot.details.first?.label == "Spend and balance")
    #expect(details["jev-latest"]?.hasPrefix("Released ") == true)
    #expect(details["jev-latest description"] == "Flagship System One model")
    #expect(details["Published price"]?.contains("docs, 18 Oct 2026") == true)
    #expect(details["Default context (docs)"] == "64k tokens per request · 32k per question")
    #expect(details["Rate limits"]?.contains("console") == true)
    #expect(details["Spend and balance"] == "Not exposed by the documented API")
    #expect(details["jev-preview"] == "Available")
    #expect(snapshot.details.count == 7)
    #expect(snapshot.note?.headline == "2 models")
  }

  @Test func adminCostsShowDailyFiguresAndEveryContributor() async throws {
    // Buckets on the 1st, the 12th and today (the 17th).
    let body = #"""
      {"data":[
        {"start_time":1756684800,"results":[{"amount":{"value":4,"currency":"usd"},"line_item":"gpt-5, input"}]},
        {"start_time":1757635200,"results":[{"amount":{"value":10,"currency":"usd"},"line_item":"gpt-5, output"}]},
        {"start_time":1758067200,"results":[{"amount":{"value":1.5,"currency":"usd"},"line_item":"gpt-5, input"}]}]}
      """#
    let snapshot = try await self.client(body).fetch(.openAI, apiKey: "sk-admin-test")
    let details = self.byLabel(snapshot)
    #expect(details["Today"] == "$1.50")
    #expect(details["Last 7 days"] == "$11.50")
    #expect(details["Busiest day"]?.hasPrefix("$10.00 on ") == true)
    #expect(details["Daily average"] == "$0.91")
    #expect(details["gpt-5, output"] == "$10.00")
    #expect(details["gpt-5, input"] == "$5.50")
  }

  @Test func anthropicDailyFiguresReadStartingAt() async throws {
    let body = #"""
      {"data":[{"starting_at":"2025-09-17T00:00:00Z","results":[{"amount":"250.00","model":"claude-opus-5"}]}]}
      """#
    let snapshot = try await self.client(body).fetch(.anthropic, apiKey: "sk-ant-admin-test")
    #expect(self.byLabel(snapshot)["Today"] == "$2.50")
    #expect(self.byLabel(snapshot)["claude-opus-5"] == "$2.50")
  }

  /// Refusals use fixed credential-safe text. A billing rejection alone does
  /// not establish that an ordinary key is invalid.
  @Test func aRefusedAnthropicKeyExplainsItself() async throws {
    func refusal(status: Int, body: String, key: String) async -> String? {
      let client = APIConsumptionClient(
        requestHandler: { request in
          (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        },
        now: { Self.now })
      do {
        _ = try await client.fetch(.anthropic, apiKey: key)
        return nil
      } catch UsageProviderError.unauthorized(let message) {
        return message
      } catch {
        return "unexpected \(error)"
      }
    }
    let regular = await refusal(
      status: 401,
      body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key sk-ant-api03-regular"}}"#,
      key: "sk-ant-api03-regular-test-key-000000")
    #expect(regular == "Anthropic could not validate this API key. Check that it is active in Claude Console. "
      + "Spend reporting requires a Console organization; Individual accounts do not support the Admin API.")

    let organization = await refusal(
      status: 403,
      body: #"{"type":"error","error":{"type":"permission_error","message":"Key sk-ant-admin01-secret lacks access"}}"#,
      key: "sk-ant-admin01-secret-test-key-0000")
    #expect(organization == "Anthropic refused this admin key. The key has no access to usage and cost data. "
      + "Admin keys work only for a Claude Console organization where you are an admin.")

    let silent = await refusal(status: 401, body: "", key: "sk-ant-admin01-test")
    #expect(silent == "Anthropic refused this admin key.")
    // A code Reserve does not know is never repeated, whatever it holds.
    let unknown = await refusal(
      status: 401, body: #"{"error":{"code":"fragment_of_the_key"}}"#, key: "sk-ant-admin01-test")
    #expect(unknown == "Anthropic refused this admin key.")
    // Every message fits the stored error limit with room to spare.
    for message in [regular, organization, silent] { #expect((message?.count ?? 0) <= 240) }
  }

  @Test(arguments: [401, 403])
  func ordinaryAnthropicKeyCanBeValidWithoutBillingAccess(_ status: Int) async throws {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      #expect(request.url?.host == "api.anthropic.com")
      let models = request.url?.path == "/v1/models"
      #expect(request.value(forHTTPHeaderField: "Authorization") == (models ? "Bearer sk-ant-api03-test" : nil))
      #expect(request.value(forHTTPHeaderField: "x-api-key") == (models ? nil : "sk-ant-api03-test"))
      #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
      #expect(request.httpMethod == nil || request.httpMethod == "GET")
      let body = models
        ? #"{"data":[{"id":"claude-test","display_name":"Claude test"}],"has_more":false}"#
        : #"{"error":{"type":"authentication_error"}}"#
      return (Data(body.utf8), HTTPURLResponse(
        url: request.url!, statusCode: models ? 200 : status, httpVersion: nil, headerFields: nil)!)
    })
    let snapshot = try await client.fetch(.anthropic, apiKey: "sk-ant-api03-test")
    #expect(await sent.value.map { $0.url!.path } == ["/v1/organizations/cost_report", "/v1/models"])
    #expect(snapshot.note?.headline == "Key valid")
    #expect(snapshot.note?.detail?.contains("Billing unavailable") == true)
    #expect(snapshot.windows.isEmpty && snapshot.primary == nil)
    #expect(snapshot.source == "Anthropic Models API")
    #expect(self.byLabel(snapshot)["Models"] == "Claude test")
  }

  @Test(arguments: ["sk-ant-usr-fixture-personal", "sk-ant-svc-fixture-service", "sk-ant-api03-fixture-legacy"])
  func billingKeysUseDocumentedAdminAPIAuthentication(_ key: String) async throws {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "x-api-key") == key)
      #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
      return (Data(#"{"data":[{"results":[{"amount":"123.00"}]}]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let snapshot = try await client.fetch(.anthropic, apiKey: key)
    #expect(snapshot.primary?.usedMinorUnits == 123)
    #expect(snapshot.source == "Anthropic Cost API")
    #expect(await sent.value.count == 1)
  }

  @Test func legacyAdminAuthenticationStillUsesXAPIKey() async throws {
    let client = APIConsumptionClient(requestHandler: { request in
      #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-admin01-fixture")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      return (Data(#"{"data":[]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    _ = try await client.fetch(.anthropic, apiKey: "sk-ant-admin01-fixture")
    #expect(APIConsumptionProvider.anthropic.keySettingsURL.absoluteString
      == "https://platform.claude.com/settings/keys")
  }

  @Test(arguments: [401, 403])
  func personalKeyFallbackRetainsBillingFailureWithoutEchoingSecrets(_ status: Int) async throws {
    let key = "sk-ant-usr-fixture-secret"
    let client = APIConsumptionClient(requestHandler: { request in
      let models = request.url?.path == "/v1/models"
      let body = models ? #"{"data":[{"id":"claude-fixture"}]}"#
        : #"{"error":{"type":"permission_error","message":"Denied key sk-ant-usr-fixture-secret"}}"#
      return (Data(body.utf8), HTTPURLResponse(
        url: request.url!, statusCode: models ? 200 : status, httpVersion: nil, headerFields: nil)!)
    })
    let snapshot = try await client.fetch(.anthropic, apiKey: key)
    let details = self.byLabel(snapshot)
    #expect(details["Credential type"] == "Personal API key")
    #expect(details["Billing response"]?.contains("HTTP \(status)") == true)
    #expect(details["Billing response"]?.contains("Permission denied") == true)
    #expect(snapshot.note?.detail?.contains("account type") == true)
    #expect(details["Account eligibility"]?.contains("Individual accounts") == true)
    #expect(snapshot.note?.detail?.contains("use an admin key") == false)
    let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!encoded.contains(key))
    #expect(snapshot.windows.isEmpty)
  }

  @Test func ordinaryKeyWithBillingAccessStillShowsSpend() async throws {
    let snapshot = try await self.client(
      #"{"data":[{"results":[{"amount":"250.00"}]}]}"#
    ).fetch(.anthropic, apiKey: "sk-ant-api03-unscoped")
    #expect(snapshot.primary?.usedMinorUnits == 250)
    #expect(snapshot.source == "Anthropic Cost API")
  }

  @Test(arguments: [429, 500])
  func billingOutagesDoNotBecomeSuccessfulKeyValidation(_ status: Int) async {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    })
    await #expect(throws: UsageProviderError.self) {
      _ = try await client.fetch(.anthropic, apiKey: "sk-ant-api03-test")
    }
    #expect(await sent.value.count == 1)
  }

  @Test func malformedModelValidationIsNotASuccess() async {
    let client = APIConsumptionClient(requestHandler: { request in
      let models = request.url?.path == "/v1/models"
      return (Data(#"{"unexpected":true}"#.utf8), HTTPURLResponse(
        url: request.url!, statusCode: models ? 200 : 401, httpVersion: nil, headerFields: nil)!)
    })
    await #expect(throws: UsageProviderError.self) {
      _ = try await client.fetch(.anthropic, apiKey: "sk-ant-api03-test")
    }
  }

  /// Only a code-shaped value survives; free text, which can quote the key,
  /// never does.
  @Test func onlyErrorCodesAreRead() {
    func code(_ json: String) -> String? { APIConsumptionClient.providerErrorCode(in: Data(json.utf8)) }
    #expect(code(#"{"error":{"code":"invalid_api_key","message":"Incorrect API key sk-pr****abcd"}}"#) == "invalid_api_key")
    #expect(code(#"{"error":{"type":"permission_error"}}"#) == "permission_error")
    #expect(code(#"{"error":"bad key sk-abc"}"#) == nil)
    #expect(code(#"{"error":{"code":"sk-ant-admin01-leak"}}"#) == nil)
    #expect(code(#"{"error":{"code":"Key sk_live_abc"}}"#) == nil)
    #expect(code("not json") == nil)
  }

  @Test func detailsSurviveTheCacheAndOldCachesStillLoad() throws {
    let snapshot = APIConsumptionSnapshot(
      provider: .openRouter, windows: [], source: "test",
      details: [UsageDetail("Key", "laptop")])
    let decoded = try JSONDecoder().decode(
      APIConsumptionSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    let legacy = Data(#"{"provider":"xAI","windows":[],"fetchedAt":0,"source":"old"}"#.utf8)
    #expect(try JSONDecoder().decode(APIConsumptionSnapshot.self, from: legacy).details.isEmpty)
  }
}
