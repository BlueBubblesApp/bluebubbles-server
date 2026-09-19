//  HandleQueryFilterTests
//  `POST /handle/query` honours `address` and `with`.
//
//  Both were accepted and dropped. The Flutter client posts `{with, address, offset, limit}`
//  (`handle_api.dart`), so an app asking for one correspondent's handle and the chats it
//  belongs to received an unfiltered page of a thousand handles with no chats on any of them,
//  and a `total` describing the whole table.
//
//  The `chats` relation is asserted as nil-vs-present rather than by count alone, because that
//  distinction is the wire format: `HandleProjection` carries nil when the caller did not ask,
//  and the serializer omits the key entirely in that case where it emits `[]` for a handle
//  that genuinely belongs to no chat.
//
//  Run against the committed `chat.db` fixture, and the address to filter on is DISCOVERED
//  from it rather than written here: a test that hard-codes fixture contents fails for the
//  wrong reason the day the fixture is regenerated.

import BBIMessage
import BBPersistence
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Handle query filters")
struct HandleQueryFilterTests {

  private struct Harness {
    let handles: HandleInterface
    /// Held for the lifetime of the test; see `ChatFixtureCopy`.
    let writer: Any
  }

  private func makeHarness(testFile: StaticString = #filePath) async throws -> Harness {
    let (path, writer) = try ChatFixtureCopy.make(testFile: testFile)
    let database = try ReadOnlyDatabase(path: path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return Harness(
      handles: HandleInterface(
        repository: MessageRepository(database: database, profile: profile)),
      writer: writer
    )
  }

  @Test("no address lists the page, with no chats loaded")
  func unfiltered() async throws {
    let harness = try await makeHarness()
    let page = try await harness.handles.query()
    #expect(!page.isEmpty)
    #expect(page.count == (try await harness.handles.count(address: nil)))
    // Not asked for, so ABSENT rather than empty: the two are different keys on the wire.
    #expect(page.allSatisfy { $0.chats == nil })
  }

  @Test("an address narrows the page and the total together")
  func addressFilter() async throws {
    let harness = try await makeHarness()
    let everyone = try await harness.handles.query()
    let target = try #require(everyone.first?.row.id)

    let page = try await harness.handles.query(address: target)
    #expect(page.map(\.row.id) == [target])
    // The total has to agree with the page, for the reason `/message/query`'s does: a
    // client pages against it. Before this, it reported the whole table.
    #expect(try await harness.handles.count(address: target) == 1)
    #expect(everyone.count > 1, "the fixture needs more than one handle to prove filtering")
  }

  @Test("an address nobody has is empty, not the whole table")
  func unknownAddress() async throws {
    let harness = try await makeHarness()
    // Reserved range, so it can never collide with fixture data.
    let page = try await harness.handles.query(address: "+15555550199")
    #expect(page.isEmpty)
    #expect(try await harness.handles.count(address: "+15555550199") == 0)
  }

  @Test("with: chats loads them, filtered and unfiltered alike")
  func withChats() async throws {
    let harness = try await makeHarness()
    let all = try await harness.handles.query(withChats: true)
    #expect(all.allSatisfy { $0.chats != nil })

    let target = try #require(all.first?.row.id)
    let filtered = try await harness.handles.query(address: target, withChats: true)
    #expect(filtered.first?.chats != nil)
  }

  @Test("paging past a filtered single result is empty, not a fallback to the list")
  func offsetPastTheMatch() async throws {
    let harness = try await makeHarness()
    let target = try #require(try await harness.handles.query().first?.row.id)
    // Answering the unfiltered list here would be the same class of bug as ignoring the
    // filter outright.
    #expect(try await harness.handles.query(offset: 1, address: target).isEmpty)
  }
}
