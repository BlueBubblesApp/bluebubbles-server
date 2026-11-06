//  FindMyProtocolTests
//  The FindMy half of the helper protocol: what goes out, and what comes back.
//
//  The helper's IMCore calls cannot be tested here; they need Messages.app running with the
//  dylib injected, which needs SIP disabled. What CAN be tested, and is where the mistakes
//  actually live, is everything either side of that: the constants transcribed from IMCore's
//  disassembly, the narrowing the contract performs, and the encode/decode pair that has to
//  agree across two processes.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBPrivateAPI

// MARK: - Constants read out of IMCore

@Suite("FindMy contract")
struct FindMyContractTests {

  /// Read from the disassembly of `-[IMFMFSession _dateFromShareDuration:]` on macOS
  /// 26.5.2: `0` is `+[NSDate dateWithTimeIntervalSinceNow:3600]`, `1` is a calendar
  /// computation to the end of the day, and **anything else** falls through to nil, which
  /// means no expiry. Getting these wrong shares someone's location for longer than they
  /// asked, silently; there is no error to notice.
  @Test("Share durations map to the values IMCore reads")
  func shareDurations() {
    #expect(FindMyShareDuration.oneHour.imCoreValue == 0)
    #expect(FindMyShareDuration.untilEndOfDay.imCoreValue == 1)
    // Not 0 and not 1 is the whole requirement; 2 is simply the value chosen to express
    // it, and the test says so rather than pinning an arbitrary number.
    #expect(FindMyShareDuration.indefinitely.imCoreValue != 0)
    #expect(FindMyShareDuration.indefinitely.imCoreValue != 1)
  }

  /// The enum exists so a client cannot send a raw integer. Anything IMCore would read as
  /// "share forever" has to be unreachable except by asking for it by name.
  @Test("Only the three named durations parse")
  func durationsAreClosed() {
    #expect(FindMyShareDuration(rawValue: "one-hour") == .oneHour)
    #expect(FindMyShareDuration(rawValue: "7") == nil)
    #expect(FindMyShareDuration(rawValue: "forever") == nil)
    #expect(FindMyShareDuration.allCases.count == 3)
  }

  /// `FMLLocation.locationTypeDescription` answers in FindMy's vocabulary, which is not
  /// ours: it says `proactiveOrShallow` where the shipping wire format says `shallow`, and
  /// clients switch on the shipped spelling.
  @Test("Location types map from the modern description")
  func modernStatuses() {
    #expect(FindMyLocationStatus(locationTypeDescription: "live") == .live)
    #expect(FindMyLocationStatus(locationTypeDescription: "legacy") == .legacy)
    #expect(FindMyLocationStatus(locationTypeDescription: "proactiveOrShallow") == .shallow)
    // Case-insensitive, because the description is a Swift enum's name reflected into a
    // string and its capitalisation is not a promise.
    #expect(FindMyLocationStatus(locationTypeDescription: "LIVE") == .live)
    // A type IMCore grows later is reported, not guessed at.
    #expect(FindMyLocationStatus(locationTypeDescription: "somethingNew") == .unknown)
    #expect(FindMyLocationStatus(locationTypeDescription: nil) == .unknown)
  }

  /// The legacy numeric mapping, transcribed from the Objective-C helper.
  @Test("Location types map from the legacy integer")
  func legacyStatuses() {
    #expect(FindMyLocationStatus(legacyLocationType: 0) == .legacy)
    #expect(FindMyLocationStatus(legacyLocationType: 2) == .live)
    #expect(FindMyLocationStatus(legacyLocationType: 1) == .shallow)
    #expect(FindMyLocationStatus(legacyLocationType: 99) == .shallow)
  }

