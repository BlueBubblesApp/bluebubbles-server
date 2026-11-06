//  FaceTimeBridge+Members
//  Who is in a conversation and who is waiting to be let in: admitting a member, reading the
//  roster against the active-participant sets the hand-off turns on, and the raw-state dump
//  that diagnoses a lobby the properties do not reveal.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FaceTimeBridge {

  // MARK: - Members

  static func admit(conversationUUID: String, handle: String) async throws {
    let client = try await ensureClient()
    // The member object may live in the active conversation OR in the incoming-pending
    // map; the conversation passed to `approvePendingMember:forConversation:` must be the
    // one the member came from.
    let candidates = [
      conversation(withGroupUUID: conversationUUID, on: client),
      incomingPendingConversation(withGroupUUID: conversationUUID, on: client),
    ].compactMap { $0 }

    for conversation in candidates {
      guard let member = anyMember(handle: handle, in: conversation) else { continue }
      try IMCoreRuntime.invoke(
        client, "approvePendingMember:forConversation:", [member, conversation]
      )
      return
    }
    throw PrivateAPIError.rejectedByMessages(
      reason: "\(handle) is not waiting in \(conversationUUID)"
    )
  }

  /// Finds a member by handle across BOTH `pendingMembers` and `remoteMembers`: a
  /// link-joiner awaiting admission shows up in the latter.
  private static func anyMember(handle: String, in conversation: AnyObject) -> AnyObject? {
    roster(of: conversation).first { member in
      memberHandleValue(member.object)?.caseInsensitiveCompare(handle) == .orderedSame
    }?.object
  }

  /// Every member associated with a conversation, tagged with which collection it came from.
  ///
  /// `lightweightMembers` is where a browser joining by LINK lives; it is NOT a subset of
  /// `remoteMembers`, and admitting one means finding it here.
  private static func roster(of conversation: AnyObject) -> [(
    object: AnyObject, declaredPending: Bool
  )] {
    func read(_ selector: String) -> [AnyObject] {
      (try? IMCoreRuntime.send(conversation, selector)).map(collection) ?? []
    }
    return read("pendingMembers").map { ($0, true) }
      + read("remoteMembers").map { ($0, false) }
      + read("lightweightMembers").map { ($0, false) }
  }

  /// Handles of the people ACTUALLY CONNECTED right now, or nil if this OS exposes neither
  /// active-participant set.
  ///
  /// This is the distinction the hand-off turns on, and missing it is what killed three live
  /// calls. `remoteMembers`/`lightweightMembers` are the conversation's ROSTER: a browser
  /// lands there the instant it opens the link, while still showing "Waiting to be let in…".
  /// `activeRemoteParticipants`/`activeLightweightParticipants` are who is really in. Reading
  /// roster membership as "joined" made the Mac hand off to somebody who had never been
  /// admitted, and the call died the moment the Mac left.
  ///
  /// Returns nil (rather than an empty set) when neither selector resolves, so the caller
  /// can tell "nobody is connected" from "this OS won't say", and fall back instead of
  /// declaring the whole call empty.
  private static func activeParticipantHandles(of conversation: AnyObject) -> Set<String>? {
    var resolved = false
    var values: Set<String> = []
    for selector in ["activeRemoteParticipants", "activeLightweightParticipants"] {
      guard let raw = try? IMCoreRuntime.send(conversation, selector) else { continue }
      resolved = true
      for participant in collection(raw) {
        // An element is a TUHandle, a TUConversationMember, or a participant wrapping
        // one; take whichever spelling answers.
        let direct = ((try? IMCoreRuntime.string(participant, "value")) ?? nil)
        let nested = (try? IMCoreRuntime.send(participant, "handle"))
          .flatMap { ((try? IMCoreRuntime.string($0, "value")) ?? nil) }
        if let value = (direct ?? nested), !value.isEmpty {
          values.insert(value.lowercased())
        }
      }
    }
    return resolved ? values : nil
  }

  static func members(conversationUUID: String) async throws -> [FaceTimeMember] {
    let client = try await ensureClient()
    var decoded: [FaceTimeMember] = []

    if let conversation = conversation(withGroupUUID: conversationUUID, on: client) {
      decoded += decodeMembers(of: conversation)
    }
    // The LOBBY lives here, not in `conversation.pendingMembers`. The daemon calls
    // `updateIncomingPendingConversationsByGroupUUID:` on the client directly, so this is
    // populated even though no delegate is installed.
    if let waiting = incomingPendingConversation(withGroupUUID: conversationUUID, on: client) {
      decoded += decodeMembers(of: waiting, forcePending: true)
    }

    // De-duplicate by handle. A member can appear in several collections at once; the
    // active-participant sets are the authority, so an "in the call" reading wins over a
    // roster entry that merely lists them.
    var byHandle: [String: FaceTimeMember] = [:]
    for member in decoded {
      let key = member.handle.value.lowercased()
      if let existing = byHandle[key], existing.isActive, !member.isActive { continue }
      byHandle[key] = member
    }
    return Array(byHandle.values)
  }

  /// The conversation as it appears in the daemon's INCOMING PENDING map: people
  /// knocking on this link who have not been let in.
  private static func incomingPendingConversation(
    withGroupUUID uuid: String,
    on client: AnyObject
  ) -> AnyObject? {
    guard
      let map = (try? IMCoreRuntime.send(client, "incomingPendingConversationsByGroupUUID"))
        as? [AnyHashable: AnyObject]
    else { return nil }
    for (key, conversation) in map {
      let keyString =
        (key as? NSUUID)?.uuidString
        ?? ((try? IMCoreRuntime.send(conversation, "groupUUID"))
          .flatMap { try? IMCoreRuntime.string($0, "UUIDString") ?? nil })
      if keyString?.caseInsensitiveCompare(uuid) == .orderedSame { return conversation }
    }
    return nil
  }

  /// Raw TelephonyUtilities state for one conversation, as strings.
  ///
  /// Exists because the lobby state could not be located by reading the properties the
  /// headers suggest: a link-joiner stuck at "Waiting to be let in…" reported
  /// `joinedFromLetMeIn = true` and appeared in `remoteMembers`, so every derived flag read
  /// "already in". Rather than guess again, this dumps what the objects actually say and the
  /// answer gets read off a live call.
  static func debugState(conversationUUID: String) async throws -> [String: String] {
    let client = try await ensureClient()
    var out: [String: String] = [:]

    let byGroup = (try? IMCoreRuntime.send(client, "conversationsByGroupUUID"))
    out["conversationsByGroupUUID"] = byGroup.map { String(describing: $0) } ?? "nil"
    let pendingMap = (try? IMCoreRuntime.send(client, "incomingPendingConversationsByGroupUUID"))
    out["incomingPendingConversationsByGroupUUID"] =
      pendingMap.map { String(describing: $0) } ?? "nil"

    // Link sources, so a link that cannot be invalidated can be explained rather than
    // reported as "nothing to do".
    out["activatedConversationLinks"] =
      (try? IMCoreRuntime.send(client, "activatedConversationLinks"))
      .map { String(describing: $0) } ?? "nil"
    let activeLinks = await callAwaitingCompletion(
      client, "getActiveLinksWithCreatedOnly:completionHandler:",
      leading: [NSNumber(value: false)], shape: .object)
    out["getActiveLinks(createdOnly:false)"] =
      activeLinks.object.map { String(describing: $0) } ?? "nil"

    if let conversation = conversation(withGroupUUID: conversationUUID, on: client) {
      out["conversation"] = String(describing: conversation)
      // The active-participant sets are the ones the hand-off decision rests on. If a
      // selector does not resolve here, `activeParticipantHandles` returns nil and
      // presence silently falls back to roster membership: the original bug. Dumped
      // so that is verifiable rather than assumed.
      for (label, selector) in [
        ("pendingMembers", "pendingMembers"),
        ("remoteMembers", "remoteMembers"),
        ("lightweightMembers", "lightweightMembers"),
        ("activeRemoteParticipants", "activeRemoteParticipants"),
        (
          "activeLightweightParticipants",
          "activeLightweightParticipants"
        ),
        ("localMember", "localMember"),
      ] {
        let value = (try? IMCoreRuntime.send(conversation, selector))
        out[label] = value.map { String(describing: $0) } ?? "nil"
      }
    } else {
      out["conversation"] = "NOT FOUND for \(conversationUUID)"
    }
    return out
  }

  // MARK: - Reading conversations/members

  /// The active conversations keyed by group UUID.
  ///
  /// Read from `conversationsByGroupUUID` on the XPC client, NOT `activeConversations`,
  /// which is a `TUConversationManager` accessor and is absent on the XPC client (verified
  /// against the runtime; the ObjC helper's ktool header put it on the wrong class). The
  /// dictionary is only populated once the client has fetched initial state, which is the
  /// whole reason `ensureClient()` awaits that before any read.
  private static func conversationsByGroupUUID(on client: AnyObject) -> [AnyHashable: AnyObject] {
    ((try? IMCoreRuntime.send(client, "conversationsByGroupUUID")) as? [AnyHashable: AnyObject])
      ?? [:]
  }

  private static func conversation(withGroupUUID uuid: String, on client: AnyObject) -> AnyObject? {
    let byGroup = conversationsByGroupUUID(on: client)
    // The keys are NSUUIDs; match case-insensitively on the string form so a caller can
    // pass either casing.
    for (key, conversation) in byGroup {
      let keyString =
        (key as? NSUUID)?.uuidString
        ?? ((try? IMCoreRuntime.send(conversation, "groupUUID"))
          .flatMap { try? IMCoreRuntime.string($0, "UUIDString") ?? nil })
      if keyString?.caseInsensitiveCompare(uuid) == .orderedSame { return conversation }
    }
    return nil
  }

  private static func decodeMembers(
    of conversation: AnyObject,
    forcePending: Bool = false
  ) -> [FaceTimeMember] {
    // Nil means the OS did not answer, so presence can't be judged; fall back to the
    // roster's own claim rather than reporting everyone as stuck in the lobby.
    let active = activeParticipantHandles(of: conversation)

    return roster(of: conversation).compactMap { entry in
      guard let value = memberHandleValue(entry.object) else { return nil }
      let joined = active.map { $0.contains(value.lowercased()) } ?? !entry.declaredPending
      let knocked = ((try? IMCoreRuntime.send(entry.object, "dateReceivedLetMeIn")) ?? nil) != nil
      return FaceTimeMember(
        handle: FaceTimeHandle(value: value),
        nickname: ((try? IMCoreRuntime.string(entry.object, "nickname")) ?? nil),
        isPending: forcePending || !joined,
        isWaitingToBeLetIn: (forcePending || !joined) && (knocked || entry.declaredPending),
        joinedFromLetMeIn: (try? IMCoreRuntime.bool(entry.object, "joinedFromLetMeIn")) ?? false,
        isActive: joined && !forcePending,
        isLightweight: (try? IMCoreRuntime.bool(entry.object, "isLightweightMember")) ?? false
      )
    }
  }

  private static func memberHandleValue(_ member: AnyObject) -> String? {
    guard let handle = try? IMCoreRuntime.send(member, "handle") else { return nil }
    return ((try? IMCoreRuntime.string(handle, "value")) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
  }
}
