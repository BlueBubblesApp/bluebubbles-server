//  WireKey
//  Every field name on the helper wire, declared once.
//
//  `HelperAction` closes the vocabulary of COMMANDS: a case on each side, an exhaustive
//  switch, and a command that one side does not know fails to compile. This does the same
//  for the fields inside a command. Spelled as literals, `PrivateAPIClient` writes
//  `"selectedMessageGuid"` and `HelperDispatch` reads `"selectedMessageGuid"` in different
//  targets with nothing but a round-trip test connecting them: a typo on either side
//  compiles and surfaces as Messages "rejecting" a request nobody can see anything wrong
//  with.
//
//  This enum is that connection. The client builds payloads keyed by it, each dispatch reads
//  them by it, and every reply is built from it, so a field has exactly one spelling and a
//  renamed case is a compile error on both sides at once. `HelperVocabularyTests` scans the
//  files on either side of the socket and fails on a literal key, which is what keeps this
//  the ONLY spelling rather than the preferred one.
//
//  What it does NOT do, stated so nobody expects it: it does not say which action carries
//  which fields. That is still the pairing between a client method and its dispatch case,
//  and `HelperRoundTripTests` is what checks it. Typed per-action payloads would close that
//  too, at the cost of a custom encoding per request type: this wire carries `ddScan` as
//  0/1, dates as epoch milliseconds and "absent" as distinct from null, none of which a
//  synthesised `Codable` produces, and the shipping Objective-C helper has to keep
//  understanding every byte. One spelling per field is the part that matters.
//
//  The raw values ARE the wire. A shipped helper matches on them, so a case may be renamed
//  freely and a raw value may not change. They look inconsistent because they are:
//  `backwardsCompatibilityMessage`, `avatar_path`, `ddScan` as a number. They are the
//  shipping helper's spellings, reproduced rather than tidied; see `PrivateAPIClient`.
//
//  Nothing but Foundation, like everything in this module: it travels into Messages.app.

import Foundation

/// A field name on the helper wire: a key in a request `data` object, a reply payload, or
/// an event frame.
public enum WireKey: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {

  // MARK: Envelope
  //
  // The frame around a payload. Decoded by name on both sides (`HelperProtocol.Request`,
  // `HelperResponse`) and written by the helper's socket client.

  case action
  case data
  case error
  case event
  case transactionId

  // MARK: Registration
  //
  // The `ping` a helper sends on connect.

  case process
  case protocolVersion
  /// Which observation-ladder rung the helper attached to.
  case events

  // MARK: Conversation and message identity

  case chatGuid
  case messageGuid
  /// The message a reply, reaction or sticker is attached to.
  case selectedMessageGuid
  /// A poll's root message.
  case rootGuid
  /// A poll's current state message.
  case stateGuid
  case partIndex
  /// A send's reply: the new message's GUID. Also the reply to `create-chat`, where it is a
  /// MESSAGE guid; see `PrivateAPIClient.createChat`.
  case identifier
  /// An older helper's spelling of `identifier` on a send reply.
  case guid

  // MARK: Sending

  case message
  case subject
  case effectId
  /// 0/1 on the wire rather than a boolean: the shipping helper reads it as a number.
  case ddScan
  case textFormatting
  /// Epoch milliseconds: "Send Later".
  case scheduledFor
  case parts
  case text
  case attachment
  case mention
  case balloonBundleId
  /// Base64: the wire is JSON and an app message's payload is an archive.
  case payload
  case summary
  case filePath
  case isAudioMessage

  // MARK: Text formatting entries

  case start
  case length
  case styles
  case effect

  // MARK: Stickers

  case xScalar
  case yScalar
  case scale
  case rotation
  case parentPreviewWidth
  case tapback
  case remove
  case accessibilityName
  case externalURI
  case byteCount

  // MARK: Polls

  case title
  case options
  case id
  case creatorHandle
  case canBeEdited
  case sessionId
  case optionIds

  // MARK: Editing, reactions, search

  case editedMessage
  case backwardsCompatibilityMessage
  case reactionType
  /// The Objective-C helper's own key for an emoji tapback's emoji.
  case reactionEmoji
  case query
  case matchType
  case limit
  case results
  case path

  // MARK: Chats

  case addresses
  case service
  case newName
  case address
  case pinned
  case chats
  case deleted

  // MARK: Mute

  case isMuted
  case isIndefinite
  /// Epoch milliseconds. OMITTED for an indefinite mute: absence is the contract.
  case mutedUntil
  case syncToPairedDevice

  // MARK: Filtering and spam

  case isFiltered
  case filterCategory
  case isKnownSender
  case isInUnknownSendersFilter
  case wasDetectedAsSMSSpam
  case canReportJunk
  case saveInContacts
  case reportToCarrier
  case dryRun
  case category
  case messageCount
  case reportedToCarrier
  case filter

  // MARK: Presence, handles, account

  case typing
  case available
  case status
  case appleId
  case activeAlias
  case alias
  case aliases
  case vettedAliases
  case handle
  case name
  case hasSharedNickname
  case avatarPath = "avatar_path"
  case shouldOffer

