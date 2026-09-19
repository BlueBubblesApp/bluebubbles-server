//  BBPrivateAPIContract: Polls
//  Creating, updating and voting in a poll, and the app-message payload underneath it.
//
//  A poll is not a message kind. It is an iMessage app balloon, so `SendAppMessageRequest`
//  is the mechanism and the poll types are one use of it. Both are here because that use is
// the only one; a second app would move the generic payload out rather than
//  copying it.
//
//  See `docs/POLLS.md` for the wire format and what it costs to get wrong.

import Foundation

/// The Polls iMessage app, which is what a poll IS on the wire; see `docs/POLLS.md`.
public enum PollsApp {
  /// The extension's own bundle identifier, and the `appExtensionIdentifier` ChatKit takes.
  public static let extensionIdentifier = "com.apple.messages.Polls"
  /// `balloon_bundle_id` on every poll and vote row. `0000000000` is the team-id slot,
  /// which is literally that for Apple's own extensions.
  public static let balloonBundleID =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls"
  public static let appName = "Polls"
}

public struct PollCreateRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  public let title: String
  /// In order. The helper mints each option's identifier.
  public let options: [String]

  public init(chat: ChatIdentifier, title: String, options: [String]) {
    self.chat = chat
    self.title = title
    self.options = options
  }
}

/// One option as the poll JSON carries it. `creatorHandle` nil means "this account", which
/// the helper fills in; the server does not know the login handle as reliably as IMCore.
public struct PollOptionSpec: Codable, Sendable, Equatable {
  public let id: String
  public let text: String
  public let creatorHandle: String?
  public let canBeEdited: Bool

  public init(id: String, text: String, creatorHandle: String? = nil, canBeEdited: Bool = false) {
    self.id = id
    self.text = text
    self.creatorHandle = creatorHandle
    self.canBeEdited = canBeEdited
  }
}

/// The poll re-sent in a new state: how a choice is added. Same session as the poll, the
/// COMPLETE option list (existing ones with their identifiers, new ones with fresh ones),
/// and the root's own creator; lands as an `associated_message_type` 2 update.
public struct PollUpdateRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  /// The poll's ROOT message. Naming it on the plugin payload is what makes ChatKit file
  /// the send as an update (`IMPluginPayload.isUpdate`) rather than a new poll; the
  /// session alone does not; measured, a same-session send landed as a second poll.
  public let rootGUID: MessageGUID
  public let sessionID: String
  public let title: String
  public let creatorHandle: String?
  public let options: [PollOptionSpec]

  public init(
    chat: ChatIdentifier, rootGUID: MessageGUID, sessionID: String, title: String,
    creatorHandle: String?, options: [PollOptionSpec]
  ) {
    self.chat = chat
    self.rootGUID = rootGUID
    self.sessionID = sessionID
    self.title = title
    self.creatorHandle = creatorHandle
    self.options = options
  }
}

/// One participant's COMPLETE selection on a poll, not a delta. Empty retracts every vote.
public struct PollVoteRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  /// The poll's LATEST state message (the newest type-2 update, or the type-3 root), which
  /// is what a vote is associated with. The server resolves it from the thread.
  public let stateGUID: MessageGUID
  /// The `MSSession` identifier every message of the poll shares, as a UUID string.
  public let sessionID: String
  public let optionIDs: [String]

  public init(chat: ChatIdentifier, stateGUID: MessageGUID, sessionID: String, optionIDs: [String])
  {
    self.chat = chat
    self.stateGUID = stateGUID
    self.sessionID = sessionID
    self.optionIDs = optionIDs
  }
}

// MARK: - The app-message payload a poll is sent as

/// An iMessage-app message: a balloon another app renders. Polls and Game Pigeon are both
/// this; so is anything else with an iMessage extension. The server builds the payload (it
/// is a keyed archive of Foundation types) and the helper only has to attach it to a
/// message, which is why this carries bytes rather than a model.
public struct SendAppMessageRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  /// The full `balloon_bundle_id`, including the
  /// `com.apple.messages.MSMessageExtensionBalloonPlugin:<team>:` prefix.
  public let balloonBundleID: String
  /// The archived `MSMessage` payload.
  public let payload: Data
  /// What the message reads as where the balloon cannot be drawn.
  public let summary: String?

  public init(
    chat: ChatIdentifier, balloonBundleID: String, payload: Data, summary: String? = nil
  ) {
    self.chat = chat
    self.balloonBundleID = balloonBundleID
    self.payload = payload
    self.summary = summary
  }
}
