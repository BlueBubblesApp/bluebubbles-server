//  WebhookRegistrationStreamTests
//  The webhook table can be followed, whichever path writes it.
//
//  The API & Webhooks page re-read the table on a timer so an endpoint registered by a
//  client over HTTP would appear. GRDB re-runs the read after every commit to the table, so
//  the page follows it instead; this pins that an upsert and a delete each reach a follower,
//  and that the first element is the table as it stands.

import BBPersistence
import Testing

@testable import BBInterfaces

@Suite("Webhook registration stream")
struct WebhookRegistrationStreamTests {

  @Test("The first element is the current table; an upsert and a delete each yield the next")
  func writesReachFollowers() async throws {
    let database = try AppDatabase.inMemory(contributors: [InterfacesSchema.self])
    let repository = WebhookRepository(database: database)
    var iterator = repository.changes().makeAsyncIterator()

    let initial = try await iterator.next()
    #expect(initial?.isEmpty == true)

    let stored = try await repository.upsert(url: "https://example.com/hook", events: ["*"])
    let afterUpsert = try await iterator.next()
    #expect(afterUpsert?.map(\.url) == ["https://example.com/hook"])

    try await repository.delete(id: try #require(stored.id))
    let afterDelete = try await iterator.next()
    #expect(afterDelete?.isEmpty == true)
  }
}
