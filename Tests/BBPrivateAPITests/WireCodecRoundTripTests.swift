//  WireCodecRoundTripTests
//  Every contract codec, through the bytes the helper socket carries.
//
//  A value is encoded with the contract's `wire` (what the helper writes), serialised the
//  way `HelperSocketClient.write` serialises it (`encodable`, then `JSONSerialization`),
//  parsed into `WireJSON` the way the server's transport parses a frame, and decoded with
//  the contract's `init(wire:)` (what `PrivateAPIClient` reads). Equality at the end is the
//  claim that the two halves agree. The suite also pins the one rule for absence: a reply
//  missing a field the contract requires throws `protocolMismatch` naming it.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBPrivateAPI
@testable import HelperShared

/// A helper payload as the server receives it.
private func overTheSocket(_ object: WireObject) throws -> WireJSON {
  let body = try JSONSerialization.data(withJSONObject: HelperSocketClient.encodable(object))
  return try JSONDecoder().decode(WireJSON.self, from: body)
}

private func roundTrip<T: WireCodable>(_ value: T) throws -> T {
  try T(wire: WireReader(overTheSocket(value.wire), context: "the test reply"))
}

/// A whole-millisecond instant, so equality after the round trip is exact.
private let instant = Date(wireMilliseconds: 1_700_000_000_123)

private let filter = ChatFilterState(
  isFiltered: 1, filterCategory: 2, isKnownSender: false, isInUnknownSendersFilter: true,
  wasDetectedAsSMSSpam: true, canReportJunk: true)

private let location = FindMyLocation(
  latitude: 37.3349, longitude: -122.009, horizontalAccuracy: 12.5, altitude: 31.25,
  shortAddress: "1 Example Way", longAddress: "1 Example Way, Example City", label: "Work",
  lastUpdated: instant, isLocatingInProgress: true, status: .live)

private let call = FaceTimeCall(
  callUUID: "CALL-1", status: .incoming,
  handle: FaceTimeHandle(value: "+12025550143", displayName: "Someone"),
  groupUUID: "GROUP-1", isVideo: false, callerIDBlocked: true)

private let member = FaceTimeMember(
  handle: FaceTimeHandle(value: "temp:11111111-2222-3333-4444-555555555555", displayName: nil),
  nickname: "Guest", isPending: true, isWaitingToBeLetIn: true, joinedFromLetMeIn: true,
  isActive: false, isLightweight: true)

@Suite("Contract codecs round-trip through the socket")
struct WireCodecRoundTripTests {

  @Test("Mute state, with a date, indefinite, and not muted")
  func muteState() throws {
    for value in [
      ChatMuteState(isMuted: true, mutedUntil: instant, isIndefinite: false),
      ChatMuteState(isMuted: true, mutedUntil: nil, isIndefinite: true),
      ChatMuteState(isMuted: false, mutedUntil: nil, isIndefinite: false),
    ] {
      #expect(try roundTrip(value) == value)
    }
  }

  @Test("Filter state, with a category and without one")
  func filterState() throws {
    #expect(try roundTrip(filter) == filter)
    let unknownCategory = ChatFilterState(
      isFiltered: 0, filterCategory: nil, isKnownSender: true, isInUnknownSendersFilter: false,
      wasDetectedAsSMSSpam: false, canReportJunk: false)
    #expect(try roundTrip(unknownCategory) == unknownCategory)
  }

  @Test("Presentation state, answered, unanswerable, and mixed")
  func presentationState() throws {
    for value in [
      ChatPresentationState(
        shouldPresentSpamReasonPicker: true, isReportedAsSpam: false, wasDetectedAsSMSSpam: true,
        wasDetectedAsSpam: false, isKnownChat: true, completedInitialChatMessagesLoad: false,
        isSMSSpamFilteringEnabled: true),
      ChatPresentationState(
        shouldPresentSpamReasonPicker: nil, isReportedAsSpam: nil, wasDetectedAsSMSSpam: nil,
        wasDetectedAsSpam: nil, isKnownChat: nil, completedInitialChatMessagesLoad: nil,
        isSMSSpamFilteringEnabled: nil),
      ChatPresentationState(
        shouldPresentSpamReasonPicker: nil, isReportedAsSpam: true, wasDetectedAsSMSSpam: nil,
        wasDetectedAsSpam: false, isKnownChat: nil, completedInitialChatMessagesLoad: true,
        isSMSSpamFilteringEnabled: nil),
    ] {
      #expect(try roundTrip(value) == value)
    }
  }

