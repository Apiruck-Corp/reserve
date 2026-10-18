import Foundation
import Testing
@testable import ReserveCore

@Suite("Anthropic identity-key workspace context")
struct AnthropicWorkspaceContextTests {
  private static let missing = #"{"error":{"type":"invalid_request_error","message":"anthropic-workspace-id is required when authenticating with an identity-linked API key; send the id of the workspace this request acts in."}}"#
  private static let workspaces = #"{"data":[{"id":"wrkspc_default","name":"Default","archived_at":null},{"id":"wrkspc_archived","name":"Default Workspace","archived_at":"2026-01-01"}],"has_more":false}"#
  private static let spend = #"{"data":[{"results":[{"amount":"123.00"}]}],"has_more":false}"#

  private actor Sent {
    var value: [URLRequest] = []
    func add(_ request: URLRequest) { self.value.append(request) }
  }

  private static func reply(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  @Test func resolvesTheDefaultOnlyAfterTheDocumentedMissingContextResponse() async throws {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      #expect(request.url?.host == "api.anthropic.com")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-usr-fixture")
      #expect(request.httpMethod == nil || request.httpMethod == "GET")
      if request.url?.path == "/v1/organizations/workspaces" {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "include_default", value: "true")) == true)
        return Self.reply(request, 200, Self.workspaces)
      }
      #expect(request.url?.path == "/v1/organizations/cost_report")
      let context = request.value(forHTTPHeaderField: "anthropic-workspace-id")
      if context == nil { return Self.reply(request, 400, Self.missing) }
      #expect(context == "wrkspc_default")
      #expect(request.url?.query?.contains("workspace_ids") == false)
      return Self.reply(request, 200, Self.spend)
    })
    let snapshot = try await client.fetch(.anthropic, apiKey: "sk-ant-usr-fixture")
    #expect(snapshot.primary?.usedMinorUnits == 123)
    #expect(snapshot.source == "Anthropic Cost API")
    #expect(await sent.value.map { $0.url!.path } == [
      "/v1/organizations/cost_report", "/v1/organizations/workspaces", "/v1/organizations/cost_report",
    ])
  }

  @Test func modelValidationCanRequireContextAfterBillingIsRefused() async throws {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      switch request.url?.path {
      case "/v1/organizations/workspaces": return Self.reply(request, 200, Self.workspaces)
      case "/v1/models":
        if request.value(forHTTPHeaderField: "anthropic-workspace-id") == nil {
          return Self.reply(request, 400, Self.missing)
        }
        return Self.reply(request, 200, #"{"data":[{"id":"claude-fixture"}]}"#)
      default: return Self.reply(request, 403, #"{"error":{"type":"permission_error"}}"#)
      }
    })
    let snapshot = try await client.fetch(.anthropic, apiKey: "sk-ant-usr-fixture")
    #expect(snapshot.note?.headline == "Key valid")
    #expect(snapshot.details.first { $0.label == "Billing response" }?.value.contains("HTTP 403") == true)
    #expect(snapshot.windows.isEmpty)
    #expect(await sent.value.count == 5)
  }

  @Test func ordinaryBadRequestsDoNotTriggerWorkspaceDiscovery() async {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      return Self.reply(request, 400, #"{"error":{"type":"invalid_request_error","message":"invalid starting_at"}}"#)
    })
    do {
      _ = try await client.fetch(.anthropic, apiKey: "sk-ant-usr-fixture")
      Issue.record("bad request was treated as success")
    } catch UsageProviderError.invalidResponse(let message) {
      #expect(message.contains("Cost Report API"))
      #expect(message.contains("HTTP 400"))
    } catch { Issue.record("unexpected error \(error)") }
    #expect(await sent.value.count == 2) // Existing grouped/ungrouped fallback only.
    #expect(await sent.value.allSatisfy { $0.url?.path == "/v1/organizations/cost_report" })
  }

  @Test func discoveryCannotLoopIfItAlsoRequiresWorkspaceContext() async {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      return Self.reply(request, 400, Self.missing)
    })
    await #expect(throws: UsageProviderError.self) {
      _ = try await client.fetch(.anthropic, apiKey: "sk-ant-usr-fixture")
    }
    #expect(await sent.value.count == 2)
  }

  @Test func multipleNonDefaultWorkspacesAreNotChosenArbitrarily() async {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      if request.url?.path == "/v1/organizations/workspaces" {
        return Self.reply(request, 200, #"{"data":[{"id":"wrkspc_a","name":"A"},{"id":"wrkspc_b","name":"B"}]}"#)
      }
      return Self.reply(request, 400, Self.missing)
    })
    await #expect(throws: UsageProviderError.self) {
      _ = try await client.fetch(.anthropic, apiKey: "sk-ant-usr-fixture")
    }
    #expect(await sent.value.count == 2)
  }

  @Test func discoveryFollowsItsOwnCursorAndRetriesWithTheDefault() async throws {
    let sent = Sent()
    let client = APIConsumptionClient(requestHandler: { request in
      await sent.add(request)
      if request.url?.path == "/v1/organizations/workspaces" {
        if request.url?.query?.contains("after_id=") == true {
          return Self.reply(request, 200, Self.workspaces)
        }
        return Self.reply(request, 200, #"{"data":[{"id":"wrkspc_first","name":"Other"}],"has_more":true,"last_id":"next"}"#)
      }
      if request.value(forHTTPHeaderField: "anthropic-workspace-id") != nil {
        return Self.reply(request, 200, Self.spend)
      }
      return Self.reply(request, 400, Self.missing)
    })
    let snapshot = try await client.fetch(.anthropic, apiKey: "sk-ant-usr-fixture")
    #expect(snapshot.primary?.usedMinorUnits == 123)
    #expect(await sent.value.count == 4)
  }

  @Test func missingWorkspaceDetectionDoesNotExposeFreeTextOrMatchOtherErrors() {
    #expect(APIConsumptionClient.anthropicRequiresWorkspace(Data(Self.missing.utf8)))
    #expect(!APIConsumptionClient.anthropicRequiresWorkspace(Data(#"{"error":{"type":"authentication_error","message":"anthropic-workspace-id is required"}}"#.utf8)))
    #expect(!APIConsumptionClient.anthropicRequiresWorkspace(Data(#"{"error":{"type":"invalid_request_error","message":"anthropic-workspace-id header must be a valid workspace ID."}}"#.utf8)))
    #expect(!APIConsumptionClient.anthropicRequiresWorkspace(Data("not json".utf8)))
    #expect(!APIConsumptionClient.anthropicRequiresWorkspace(Data(repeating: 65, count: 16_385)))
  }

  @Test func rejectionHintsReturnOnlyFixedCategories() {
    let body = Data(#"{"error":{"type":"invalid_request_error","message":"Missing workspace header for API key sk-ant-usr-secret-fixture and organization org_private."}}"#.utf8)
    #expect(APIConsumptionClient.anthropicRequestErrorHints(body)
      == " Response categories: workspace context, organization scope, API key, request header, required input.")
    #expect(APIConsumptionClient.anthropicRequestErrorHints(Data(#"{"error":{"message":"sk-ant-usr-secret-fixture"}}"#.utf8)).isEmpty)
    #expect(APIConsumptionClient.anthropicRequestErrorHints(Data("not JSON".utf8)).isEmpty)
    #expect(APIConsumptionClient.anthropicRequestErrorHints(Data(repeating: 65, count: 16_385)).isEmpty)
  }
}
