//  MessageEventFixture
//  One `chat.db` copy, for the suites that drive `ChangeDetectionService.event`.
//
//  Extracted when a second suite needed the same thing, and specifically because of
//  `failing`. The builder gates `.messageSendError` on BOTH the changed-field set and a
//  non-zero `error` column, and no fixture row has one — so a test that passes `[.error]`
//  and nothing else gets an ordinary `.updatedMessage` back. Every assertion that is also
//  true of an update then passes, and the suite looks like it covers a branch it has never
//  reached. That is exactly what `NotificationPriorityTests.sendErrorIsNormal` did: it
//  asserted `.normal`, which an update is too.
//
//  So the error is written HERE rather than left to each caller to remember, and the callers
//  say `failing: true` where they mean it.
//
//  Written on the throwaway copy before the read-only handle opens: `chat.db` itself is never
//  touched, and the rule about never writing to it is not bent.

import BBIMessage
import BBPersistence
import BBSerialization
import BBTestSupport
import Foundation
import GRDB

struct MessageEventFixture {
  let repository: MessageRepository
  let serializer: MessageSerializer

  /// - Parameters:
  ///   - failing: sets `error = 1` on `guid`, which is the only way to reach the
  ///     `.messageSendError` branch. Requires `guid`.
  ///   - release: which committed fixture. Sequoia for anything that needs its columns: the
  ///     Send Later operations refuse on a database without `schedule_state`.
  ///   - balloon: turns a row into an iMessage-app balloon, writing its bundle id and its
  ///     archived payload, for the suites that ask what an app message's event carries.
  ///   - groupChange: turns a row into a group change the way Messages writes one: no text,
  ///     no attributed body, and the `item_type` / `group_action_type` pair, with a
  ///     `group_title` for a rename.
  init(
    failing guid: String? = nil, release: CommittedChatDB.Release = .sonoma,
    balloon: (guid: String, bundleID: String, payload: Data)? = nil,
    groupChange: GroupChange? = nil
  ) async throws {
    let path = try CommittedChatDB.copy(release)

    if let groupChange {
      let queue = try DatabaseQueue(path: path.path)
      try await queue.write { db in
        try db.execute(
          sql: """
            UPDATE message SET text = NULL, attributedBody = NULL, item_type = ?,
              group_action_type = ?, group_title = ?
            WHERE guid = ?
            """,
          arguments: [
            groupChange.itemType, groupChange.groupActionType, groupChange.title,
            groupChange.guid,
          ])
      }
    }

    if guid != nil || balloon != nil {
      let queue = try DatabaseQueue(path: path.path)
      try await queue.write { db in
        if let guid {
          try db.execute(sql: "UPDATE message SET error = 1 WHERE guid = ?", arguments: [guid])
        }
        if let balloon {
          try db.execute(
            sql: "UPDATE message SET balloon_bundle_id = ?, payload_data = ? WHERE guid = ?",
            arguments: [balloon.bundleID, balloon.payload, balloon.guid])
        }
      }
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    repository = MessageRepository(database: database, profile: profile)
    serializer = MessageSerializer(profile: profile)
  }

  /// What `groupChange:` writes over a row.
  struct GroupChange {
    var guid: String = MessageEventFixture.groupIncomingGUID
    var itemType: Int
    var groupActionType: Int
    var title: String? = nil
  }

  /// A message somebody else sent to the fixture's GROUP chat, which has two participants.
  static let groupIncomingGUID = "11111111-0000-0000-0000-000000000004"

  /// A message somebody else sent, in the fixture.
  static let incomingGUID = "11111111-0000-0000-0000-000000000001"
  /// One the account sent itself.
  static let outgoingGUID = "11111111-0000-0000-0000-000000000002"
}