  @Test("Spam result, with its nested filter state")
  func spamResult() throws {
    let value = ChatSpamResult(
      messageCount: 12, reportedToCarrier: false, wasDryRun: true, filter: filter)
    #expect(try roundTrip(value) == value)
  }

  @Test("FindMy status, with a device and unavailable")
  func findMyStatus() throws {
    let value = FindMyStatus(
      isAvailable: true, isProvisioned: true, isRestricted: false, isSharingDisabled: false,
      backend: .findMyLocate, activeDevice: FindMyDeviceSummary(name: "Mac", isThisDevice: true))
    #expect(try roundTrip(value) == value)
    #expect(try roundTrip(FindMyStatus.unavailable) == .unavailable)
    let nameless = FindMyDeviceSummary(name: nil, isThisDevice: false)
    #expect(try roundTrip(nameless) == nameless)
  }

  @Test("FindMy location, located and not")
  func findMyLocation() throws {
    #expect(try roundTrip(location) == location)
    let unlocated = FindMyLocation(status: .unknown)
    #expect(try roundTrip(unlocated) == unlocated)
  }

  @Test("FindMy friend, with a position and without")
  func findMyFriend() throws {
    for value in [
      FindMyFriend(
        handle: "+12025550143", isSharingWithMe: true, isFollowingMyLocation: false,
        location: location),
      FindMyFriend(
        handle: "someone@example.com", isSharingWithMe: false, isFollowingMyLocation: true),
    ] {
      #expect(try roundTrip(value) == value)
    }
  }

  /// IMCore reports an unlocated friend at (0, 0). The encoder drops the pair, so a client
  /// never sees a pin in the Gulf of Guinea; the round trip is deliberately NOT the identity.
  @Test("The origin is not sent as a position")
  func originIsDropped() throws {
    let decoded = try roundTrip(FindMyLocation(latitude: 0, longitude: 0, status: .legacy))
    #expect(decoded.latitude == nil)
    #expect(decoded.longitude == nil)
    #expect(decoded.status == .legacy)
  }

  /// `JSONSerialization` raises an exception nothing can catch for a non-finite number, inside
  /// Messages. The encoder drops the reading; the rest of the reply still goes.
  @Test("A non-finite reading is dropped rather than failing the reply")
  func nonFiniteIsDropped() throws {
    let value = FindMyLocation(
      latitude: .nan, longitude: 12, horizontalAccuracy: .infinity, altitude: -.infinity,
      label: "Somewhere", status: .shallow)
    let decoded = try roundTrip(value)
    #expect(decoded.latitude == nil)
    #expect(decoded.longitude == nil)
    #expect(decoded.horizontalAccuracy == nil)
    #expect(decoded.altitude == nil)
    #expect(decoded.label == "Somewhere")
    #expect(decoded.status == .shallow)
  }

  @Test("FaceTime link, full and bare")
  func faceTimeLink() throws {
    for value in [
      FaceTimeLink(
        url: "https://facetime.apple.com/join#v=1&p=abc", groupUUID: "GROUP-1", name: "Call",
        expiresAt: instant),
      FaceTimeLink(url: "https://facetime.apple.com/join#v=1&p=def"),
    ] {
      #expect(try roundTrip(value) == value)
    }
  }

  @Test("FaceTime call, with a peer, without one, and with an unnamed peer")
  func faceTimeCall() throws {
    for value in [
      call,
      FaceTimeCall(callUUID: "CALL-2", status: .answered),
      FaceTimeCall(
        callUUID: "CALL-3", status: .disconnected, handle: FaceTimeHandle(value: "+12025550143")),
    ] {
      #expect(try roundTrip(value) == value)
    }
  }

  @Test("FaceTime member, a link guest and an invited address")
  func faceTimeMember() throws {
    let invited = FaceTimeMember(
      handle: FaceTimeHandle(value: "someone@example.com", displayName: "Someone"),
      isPending: false, isActive: true)
    for value in [member, invited] {
      #expect(try roundTrip(value) == value)
    }
  }

