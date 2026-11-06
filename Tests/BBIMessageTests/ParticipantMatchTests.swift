//  ParticipantMatchTests
//  Finding a chat by who is in it costs two reads, however many chats are candidates.
//
//  `chats(matchingParticipants:)` is what the Shortcut group-creation path polls every 500 ms
//  for up to 30 seconds. It read the candidates and then each candidate's participants one
//  query at a time, and for a single address the candidates are every one-to-one chat on the
//  Mac: hundreds of reads per poll, every one through the single `DatabaseQueue` the change
//  detector also waits on. The answers were right and the fixture is small, so only counting
//  statements can see it.

import BBCore
import BBPersistence
import Foundation
import Testing

@testable import BBIMessage

@Suite("Chats by participant set")
struct ParticipantMatchTests {

  /// Every SELECT the repository runs.
  private final class StatementLog: Sendable {
    private let statements = Locked<[String]>([])
    func record(_ sql: String) { statements.withLock { $0.append(sql) } }
    func reset() { statements.withLock { $0.removeAll() } }
    var selects: Int {
      statements.withLock { $0.filter(Self.isSelect).count }
    }
    private static func isSelect(_ sql: String) -> Bool {
      sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT")
    }
  }

  private func open(
    _ fixture: ChatDatabaseFixture
  ) async throws -> (MessageRepository, StatementLog) {
    let log = StatementLog()
    let database = try ReadOnlyDatabase(
      path: fixture.path, observingStatements: { [log] in log.record($0) })
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return (MessageRepository(database: database, profile: profile), log)
  }

  @Test("The participant check is one read, not one per candidate chat")
  func participantsAreReadInBulk() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    // More one-to-one chats, so a per-candidate read would show as a larger count. Handles
    // 1 to 4 exist in the seed; each of these is a distinct candidate with one participant.
    for (index, handle) in [2, 3, 4].enumerated() {
      try await fixture.insertChat(guid: "any;-;extra\(index)@example.com", participant: handle)
    }
    let (repository, log) = try await open(fixture)

    log.reset()
    let found = try await repository.chats(
      matchingParticipants: [ChatDatabaseFixture.aliceAddress], normalize: { $0 })

    #expect(found.map(\.rowID) == [1])
    // The candidate query and the bulk participant query. The seed has three one-to-one
    // chats and this test adds three more: a read per candidate would be seven.
    #expect(log.selects == 2, "ran \(log.selects) SELECTs for six candidate chats")
  }

  @Test("A group is found by its exact set, in any order, and not by a subset")
  func matchesTheExactSet() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let (repository, _) = try await open(fixture)

    let group = try await repository.chats(
      matchingParticipants: [ChatDatabaseFixture.bobAddress, ChatDatabaseFixture.aliceAddress],
      normalize: { $0 })
    #expect(group.map(\.rowID) == [2])

    let nobody = try await repository.chats(
      matchingParticipants: [ChatDatabaseFixture.aliceAddress, ChatDatabaseFixture.carolAddress],
      normalize: { $0 })
    #expect(nobody.isEmpty)
  }

  @Test("Each candidate is judged by its own members, not by its prefix twin's")
  func prefixTwinsKeepTheirOwnMembers() async throws {
    // Two rows whose GUIDs differ only in the service prefix, with different members. A
    // lookup by GUID matches both rows for either one (rule 3), so each reported the union
    // and neither matched a single address. By ROWID, each is itself.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let twin = try await fixture.insertChat(
      guid: ChatDatabaseFixture.chatGUID(ChatDatabaseFixture.aliceAddress, service: "SMS"),
      participant: 3)
    let (repository, _) = try await open(fixture)

    let alice = try await repository.chats(
      matchingParticipants: [ChatDatabaseFixture.aliceAddress], normalize: { $0 })
    #expect(alice.map(\.rowID) == [1])

    let carol = try await repository.chats(
      matchingParticipants: [ChatDatabaseFixture.carolAddress], normalize: { $0 })
    #expect(carol.map(\.rowID) == [twin, 3])
  }
}