  /// IMCore reports a friend it cannot locate as being at the origin. A client that trusts
  /// it drops a pin in the Gulf of Guinea, so the check lives here once rather than in
  /// every consumer.
  @Test("The origin does not count as a position")
  func originIsNotAFix() {
    #expect(FindMyLocation(latitude: 0, longitude: 0).hasCoordinates == false)
    #expect(FindMyLocation(latitude: nil, longitude: nil).hasCoordinates == false)
    #expect(FindMyLocation(latitude: 37.3349, longitude: -122.009).hasCoordinates)
    // A real position ON a zero meridian or the equator is still a position; only the
    // pair being zero is the sentinel.
    #expect(FindMyLocation(latitude: 0, longitude: -122.009).hasCoordinates)
    #expect(FindMyLocation(latitude: 51.4779, longitude: 0).hasCoordinates)
  }

  /// The shape the helper falls back to when `IMFMFSession` itself is absent. Every field
  /// reads as "cannot" rather than "unknown", because a client deciding whether to show
  /// FindMy has to err towards hiding it.
  @Test("The unavailable status is pessimistic in every field")
  func unavailableIsSafe() {
    let status = FindMyStatus.unavailable
    #expect(status.isAvailable == false)
    #expect(status.isProvisioned == false)
    #expect(status.isSharingDisabled)
    #expect(status.backend == .none)
    #expect(status.activeDevice == nil)
  }
}

// MARK: - The wire

@Suite("FindMy over the wire")
struct FindMyWireTests {

  /// One friend, in exactly the shape `HelperDispatch` emits.
  private static func friendReply() -> WireJSON {
    .object([
      "friends": .array([
        .object([
          "handle": .string("+15550000001"),
          "isSharingWithMe": .bool(true),
          "isFollowingMyLocation": .bool(false),
          "location": .object([
            "latitude": .number(37.3349),
            "longitude": .number(-122.009),
            "horizontalAccuracy": .number(12.5),
            "shortAddress": .string("1 Infinite Loop"),
            "longAddress": .string("1 Infinite Loop, Cupertino, CA"),
            "label": .string("Work"),
            "lastUpdated": .number(1_700_000_000_000),
            "isLocatingInProgress": .bool(false),
            "status": .string("live"),
          ]),
        ])
      ])
    ])
  }

  @Test("A friend decodes with every field the helper sent")
  func decodesFriends() async throws {
    let transport = StubHelperTransport(replies: ["findmy-friends": Self.friendReply()])
    let client = PrivateAPIClient(transport: transport)

    let friends = try await client.findMyFriends()
    #expect(friends.count == 1)

    let friend = try #require(friends.first)
    #expect(friend.handle == "+15550000001")
    #expect(friend.isSharingWithMe)
    #expect(friend.isFollowingMyLocation == false)

    let location = try #require(friend.location)
    // The failure this catches: reading a coordinate through `intValue`, which truncates
    // 37.3349 to 37: an error of up to seventy miles that still looks like a position.
    #expect(location.latitude == 37.3349)
    #expect(location.longitude == -122.009)
    #expect(location.horizontalAccuracy == 12.5)
    #expect(location.shortAddress == "1 Infinite Loop")
    #expect(location.label == "Work")
    #expect(location.status == .live)
    // Milliseconds on the wire, seconds in Foundation.
    #expect(location.lastUpdated == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("A friend with no position decodes as a friend with no position")
  func decodesFriendWithoutLocation() async throws {
    let reply = WireJSON.object([
      "friends": .array([
        .object([
          "handle": .string("+15550000002"),
          "isSharingWithMe": .bool(true),
          "isFollowingMyLocation": .bool(true),
        ])
      ])
    ])
    let transport = StubHelperTransport(replies: ["findmy-friends": reply])
    let client = PrivateAPIClient(transport: transport)

    let friends = try await client.findMyFriends()
    // Present, not dropped. Someone who is sharing but has not been located yet is a
    // different thing from someone we have never heard of.
    #expect(friends.count == 1)
    #expect(friends.first?.location == nil)
    #expect(friends.first?.isFollowingMyLocation == true)
  }

  /// An entry with an empty handle is not a friend. Dropping it beats storing one that can
  /// never be looked up or refreshed.
  @Test("An entry with an empty handle is dropped")
  func dropsAnonymousEntries() async throws {
    let reply = WireJSON.object([
      "friends": .array([
        .object([
          "handle": .string(""),
          "isSharingWithMe": .bool(true),
          "isFollowingMyLocation": .bool(false),
        ])
      ])
    ])
    let transport = StubHelperTransport(replies: ["findmy-friends": reply])
    let client = PrivateAPIClient(transport: transport)
    #expect(try await client.findMyFriends().isEmpty)
  }

  /// An entry with NO handle is a different thing: a helper from another build, which no
  /// amount of dropping entries makes right.
  @Test("An entry missing its handle is a protocol mismatch")
  func missingHandleIsMismatch() async throws {
    let reply = WireJSON.object([
      "friends": .array([
        .object(["isSharingWithMe": .bool(true), "isFollowingMyLocation": .bool(false)])
      ])
    ])
    let client = PrivateAPIClient(
      transport: StubHelperTransport(replies: ["findmy-friends": reply]))
    await #expect(
      throws: PrivateAPIError.protocolMismatch(
        "the findmy-friends reply has no 'friends[0].handle'")
    ) {
      _ = try await client.findMyFriends()
    }
  }