  /// The event decoder uses the same codecs as the replies, so a call or a member a helper
  /// emits with them decodes on the server unchanged.
  @Test("FaceTime events decode what the codecs encode")
  func faceTimeEvents() throws {
    guard case .object(let callFields) = try overTheSocket(call.wire) else {
      Issue.record("a call did not encode as an object")
      return
    }
    guard
      case .faceTimeCallChanged(let decodedCall, _)? = HelperEventDecoder.decode(
        name: HelperEventName.faceTimeCallStatusChanged.rawValue, payload: callFields)
    else {
      Issue.record("the call event did not decode")
      return
    }
    #expect(decodedCall == call)

    let membership: WireObject = [.conversationUUID: "GROUP-1", .members: [member.wire]]
    guard case .object(let membershipFields) = try overTheSocket(membership) else {
      Issue.record("a membership did not encode as an object")
      return
    }
    guard
      case .faceTimeMembershipChanged(let conversation, let members)? = HelperEventDecoder.decode(
        name: HelperEventName.faceTimeMembershipChanged.rawValue, payload: membershipFields)
    else {
      Issue.record("the membership event did not decode")
      return
    }
    #expect(conversation == "GROUP-1")
    #expect(members == [member])
  }
}

// MARK: - Absence

@Suite("A reply missing a required field is a protocol mismatch")
struct WireCodecRequiredFieldTests {

  /// One sample per codec and the fields it may not lose. Every OTHER field of the sample is
  /// optional, and the second test below holds that side of the line too.
  private typealias Sample = (
    name: String, wire: WireObject, required: [WireKey], decode: (WireReader) throws -> Void
  )

  /// Computed rather than stored: a `WireObject` is not `Sendable`, so it cannot sit in a
  /// static.
  private static var cases: [Sample] {
    [
      (
        "mute", ChatMuteState(isMuted: true, mutedUntil: instant, isIndefinite: false).wire,
        [.isMuted, .isIndefinite], { _ = try ChatMuteState(wire: $0) }
      ),
      (
        "filter", filter.wire,
        [
          .isFiltered, .isKnownSender, .isInUnknownSendersFilter, .wasDetectedAsSMSSpam,
          .canReportJunk,
        ], { _ = try ChatFilterState(wire: $0) }
      ),
      (
        "spam",
        ChatSpamResult(messageCount: 1, reportedToCarrier: false, wasDryRun: false, filter: filter)
          .wire,
        [.messageCount, .reportedToCarrier, .dryRun, .filter], { _ = try ChatSpamResult(wire: $0) }
      ),
      (
        "status",
        FindMyStatus(
          isAvailable: true, isProvisioned: true, isRestricted: false, isSharingDisabled: false,
          backend: .legacyFindMyFriends,
          activeDevice: FindMyDeviceSummary(name: "Mac", isThisDevice: true)
        ).wire,
        [.available, .provisioned, .restricted, .sharingDisabled, .backend],
        { _ = try FindMyStatus(wire: $0) }
      ),
      (
        "device", FindMyDeviceSummary(name: "Mac", isThisDevice: true).wire, [.isThisDevice],
        { _ = try FindMyDeviceSummary(wire: $0) }
      ),
      (
        "location", location.wire, [.isLocatingInProgress, .status],
        { _ = try FindMyLocation(wire: $0) }
      ),
      (
        "friend",
        FindMyFriend(
          handle: "+12025550143", isSharingWithMe: true, isFollowingMyLocation: true,
          location: location
        ).wire,
        [.handle, .isSharingWithMe, .isFollowingMyLocation], { _ = try FindMyFriend(wire: $0) }
      ),
      (
        "link",
        FaceTimeLink(
          url: "https://facetime.apple.com/join#x", groupUUID: "G", name: "N", expiresAt: instant
        )
        .wire,
        [.url], { _ = try FaceTimeLink(wire: $0) }
      ),
      (
        "call", call.wire, [.callUUID, .callStatus, .isVideo, .callerIDBlocked],
        { _ = try FaceTimeCall(wire: $0) }
      ),
      (
        "member", member.wire,
        [.handle, .isActive, .isLightweight, .isPending, .isWaitingToBeLetIn, .joinedFromLetMeIn],
        { _ = try FaceTimeMember(wire: $0) }
      ),
    ]
  }

