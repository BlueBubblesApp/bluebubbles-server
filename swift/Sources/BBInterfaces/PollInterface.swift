//  PollInterface
//  Polls: assembling one from its message thread, creating one, voting on one.
//
//  `docs/POLLS.md` is the reference. The read side is pure chat.db: the poll's root row, the
//  type-2 updates that point at it, and the type-4000 votes that point at whichever state
//  message was current when they were cast. The writes go through the helper. macOS 26 only.

import BBCapabilities
import BBIMessage
import BBPrivateAPIContract
import BBSerialization
import Foundation

extension MessageInterface {

  /// A poll assembled from its thread.
  public struct Poll: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
      public let id: String
      public let text: String
      public let creatorHandle: String?
      public let canBeEdited: Bool
    }
    public struct Vote: Sendable, Equatable {
      public let guid: String
      public let handle: String?
      public let optionIDs: [String]
      public let dateMilliseconds: Int64?
    }
    /// The root (type 3) message.
    public let guid: String
    public let title: String
    public let creatorHandle: String?
    public let sessionID: String?
    public let options: [Option]
    /// One entry per participant, their newest vote only.
    public let votes: [Vote]
    /// What a new vote must be associated with: the newest update, or the root.
    public let latestStateGUID: String
  }

  /// The poll behind a message GUID — the root, an update, or a vote all resolve to it.
  public func poll(guid: String) async throws -> Poll {
    try Self.checkPollsSupported()
    var row = try await requireMessage(guid)
    // Walk up to the root: a vote points at a state message, an update at the root.
    var hops = 0
    while row.associatedMessageType == 2 || row.associatedMessageType == 4000, hops < 8 {
      guard let parent = row.associatedMessageTarget?.guid ?? row.associatedMessageGUID,
        let above = try await repository.message(guid: parent)
      else { break }
      row = above
      hops += 1
    }
    guard row.balloonBundleID == PollsApp.balloonBundleID,
      let rootEnvelope = PollPayload.envelope(from: row.payloadData)
    else {
      throw InterfaceError.invalidRequest("\(guid) is not a poll")
    }

    // The thread: everything pointing at the root, then everything pointing at those
    // updates — votes chain to the newest state, not the root.
    let firstLevel = try await repository.messages(associatedWith: [row.guid])
    let updates = firstLevel.filter { $0.associatedMessageType == 2 }
    var thread = firstLevel
    if !updates.isEmpty {
      thread += try await repository.messages(associatedWith: updates.map(\.guid))
    }

    let latestUpdate = updates.max { ($0.date?.rawValue ?? 0) < ($1.date?.rawValue ?? 0) }
    let stateRow = latestUpdate ?? row
    let envelope = PollPayload.envelope(from: stateRow.payloadData) ?? rootEnvelope
    let definition = try JSONDecoder().decode(PollPayload.Definition.self, from: envelope.json)

    let own = try await repository.ownAddress()
    var newest: [String: Poll.Vote] = [:]
    for vote in thread where vote.associatedMessageType == 4000 {
      guard let voteEnvelope = PollPayload.envelope(from: vote.payloadData),
        let decoded = try? JSONDecoder().decode(PollPayload.Votes.self, from: voteEnvelope.json)
      else { continue }
      var handle: String? = vote.isFromMe ? own : decoded.item.votes.first?.participantHandle
      if handle == nil, let rowID = vote.handleID {
        handle = try await repository.handle(rowID: rowID)?.id
      }
      let key = handle ?? vote.guid
      let entry = Poll.Vote(
        guid: vote.guid, handle: handle,
        optionIDs: decoded.item.votes.map(\.voteOptionIdentifier),
        dateMilliseconds: vote.date?.epochMilliseconds)
      if let existing = newest[key],
        (existing.dateMilliseconds ?? 0) > (entry.dateMilliseconds ?? 0)
      {
        continue
      }
      newest[key] = entry
    }

    return Poll(
      guid: row.guid,
      title: definition.item.title ?? "",
      creatorHandle: definition.item.creatorHandle,
      sessionID: envelope.sessionID ?? rootEnvelope.sessionID,
      options: definition.item.orderedPollOptions.map {
        Poll.Option(
          id: $0.optionIdentifier, text: $0.text, creatorHandle: $0.creatorHandle,
          canBeEdited: $0.canBeEdited ?? false)
      },
      votes: newest.values.sorted { ($0.dateMilliseconds ?? 0) < ($1.dateMilliseconds ?? 0) },
      latestStateGUID: stateRow.guid
    )
  }

  public func serialize(_ poll: Poll) -> JSONValue {
    .object([
      "guid": .string(poll.guid),
      "title": .string(poll.title),
      "creator_handle": poll.creatorHandle.map(JSONValue.string) ?? .null,
      "session_id": poll.sessionID.map(JSONValue.string) ?? .null,
      "latest_state_guid": .string(poll.latestStateGUID),
      "options": .array(
        poll.options.map {
          .object([
            "id": .string($0.id), "text": .string($0.text),
            "creator_handle": $0.creatorHandle.map(JSONValue.string) ?? .null,
            "can_be_edited": .bool($0.canBeEdited),
          ])
        }),
      "votes": .array(
        poll.votes.map {
          .object([
            "guid": .string($0.guid),
            "handle": $0.handle.map(JSONValue.string) ?? .null,
            "option_ids": .array($0.optionIDs.map(JSONValue.string)),
            "date": $0.dateMilliseconds.map(JSONValue.int64) ?? .null,
          ])
        }),
    ])
  }

  public func createPoll(chatGUID: String, title: String, options: [String]) async throws
    -> SendOutcome
  {
    try Self.checkPollsSupported()
    let api = try requirePrivateAPI(for: "polls")
    let trimmed = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard trimmed.count >= 2, trimmed.allSatisfy({ !$0.isEmpty }) else {
      throw InterfaceError.invalidRequest("a poll needs at least two non-empty options")
    }
    let sent = try await throughMessages {
      try await api.createPoll(
        PollCreateRequest(chat: ChatIdentifier(chatGUID), title: title, options: trimmed))
    }
    return SendOutcome(
      backend: .privateAPI, messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue))
  }

  /// Casts the local user's complete selection. `pollGUID` may be any message of the
  /// thread; the vote goes against the poll's latest state.
  public func votePoll(chatGUID: String, pollGUID: String, optionIDs: [String]) async throws
    -> SendOutcome
  {
    let api = try requirePrivateAPI(for: "polls")
    let poll = try await poll(guid: pollGUID)
    let known = Set(poll.options.map(\.id))
    for id in optionIDs where !known.contains(id) {
      throw InterfaceError.invalidRequest("option \(id) is not on this poll")
    }
    guard let sessionID = poll.sessionID else {
      throw InterfaceError.invalidRequest(
        "this poll carries no session id, so it cannot be voted on")
    }
    let sent = try await throughMessages {
      try await api.votePoll(
        PollVoteRequest(
          chat: ChatIdentifier(chatGUID), stateGUID: MessageGUID(poll.latestStateGUID),
          sessionID: sessionID, optionIDs: optionIDs))
    }
    return SendOutcome(
      backend: .privateAPI, messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue))
  }

  /// Adds a choice: the poll re-sent in its new state, in its own session, which lands as a
  /// type-2 update the thread walk already follows. Anyone may add a choice to anyone's
  /// poll, so the new option is credited to this account while the rest keep theirs.
  public func addPollOption(chatGUID: String, pollGUID: String, text: String) async throws
    -> SendOutcome
  {
    let api = try requirePrivateAPI(for: "polls")
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw InterfaceError.invalidRequest("`text` is required") }
    let poll = try await poll(guid: pollGUID)
    guard let sessionID = poll.sessionID else {
      throw InterfaceError.invalidRequest(
        "this poll carries no session id, so it cannot be updated")
    }
    var options = poll.options.map {
      PollOptionSpec(
        id: $0.id, text: $0.text, creatorHandle: $0.creatorHandle, canBeEdited: $0.canBeEdited)
    }
    options.append(PollOptionSpec(id: UUID().uuidString, text: trimmed))
    let sent = try await throughMessages {
      try await api.updatePoll(
        PollUpdateRequest(
          chat: ChatIdentifier(chatGUID), rootGUID: MessageGUID(poll.guid),
          sessionID: sessionID, title: poll.title, creatorHandle: poll.creatorHandle,
          options: options))
    }
    return SendOutcome(
      backend: .privateAPI, messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue))
  }

  /// Polls arrived with macOS 26; the Polls extension does not exist below it.
  static func checkPollsSupported(
    majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  ) throws {
    guard majorVersion >= PrivateAPICapability.polls.minimumMacOS else {
      throw InterfaceError.invalidRequest("Polls are only supported on macOS 26 and newer")
    }
  }
}
