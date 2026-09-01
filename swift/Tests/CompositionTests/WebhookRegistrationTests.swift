//  WebhookRegistrationTests
//  Registering and editing a webhook, against a real database.
//
//  `createWebhook` upserts on the URL, which is right for "register this endpoint again after
//  a reinstall" and wrong for "change this endpoint's address": through the upsert, a changed
//  URL leaves the old row registered and still being POSTed to. That is the whole reason
//  `updateWebhook` exists, so it is the thing worth pinning here.
//
//  The event list is the other half. It has been a column, a matcher and a request field all
//  along while the settings window only ever wrote `["*"]` — so what matters is that a chosen
//  set survives the round trip into the column `WebhookSink` reads.
//
//  See `.claude/docs/architecture.md`.

import BBDiagnostics
import BBHTTPAPI
import BBPersistence
import BBSerialization
import BBSettings
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Webhook registration")
struct WebhookRegistrationTests {

  private func makeInterface() async throws -> ServerInterface {
    let database = try AppDatabase.inMemory()
    return ServerInterface(
      database: database,
      alerts: AlertCenter(),
      settings: try await SettingsStore(
        database: database, secrets: InMemorySecretStore()
      ),
      messages: nil
    )
  }

  private func events(_ hook: JSONValue) -> [String] {
    hook["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  @Test("A chosen event set survives registration")
  func storesChosenEvents() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(
      url: "https://example.com/hook", events: ["new-message", "typing-indicator"]
    )
    #expect(events(created) == ["new-message", "typing-indicator"])

    // And it is what a later read returns, not just what the create call echoed back.
    let listed = try await server.webhooks()
    #expect(listed.count == 1)
    #expect(events(listed[0]) == ["new-message", "typing-indicator"])
  }

  @Test("An empty event list means everything")
  func emptyMeansWildcard() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(url: "https://example.com/hook", events: [])
    // Not an empty array: `WebhookTarget.matches` treats an empty subscription as
    // matching nothing, so storing one would register an endpoint that is never called.
    #expect(events(created) == ["*"])
  }

  @Test("Subscriptions can be narrowed after the fact")
  func updatesEvents() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(url: "https://example.com/hook", events: ["*"])
    let id = Int64(try #require(created["id"]?.intValue))

    let updated = try await server.updateWebhook(id: id, url: nil, events: ["new-message"])
    #expect(events(updated) == ["new-message"])
    #expect(updated["url"]?.stringValue == "https://example.com/hook")

    let listed = try await server.webhooks()
    #expect(listed.count == 1)
    #expect(events(listed[0]) == ["new-message"])
  }

  @Test("Changing the URL moves the endpoint rather than adding one")
  func updatesURLInPlace() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(url: "https://old.example.com/hook", events: ["*"])
    let id = Int64(try #require(created["id"]?.intValue))

    _ = try await server.updateWebhook(id: id, url: "https://new.example.com/hook", events: nil)

    // The failure this guards: through `createWebhook`'s URL-keyed upsert this leaves TWO
    // rows, and the old address keeps receiving every event.
    let listed = try await server.webhooks()
    #expect(listed.count == 1)
    #expect(listed[0]["url"]?.stringValue == "https://new.example.com/hook")
    #expect(events(listed[0]) == ["*"])
  }

  @Test("Omitting a field leaves it alone")
  func partialUpdate() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(
      url: "https://example.com/hook", events: ["new-message"]
    )
    let id = Int64(try #require(created["id"]?.intValue))

    // Events absent, not empty — a caller changing only the URL must not blank the
    // subscription, and empty means the wildcard, so the two cannot be conflated.
    let updated = try await server.updateWebhook(
      id: id, url: "https://example.com/other", events: nil
    )
    #expect(events(updated) == ["new-message"])
    #expect(updated["url"]?.stringValue == "https://example.com/other")
  }

  @Test("Moving one endpoint onto another's address is refused")
  func rejectsDuplicateURL() async throws {
    let server = try await makeInterface()
    _ = try await server.createWebhook(url: "https://a.example.com/hook", events: ["*"])
    let second = try await server.createWebhook(url: "https://b.example.com/hook", events: ["*"])
    let id = Int64(try #require(second["id"]?.intValue))

    await #expect(throws: InterfaceError.self) {
      _ = try await server.updateWebhook(id: id, url: "https://a.example.com/hook", events: nil)
    }

    // And nothing moved.
    let listed = try await server.webhooks()
    #expect(listed.count == 2)
    #expect(listed[1]["url"]?.stringValue == "https://b.example.com/hook")
  }

  @Test("Editing a webhook that is not there is a not-found, not a silent no-op")
  func rejectsMissingID() async throws {
    let server = try await makeInterface()
    await #expect(throws: InterfaceError.self) {
      _ = try await server.updateWebhook(id: 404, url: nil, events: ["new-message"])
    }
  }

  @Test("A non-HTTP URL is refused on edit as well as on create")
  func validatesURL() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(url: "https://example.com/hook", events: ["*"])
    let id = Int64(try #require(created["id"]?.intValue))

    await #expect(throws: InterfaceError.self) {
      _ = try await server.updateWebhook(id: id, url: "ftp://example.com/hook", events: nil)
    }
  }
}