  // MARK: Attachments

  case attachmentGuid

  // MARK: FindMy

  case provisioned
  case restricted
  case sharingDisabled
  case backend
  case activeDevice
  case isThisDevice
  case friends
  case friend
  case isSharingWithMe
  case isFollowingMyLocation
  case location
  case latitude
  case longitude
  case horizontalAccuracy
  case altitude
  case shortAddress
  case longAddress
  case label
  /// Epoch milliseconds.
  case lastUpdated
  case isLocatingInProgress
  case duration

  // MARK: FaceTime

  case callUUID
  /// The older FaceTime helper's spelling of `callUUID`. Read, never written.
  case legacyCallUUID = "call_uuid"
  case callStatus
  /// The older FaceTime helper's spelling of `callStatus`. Read, never written.
  case legacyCallStatus = "call_status"
  case video
  case isVideo
  case callerIDBlocked
  case displayName
  case conversationUUID
  /// The shipping helper's name for the handle to admit.
  case handleUUID
  case groupUUID
  /// The older FaceTime helper's spelling of `groupUUID`. Read, never written.
  case legacyGroupUUID = "group_uuid"
  case link
  case url
  case urls
  case expiresAt
  case call
  case calls
  case members
  case nickname
  case isPending
  case isWaitingToBeLetIn
  case joinedFromLetMeIn
  case isActive
  case isLightweight
  case windows
  case dismissed
  case muted
  case sendingVideo
  case invalidated

  public var description: String { rawValue }
}

/// An unsolicited event a helper pushes to the server.
///
/// The names are part of the compatibility contract (`started-typing`, `aliases-removed`
/// and the rest are what the shipping Objective-C helper emits) so the Swift helpers keep
/// them. Here rather than in the server's decoder so the emitting side spells them from the
/// same enum the decoding side switches over.
public enum HelperEventName: String, Sendable, CaseIterable {
  /// Registration, not an event: sent once on connect with `process` and `protocolVersion`.
  case ping
  case startedTyping = "started-typing"
  /// The shipping helper emits both spellings for the same thing.
  case typing
  case stoppedTyping = "stopped-typing"
  case aliasesRemoved = "aliases-removed"
  case newFindMyLocation = "new-findmy-location"
  case faceTimeCallStatusChanged = "ft-call-status-changed"
  case faceTimeMembershipChanged = "ft-members-changed"
}

// MARK: - Reading a payload by key

extension Dictionary where Key == String, Value == WireJSON {
  /// A request's `data`, or an event's fields, read by the typed key.
  public subscript(key: WireKey) -> WireJSON? { self[key.rawValue] }
}

// MARK: - Building a reply

/// A reply or event payload the helper writes, keyed by `WireKey`.
///
/// The helper serialises its replies with `JSONSerialization`, which wants `[String: Any]`.
/// This is that dictionary behind a typed front: it is built from `WireKey`s, nests (a
/// `WireObject` or `[WireObject]` as a value is unwrapped at serialisation), and DROPS nil
/// values rather than writing nulls. The drop is the contract, not a convenience: the
/// server branches on key PRESENCE for `mutedUntil`, `latitude` and the like, and an absent
/// key is a different answer from a null one.
///
/// Not `Sendable`, like the `[String: Any]` it wraps. Both dispatches and the socket client's
/// reply path are `@MainActor`, which is where it is built and written.
public struct WireObject: ExpressibleByDictionaryLiteral {

  /// The string-keyed form. Values may still contain nested `WireObject`s; `jsonObject`
  /// is what flattens them for the serialiser.
  public private(set) var fields: [String: Any]

  public init(_ pairs: [WireKey: Any?]) {
    fields = [:]
    fields.reserveCapacity(pairs.count)
    for (key, value) in pairs {
      if let value { fields[key.rawValue] = value }
    }
  }

  /// A payload of strings, which is what an observed event carries.
  public init(strings pairs: [WireKey: String]) {
    fields = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key.rawValue, $0.value as Any) })
  }

  public init(dictionaryLiteral elements: (WireKey, Any?)...) {
    fields = [:]
    fields.reserveCapacity(elements.count)
    for (key, value) in elements {
      if let value { fields[key.rawValue] = value }
    }
  }

  /// Free-form fields the contract does not model: the FaceTime debug dump, whose keys
  /// are whatever the bridge found worth printing. The ONLY way a string key gets in, and
  /// it says so at the call site.
  public init(untyped fields: [String: Any]) {
    self.fields = fields
  }

  public subscript(key: WireKey) -> Any? {
    get { fields[key.rawValue] }
    set { fields[key.rawValue] = newValue }
  }

  /// What `JSONSerialization` is handed: every nested `WireObject` replaced by its fields,
  /// recursively, so the value graph is plain Foundation types.
  public var jsonObject: [String: Any] {
    fields.mapValues(Self.flatten)
  }

  private static func flatten(_ value: Any) -> Any {
    switch value {
    case let object as WireObject:
      object.jsonObject
    case let list as [Any]:
      list.map(flatten)
    case let dictionary as [String: Any]:
      dictionary.mapValues(flatten)
    default:
      value
    }
  }
}