  @Test("Status decodes with every field the helper sent")
  func decodesStatus() async throws {
    let reply = WireJSON.object([
      "available": .bool(true),
      "provisioned": .bool(true),
      "restricted": .bool(false),
      "sharingDisabled": .bool(false),
      "backend": .string("findmy-locate"),
      "activeDevice": .object([
        "name": .string("Mac mini"),
        "isThisDevice": .bool(true),
      ]),
    ])
    let transport = StubHelperTransport(replies: ["findmy-status": reply])
    let client = PrivateAPIClient(transport: transport)

    let status = try await client.findMyStatus()
    #expect(status.isAvailable)
    #expect(status.backend == .findMyLocate)
    #expect(status.activeDevice?.name == "Mac mini")
    #expect(status.activeDevice?.isThisDevice == true)
  }

  /// Every helper this server injects answers this action with every field. An empty reply
  /// is a helper from another build, and is reported as one rather than as "FindMy is not
  /// available", which would hide a feature behind a version skew nobody can see.
  @Test("An empty status reply is a protocol mismatch")
  func missingStatusIsMismatch() async throws {
    let client = PrivateAPIClient(transport: StubHelperTransport())
    await #expect(
      throws: PrivateAPIError.protocolMismatch("the findmy-status reply has no 'available'")
    ) {
      _ = try await client.findMyStatus()
    }
  }

  /// A partial reply must not read as "sharing is enabled" by default, nor as anything else:
  /// it throws, naming the field.
  @Test("A partial status is a protocol mismatch, not a default")
  func partialStatusIsMismatch() async throws {
    let reply = WireJSON.object([
      "available": .bool(true),
      "provisioned": .bool(true),
      "restricted": .bool(false),
      "backend": .string("legacy-fmf"),
    ])
    let client = PrivateAPIClient(
      transport: StubHelperTransport(replies: ["findmy-status": reply])
    )
    await #expect(
      throws: PrivateAPIError.protocolMismatch("the findmy-status reply has no 'sharingDisabled'")
    ) {
      _ = try await client.findMyStatus()
    }
  }

  /// A backend this server has no case for is the helper speaking a newer contract.
  @Test("An unknown backend is a protocol mismatch")
  func unknownBackendIsMismatch() async throws {
    let reply = WireJSON.object([
      "available": .bool(true),
      "provisioned": .bool(true),
      "restricted": .bool(false),
      "sharingDisabled": .bool(false),
      "backend": .string("something-new"),
    ])
    let client = PrivateAPIClient(
      transport: StubHelperTransport(replies: ["findmy-status": reply])
    )
    await #expect(throws: PrivateAPIError.self) {
      _ = try await client.findMyStatus()
    }
  }

  @Test("A refresh sends the address the caller asked about")
  func refreshOneSendsTheAddress() async throws {
    let reply = WireJSON.object([
      "friend": .object([
        "handle": .string("+15550000001"),
        "isSharingWithMe": .bool(true),
        "isFollowingMyLocation": .bool(false),
      ])
    ])
    let transport = StubHelperTransport(replies: ["refresh-findmy-location": reply])
    let client = PrivateAPIClient(transport: transport)

    let friend = try await client.refreshFindMyLocation(handle: "+15550000001")
    #expect(friend.handle == "+15550000001")
    #expect(await transport.actions == ["refresh-findmy-location"])
    #expect(await transport.lastPayload?["address"]?.stringValue == "+15550000001")
  }

  /// A refresh that comes back with nothing is an error rather than an empty friend: the
  /// caller asked about one person and there is no honest answer to give.
  @Test("A refresh with no reply fails rather than inventing a friend")
  func refreshOneWithNoReply() async throws {
    let client = PrivateAPIClient(transport: StubHelperTransport())
    await #expect(throws: (any Error).self) {
      try await client.refreshFindMyLocation(handle: "+15550000001")
    }
  }

  @Test("Sharing sends the chat, the duration and the address")
  func startSharingPayload() async throws {
    let transport = StubHelperTransport()
    let client = PrivateAPIClient(transport: transport)

    try await client.startSharingFindMyLocation(
      FindMyShareRequest(
        chat: ChatIdentifier("iMessage;-;+15550000001"),
        address: "+15550000001",
        duration: .untilEndOfDay
      )
    )

    #expect(await transport.actions == ["start-sharing-findmy-location"])
    let payload = try #require(await transport.lastPayload)
    #expect(payload["chatGuid"]?.stringValue == "iMessage;-;+15550000001")
    #expect(payload["address"]?.stringValue == "+15550000001")
    // The name, not the integer. The helper maps it, so a wrong number cannot get onto
    // the wire from here.
    #expect(payload["duration"]?.stringValue == "until-end-of-day")
  }

  /// Sharing with a whole conversation omits the address rather than sending an empty one:
  /// the helper distinguishes "everyone in this chat" from "this participant" by presence.
  @Test("Sharing with a whole chat omits the address")
  func startSharingWithoutAddress() async throws {
    let transport = StubHelperTransport()
    let client = PrivateAPIClient(transport: transport)

    try await client.startSharingFindMyLocation(
      FindMyShareRequest(chat: ChatIdentifier("iMessage;+;chat123"), duration: .oneHour)
    )
    let payload = try #require(await transport.lastPayload)
    #expect(payload["address"] == nil)
    #expect(payload["duration"]?.stringValue == "one-hour")
  }

  @Test("Stopping a share sends the chat")
  func stopSharingPayload() async throws {
    let transport = StubHelperTransport()
    let client = PrivateAPIClient(transport: transport)

    try await client.stopSharingFindMyLocation(
      chat: ChatIdentifier("iMessage;+;chat123"), address: nil
    )
    #expect(await transport.actions == ["stop-sharing-findmy-location"])
    #expect(await transport.lastPayload?["chatGuid"]?.stringValue == "iMessage;+;chat123")
  }

  @Test("Requesting a share sends the address")
  func requestSharePayload() async throws {
    let transport = StubHelperTransport()
    let client = PrivateAPIClient(transport: transport)

    try await client.requestFindMyLocationShare(handle: "someone@example.invalid")
    #expect(await transport.actions == ["request-findmy-location-share"])
    #expect(
      await transport.lastPayload?["address"]?.stringValue
        == "someone@example.invalid")
  }
}
