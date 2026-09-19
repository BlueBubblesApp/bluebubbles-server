//  WebhookRegistrationTests
//  Registering and editing a webhook, against a real database.
//
//  `createWebhook` upserts on the URL, which is right for "register this endpoint again after
//  a reinstall" and wrong for "change this endpoint's address": through the upsert, a changed
//  URL leaves the old row registered and still being POSTed to. That is the whole reason
//  `updateWebhook` exists, so it is the thing worth pinning here.
//
//  The event list is the other half. It has been a column, a matcher and a request field all
//  along while the settings window only ever wrote `["*"]`, so what matters is that a chosen
//  set survives the round trip into the column `WebhookSink` reads.
//
//  See `.claude/docs/architecture.md`.

import BBAppStore
import BBDiagnostics
import BBHTTPAPI
import BBMedia
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

  private func makeInterface() async throws -> AdminInterface {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    return AdminInterface(
      database: database,
      alerts: AlertCenter(),
      settings: try await SettingsStore(
        database: database, secrets: InMemorySecretStore()
      ),
      messages: nil
    )
  }

  private func events(_ hook: Webhook) -> [String] { hook.subscribedEvents }

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
    let id = try #require(created.id)

    let updated = try await server.updateWebhook(id: id, url: nil, events: ["new-message"])
    #expect(events(updated) == ["new-message"])
    #expect(updated.url == "https://example.com/hook")

    let listed = try await server.webhooks()
    #expect(listed.count == 1)
    #expect(events(listed[0]) == ["new-message"])
  }

  @Test("Changing the URL moves the endpoint rather than adding one")
  func updatesURLInPlace() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(url: "https://old.example.com/hook", events: ["*"])
    let id = try #require(created.id)

    _ = try await server.updateWebhook(id: id, url: "https://new.example.com/hook", events: nil)

    // The failure this guards: through `createWebhook`'s URL-keyed upsert this leaves TWO
    // rows, and the old address keeps receiving every event.
    let listed = try await server.webhooks()
    #expect(listed.count == 1)
    #expect(listed[0].url == "https://new.example.com/hook")
    #expect(events(listed[0]) == ["*"])
  }

  @Test("Omitting a field leaves it alone")
  func partialUpdate() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(
      url: "https://example.com/hook", events: ["new-message"]
    )
    let id = try #require(created.id)

    // Events absent, not empty: a caller changing only the URL must not blank the
    // subscription, and empty means the wildcard, so the two cannot be conflated.
    let updated = try await server.updateWebhook(
      id: id, url: "https://example.com/other", events: nil
    )
    #expect(events(updated) == ["new-message"])
    #expect(updated.url == "https://example.com/other")
  }

  // MARK: - The redirect policy

  /// Off unless asked for. `URLSession` follows redirects by default, so the URL an operator
  /// approved is otherwise not the only address that receives their messages.
  @Test("A new webhook does not follow redirects")
  func newWebhookRefusesRedirects() async throws {
    let admin = try await makeInterface()
    let hook = try await admin.createWebhook(url: "https://example.com/a", events: ["*"])
    #expect(hook.followRedirects == false)
    #expect(Webhook.defaultFollowRedirects == false)
  }

  @Test("The switch survives a round trip in both directions")
  func policyRoundTrips() async throws {
    let admin = try await makeInterface()
    let created = try await admin.createWebhook(
      url: "https://example.com/a", events: ["*"], followRedirects: true)
    #expect(created.followRedirects)

    let id = try #require(created.id)
    let off = try await admin.updateWebhook(
      id: id, url: nil, events: nil, followRedirects: false)
    #expect(off.followRedirects == false)

    let back = try await admin.updateWebhook(
      id: id, url: nil, events: nil, followRedirects: true)
    #expect(back.followRedirects)
  }

  /// **Absent means "leave it", never "turn it off".** `createWebhook` upserts on the URL, so
  /// a client re-registering its endpoint after a reinstall sends the two fields it has always
  /// sent — and reading that omission as `false` would silently disarm a switch the operator
  /// had turned on, through a request that was not about redirects at all.
  @Test("A create that says nothing leaves an existing endpoint's policy alone")
  func silentRecreateDoesNotDisarm() async throws {
    let admin = try await makeInterface()
    _ = try await admin.createWebhook(
      url: "https://example.com/a", events: ["*"], followRedirects: true)

    // Exactly what a v1 client sends: a URL and an event list, and no opinion.
    let again = try await admin.createWebhook(
      url: "https://example.com/a", events: ["new-message"])

    #expect(again.followRedirects)
    #expect(events(again) == ["new-message"])
  }

  @Test("An update that says nothing leaves the policy alone too")
  func silentUpdateDoesNotDisarm() async throws {
    let admin = try await makeInterface()
    let created = try await admin.createWebhook(
      url: "https://example.com/a", events: ["*"], followRedirects: true)
    let id = try #require(created.id)

    let renamed = try await admin.updateWebhook(
      id: id, url: "https://example.com/b", events: nil)

    #expect(renamed.followRedirects)
    #expect(renamed.url == "https://example.com/b")
  }

  /// The delivery path reads `targets()`, not `all()`, and a policy that stops at the record
  /// is a policy the transport never hears about.
  @Test("The policy reaches the delivery target")
  func policyReachesTheTarget() async throws {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = WebhookRepository(database: database)
    _ = try await store.upsert(url: "https://example.com/a", events: ["*"])
    _ = try await store.upsert(
      url: "https://example.com/b", events: ["*"], followRedirects: true)

    let targets = try await store.targets().sorted { $0.url < $1.url }
    #expect(targets.map(\.followRedirects) == [false, true])
  }

  /// The migration's asymmetry, asserted through the DDL default that produces it.
  ///
  /// `ALTER TABLE … ADD COLUMN … NOT NULL DEFAULT 1` is what backfills the rows that already
  /// existed, so a webhook registered before the column did keeps following redirects — which
  /// is what it has been doing, and changing it on upgrade would break a working integration.
  /// An insert that names the column (every insert this code makes) is unaffected.
  @Test("A row that predates the column reads as following redirects")
  func migratedRowsKeepFollowing() async throws {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    // Written WITHOUT the column, which is the shape every pre-migration row has.
    try await database.write { db in
      try db.execute(
        sql: "INSERT INTO webhook (url, events, created_at) VALUES (?, ?, ?)",
        arguments: ["https://legacy.example.com/hook", "[\"*\"]", Date()]
      )
    }
    let rows = try await WebhookRepository(database: database).all()
    #expect(rows.count == 1)
    #expect(rows.first?.followRedirects == true)
  }

  @Test("Moving one endpoint onto another's address is refused")
  func rejectsDuplicateURL() async throws {
    let server = try await makeInterface()
    _ = try await server.createWebhook(url: "https://a.example.com/hook", events: ["*"])
    let second = try await server.createWebhook(url: "https://b.example.com/hook", events: ["*"])
    let id = try #require(second.id)

    // `StoreError` since `BBAppStore` was split out; the wire response is unchanged and
    // `SplitModuleWireShapeTests` pins it.
    await #expect(throws: StoreError.self) {
      _ = try await server.updateWebhook(id: id, url: "https://a.example.com/hook", events: nil)
    }

    // And nothing moved.
    let listed = try await server.webhooks()
    #expect(listed.count == 2)
    #expect(listed[1].url == "https://b.example.com/hook")
  }

  @Test("Editing a webhook that is not there is a not-found, not a silent no-op")
  func rejectsMissingID() async throws {
    let server = try await makeInterface()
    await #expect(throws: StoreError.self) {
      _ = try await server.updateWebhook(id: 404, url: nil, events: ["new-message"])
    }
  }

  @Test("A non-HTTP URL is refused on edit as well as on create")
  func validatesURL() async throws {
    let server = try await makeInterface()
    let created = try await server.createWebhook(url: "https://example.com/hook", events: ["*"])
    let id = try #require(created.id)

    await #expect(throws: InterfaceError.self) {
      _ = try await server.updateWebhook(id: id, url: "ftp://example.com/hook", events: nil)
    }
  }
}
