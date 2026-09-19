//  PollFailureTests
//  What a client receives when Messages refuses a poll operation.
//
//  The last of the exhaustive walks. Same contract as its four siblings: a refusal from
//  Messages is `InterfaceError.messagesFailed`, projecting to the 500 `iMessage Error`.
//
//  **Two things had to move before this file could exist, and only one of them was the one
//  I predicted.** The declared reason polls were uncovered was `checkPollsSupported()`
//  reading `ProcessInfo` — true, and now fixed by `MessageInterface.osMajorVersion`, so this
//  suite proves the same thing on a Tahoe host and a Sonoma runner. The reason I had NOT
//  predicted is that two of the three never touch that gate directly: `votePoll` and
//  `addPollOption` go through `poll(guid:)`, which resolves a real poll out of `chat.db` —
//  a balloon row with a decodable `payload_data` archive, and a thread walk over the rows
//  associated with it. No fixture had one, so both would have failed on `.invalidRequest`
//  before reaching Messages, and a walk that did not seed one would have asserted a
//  translation that never ran.
//
//  That is the third time in this set of walks that the obstacle was a path never entered
//  rather than the thing the note said: the empty profile hid nine message operations, the
//  interval gate could have hidden two FindMy ones, and a missing poll row would have hidden
//  two here.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBHTTPAPI
import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Poll failure translation")
struct PollFailureTests {

  private static let chat = "iMessage;-;+12025550143"
  private static let pollGUID = "11111111-0000-0000-0000-0000000P0LL"
  /// Polls arrived with macOS 26; below it the extension does not exist.
  private static let tahoe = 26

  /// A `chat.db` copy carrying one real poll.
  ///
  /// Seeded through GRDB on the throwaway copy before the read-only handle opens, the same
  /// way `MessageEventFixture` writes an error column. The payload is built exactly as
  /// `PollPayloadTests` builds one — a keyed archive of a dictionary holding an `NSURL`
  /// whose data: body is the base64 JSON, a name, and a session `NSUUID` — because that is
  /// what `MSMessage` actually writes and the decoder under test is the real one.
  private func interface(osMajorVersion: Int = tahoe) async throws -> MessageInterface {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-pollfail-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO message (guid, text, handle_id, service, date, is_from_me,
            balloon_bundle_id, payload_data)
          VALUES (?, ?, 0, 'iMessage', 0, 1, ?, ?)
          """,
        arguments: [
          Self.pollGUID, "Dinner?", PollsApp.balloonBundleID, Self.payload(),
        ])
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return MessageInterface(
      repository: MessageRepository(database: database, profile: profile),
      serializer: MessageSerializer(profile: profile),
      privateAPI: FailingPrivateAPI(),
      osMajorVersion: osMajorVersion
    )
  }

  private static func payload() throws -> Data {
    let json = #"""
      {"version":1,"item":{"title":"Dinner?","creatorHandle":"me@example.com",
      "orderedPollOptions":[{"optionIdentifier":"A","text":"Pizza","canBeEdited":true},
      {"optionIdentifier":"B","text":"Tacos","canBeEdited":true}]}}
      """#
    let body = Data(json.utf8).base64EncodedString()
    let dictionary: NSDictionary = [
      "URL": NSURL(string: "data:," + body)!,
      "an": PollsApp.appName,
      "sessionIdentifier": UUID() as NSUUID,
    ]
    return try NSKeyedArchiver.archivedData(
      withRootObject: dictionary, requiringSecureCoding: true)
  }

  /// Every poll operation that reaches Messages, by name.
  private func operations(
    _ message: MessageInterface
  ) -> [(String, () async throws -> Void)] {
    [
      (
        "createPoll",
        {
          _ = try await message.createPoll(
            chatGUID: Self.chat, title: "Dinner?", options: ["Pizza", "Tacos"])
        }
      ),
      (
        "votePoll",
        {
          _ = try await message.votePoll(
            chatGUID: Self.chat, pollGUID: Self.pollGUID, optionIDs: ["A"])
        }
      ),
      (
        "addPollOption",
        {
          _ = try await message.addPollOption(
            chatGUID: Self.chat, pollGUID: Self.pollGUID, text: "Sushi")
        }
      ),
    ]
  }

  @Test("Every poll operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let message = try await interface()

    for (name, operation) in operations(message) {
      do {
        try await operation()
        Issue.record("\(name) should have failed")
      } catch let error as InterfaceError {
        #expect(error == .messagesFailed("Messages said no"), "\(name)")
      } catch {
        Issue.record("\(name) threw \(type(of: error)) rather than InterfaceError: \(error)")
      }
    }
  }

  @Test("A refused poll renders as 500 with the iMessage error type")
  func rendersWithTheDocumentedShape() async throws {
    let message = try await interface()

    do {
      _ = try await message.createPoll(
        chatGUID: Self.chat, title: "Dinner?", options: ["Pizza", "Tacos"])
      Issue.record("the poll should have failed")
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: .init(label: "test"))
      #expect(status == 500)
      #expect(envelope.error?.type == .iMessageError)
    }
  }

  // MARK: - The version gate

  @Test(
    "Below macOS 26 every poll operation refuses, whatever Mac runs the test",
    arguments: ["createPoll", "votePoll", "addPollOption"])
  func belowTahoeIsRefused(operation: String) async throws {
    // The half that needed `osMajorVersion` to be injectable at all. This asserted nothing
    // before: on this Tahoe host the gate always opened, so the documented refusal below
    // macOS 26 was unreachable, and on a Sonoma runner the walk above would have failed
    // instead. Both answers are now reachable from either machine.
    let message = try await interface(osMajorVersion: 15)

    do {
      switch operation {
      case "createPoll":
        _ = try await message.createPoll(
          chatGUID: Self.chat, title: "Dinner?", options: ["Pizza", "Tacos"])
      case "votePoll":
        _ = try await message.votePoll(
          chatGUID: Self.chat, pollGUID: Self.pollGUID, optionIDs: ["A"])
      default:
        _ = try await message.addPollOption(
          chatGUID: Self.chat, pollGUID: Self.pollGUID, text: "Sushi")
      }
      Issue.record("\(operation) should have been refused below macOS 26")
    } catch let error as InterfaceError {
      guard case .invalidRequest(let detail) = error else {
        Issue.record("expected .invalidRequest, got \(error)")
        return
      }
      #expect(detail.contains("macOS 26"))
    }
  }

  // MARK: - What must NOT be translated

  @Test("A poll with one option stays a 400")
  func validationKeepsIts400() async throws {
    let message = try await interface()

    do {
      _ = try await message.createPoll(chatGUID: Self.chat, title: "?", options: ["Only"])
      Issue.record("a one-option poll should have been rejected")
    } catch let error as InterfaceError {
      guard case .invalidRequest = error else {
        Issue.record("expected .invalidRequest, got \(error)")
        return
      }
    }
  }
}
