//  MessageMutationHydrationTests
//  `edit`, `unsend` and `notify` answer with the row AFTER it changed.
//
//  These four routes — `react` too — used to answer `data: null` where the reference answers
//  the serialised message. `react` is a send and hydrates like one; these three are not. They
//  MUTATE a row that already exists, so a wait for the row to appear would return instantly
//  with the message as it was BEFORE the edit — the pre-edit text, the un-notified flag —
//  which is worse than returning nothing, because a client would display it as the result.
//
//  So what is asserted here is the wait keying on the right column, against a real `chat.db`
//  that a second connection changes underneath it, exactly as Messages would.
//
//  The response SHAPE is `SendShapeTests`' job, and it covers all eight message-bearing
//  routes against their recorded fixtures.

import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Message mutation hydration", .serialized)
struct MessageMutationHydrationTests {

  /// A message the account sent, in the group chat, with no edit recorded against it.
  static let target = "11111111-0000-0000-0000-000000000007"

  /// A read-only interface over a copy of the fixture, plus the writable handle that plays
  /// the part of Messages.
  private struct Harness {
    let interface: MessageInterface
    let writer: DatabaseQueue
    let path: String

    /// What Messages does to a row when an edit or an unsend lands: `date_edited` moves.
    func recordEdit(at nanoseconds: Int64) throws {
      try writer.write { db in
        try db.execute(
          sql: "UPDATE message SET date_edited = ? WHERE guid = ?",
          arguments: [nanoseconds, MessageMutationHydrationTests.target])
      }
    }

    func recordNotified() throws {
      try writer.write { db in
        try db.execute(
          sql: "UPDATE message SET did_notify_recipient = 1 WHERE guid = ?",
          arguments: [MessageMutationHydrationTests.target])
      }
    }

    func tearDown() { try? FileManager.default.removeItem(atPath: path) }
  }

  private func harness(
    _ configure: (inout FailingPrivateAPI) -> Void
  ) async throws -> Harness {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-mutation-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    var api = FailingPrivateAPI()
    configure(&api)

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return Harness(
      interface: MessageInterface(
        repository: MessageRepository(database: database, profile: profile),
        serializer: MessageSerializer(profile: profile),
        privateAPI: api
      ),
      writer: try DatabaseQueue(path: path.path),
      path: path.path
    )
  }

  /// The fixture's rows are stamped in 2024; anything later than that reads as "after".
  private static let editedAt: Int64 = 800_000_000_000_000_000

  /// The write lands LATE, on purpose.
  ///
  /// A double that writes before returning would leave the polling loop untested — the first
  /// look would already see the new value, and a `mutated` that never looped again would pass.
  /// Messages does not work that way: it acknowledges the edit and writes the row afterwards,
  /// which is the entire reason this wait exists.
  @Test("An edit waits for dateEdited to move, and answers with the row once it has")
  func editWaitsForTheEditDate() async throws {
    // Captured before the harness exists, then filled in — the closure IS the moment
    // Messages accepts the edit, so it has to be able to reach the writer it stands in for.
    let box = Box()
    let harness = try await harness { api in
      api.onEdit = {
        Task.detached {
          try? await Task.sleep(for: .milliseconds(300))
          try? box.value?.recordEdit(at: Self.editedAt)
        }
      }
    }
    box.value = harness
    defer { harness.tearDown() }

    let outcome = try await harness.interface.edit(
      guid: Self.target, partIndex: 0, newText: "Sunday it is",
      backwardCompatibilityText: "Edited"
    )
    let row = try #require(
      outcome.message?.row,
      "the edit was accepted and the row changed; hydration should not have timed out"
    )
    #expect(row.guid == Self.target)
    // Not nil, which is what an unedited row carries — so a `mutated` that returned on the
    // first look, before Messages had written anything, fails here.
    #expect(row.dateEdited?.rawValue == Self.editedAt)
  }

  /// An unsend watches `dateEdited`, not `dateRetracted`. That looks like a bug and is not:
  /// Messages records an unsend as an edit that empties the part, so `date_edited` is the
  /// column that moves — watching `dateRetracted` would wait out the whole timeout on every
  /// successful unsend.
  @Test("An unsend waits on dateEdited, which is the column Messages moves")
  func unsendWaitsForTheEditDate() async throws {
    let box = Box()
    let harness = try await harness { api in
      api.onUnsend = { try box.value?.recordEdit(at: Self.editedAt) }
    }
    box.value = harness
    defer { harness.tearDown() }

    let outcome = try await harness.interface.unsend(guid: Self.target, partIndex: 0)
    #expect(try #require(outcome.message?.row).dateEdited?.rawValue == Self.editedAt)
  }

  @Test("A notify answers once didNotifyRecipient is set")
  func notifyWaitsForTheFlag() async throws {
    let box = Box()
    let harness = try await harness { api in
      api.onNotify = { try box.value?.recordNotified() }
    }
    box.value = harness
    defer { harness.tearDown() }

    let outcome = try await harness.interface.notify(guid: Self.target)
    #expect(try #require(outcome.message?.row).didNotifyRecipient == true)
  }

  /// The reference refuses before calling Messages, and the refusal matters: the flag is what
  /// the wait keys on, so a second notify would find it already true and answer instantly
  /// with a notification that never went out.
  @Test("Notifying an already-notified message is refused, not silently repeated")
  func notifyRefusesWhenAlreadyNotified() async throws {
    let box = Box()
    let harness = try await harness { api in
      api.onNotify = { try box.value?.recordNotified() }
    }
    box.value = harness
    defer { harness.tearDown() }
    try harness.recordNotified()

    await #expect(throws: InterfaceError.self) {
      _ = try await harness.interface.notify(guid: Self.target)
    }
  }

  /// A GUID that names nothing is a 400 "Selected message does not exist!", not a 404 and not
  /// whatever IMCore would have said — the reference checks the database first on all four of
  /// these routes.
  @Test("A message that does not exist is refused before Messages is reached")
  func unknownMessageIsRefusedEarly() async throws {
    let harness = try await harness { _ in }
    defer { harness.tearDown() }

    await #expect(throws: InterfaceError.self) {
      _ = try await harness.interface.notify(guid: "00000000-0000-0000-0000-00000000dead")
    }
    do {
      _ = try await harness.interface.notify(guid: "00000000-0000-0000-0000-00000000dead")
    } catch let error as InterfaceError {
      #expect(error.body == "Selected message does not exist!")
    }
  }

  /// Holds the harness so the helper double's closure can reach it. The closure has to be
  /// built before the harness it writes to exists, because the harness owns the double.
  private final class Box: @unchecked Sendable {
    var value: Harness?
  }
}