  @Test("Each required field, removed, throws protocolMismatch naming it")
  func requiredFieldsThrow() throws {
    for sample in Self.cases {
      guard case .object(let fields) = try overTheSocket(sample.wire) else {
        Issue.record("\(sample.name) did not encode as an object")
        continue
      }
      for key in sample.required {
        #expect(fields[key] != nil, "\(sample.name) does not send '\(key)'")
        var without = fields
        without[key.rawValue] = nil
        let reader = try WireReader(.object(without), context: "the \(sample.name) reply")
        #expect(
          throws: PrivateAPIError.protocolMismatch("the \(sample.name) reply has no '\(key)'"),
          "\(sample.name) decoded without '\(key)'"
        ) {
          try sample.decode(reader)
        }
      }
    }
  }

  /// The other side of the line: a field whose absence means something decodes without it.
  @Test("Every field not listed as required may be absent")
  func optionalFieldsDoNot() throws {
    for sample in Self.cases {
      guard case .object(let fields) = try overTheSocket(sample.wire) else { continue }
      for key in fields.keys where !sample.required.map(\.rawValue).contains(key) {
        var without = fields
        without[key] = nil
        let reader = try WireReader(.object(without), context: "the \(sample.name) reply")
        #expect(throws: Never.self, "\(sample.name) requires '\(key)'") {
          try sample.decode(reader)
        }
      }
    }
  }

  @Test("A nested field names its path")
  func nestedPath() throws {
    let reply = WireJSON.object([
      "friends": .array([
        .object([
          "handle": .string("+12025550143"),
          "isSharingWithMe": .bool(true),
          "isFollowingMyLocation": .bool(true),
          "location": .object(["isLocatingInProgress": .bool(false)]),
        ])
      ])
    ])
    #expect(
      throws: PrivateAPIError.protocolMismatch(
        "the findmy-friends reply has no 'friends[0].location.status'")
    ) {
      _ = try WireReader(reply: reply, to: .findMyFriends).decodeList(
        .friends, as: FindMyFriend.self)
    }
  }

  /// A count sent as a string is a disagreement about the format, not a missing value.
  @Test("A field of the wrong type is a protocol mismatch")
  func wrongType() throws {
    let reply = WireJSON.object([
      "isMuted": .string("yes"),
      "isIndefinite": .bool(false),
    ])
    #expect(
      throws: PrivateAPIError.protocolMismatch(
        "the get-chat-mute reply carries 'isMuted' that is not a boolean")
    ) {
      _ = try ChatMuteState(reply: reply, to: .getChatMute)
    }
  }

  /// Through the client: a scalar reply follows the same rule as a codec.
  @Test("A scalar reply missing its field throws through the client")
  func clientScalar() async throws {
    let client = PrivateAPIClient(transport: StubHelperTransport())
    await #expect(
      throws: PrivateAPIError.protocolMismatch("the clear-chat-history reply has no 'deleted'")
    ) {
      _ = try await client.clearChatHistory(ChatIdentifier("any;-;someone@example.com"))
    }
    await #expect(
      throws: PrivateAPIError.protocolMismatch("the get-chat-mute reply has no 'isMuted'")
    ) {
      _ = try await client.muteState(chat: ChatIdentifier("any;-;someone@example.com"))
    }
  }
}

// MARK: - Times

@Suite("Times on the helper wire")
struct WireMillisecondsTests {

  @Test("A whole-millisecond date survives the round trip exactly")
  func roundTrips() {
    #expect(instant.wireMilliseconds == 1_700_000_000_123)
    #expect(Date(wireMilliseconds: Double(instant.wireMilliseconds)) == instant)
  }

  @Test("Sub-millisecond precision is rounded, never sent as a fraction")
  func rounds() {
    #expect(Date(timeIntervalSince1970: 1.0004).wireMilliseconds == 1000)
    #expect(Date(timeIntervalSince1970: 1.0006).wireMilliseconds == 1001)
  }

  /// The helper converts dates inside Messages, where a trap is the user's crash.
  @Test("An unrepresentable date clamps rather than traps")
  func clamps() {
    #expect(Date(timeIntervalSince1970: .infinity).wireMilliseconds == .max)
    #expect(Date(timeIntervalSince1970: -.infinity).wireMilliseconds == .min)
    #expect(Date(timeIntervalSince1970: 1e300).wireMilliseconds == .max)
  }

  @Test("The client sends whole milliseconds for a scheduled send and a mute")
  func clientSendsWholeMilliseconds() async throws {
    let transport = StubHelperTransport(replies: [
      "set-chat-mute": .object(["isMuted": .bool(true), "isIndefinite": .bool(false)])
    ])
    let client = PrivateAPIClient(transport: transport)
    let chat = ChatIdentifier("any;-;someone@example.com")
    let fractional = Date(timeIntervalSince1970: 1_700_000_000.1234567)

    try await client.rescheduleMessage(MessageGUID("MESSAGE-1"), in: chat, to: fractional)
    #expect(await transport.lastPayload?["scheduledFor"] == .number(1_700_000_000_123))

    _ = try await client.setMute(ChatMuteRequest(chat: chat, until: fractional))
    #expect(await transport.lastPayload?["mutedUntil"] == .number(1_700_000_000_123))
  }
}
