//  FaceTimeProtocolTests
//  The FaceTime half of the helper protocol: constants, narrowing, and the encode/decode pair.
//
//  The IMCore/TelephonyUtilities calls cannot run here — they need FaceTime.app injected. What
//  IS testable is where the mistakes live: the call-status constants transcribed from the Node
//  server, and the wire shape both processes must agree on.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBPrivateAPI

@Suite("FaceTime contract")
struct FaceTimeContractTests {

  /// The raw values are IMCore's and NOT contiguous. Transcribed from the Node server's
  /// `FaceTimeSessionStatus`, which corrected the Objective-C helper's guessed constants.
  @Test("Call status maps from the raw TUCall value")
  func callStatusMapping() {
    #expect(FaceTimeCallStatus(raw: 0) == .unknown)
    #expect(FaceTimeCallStatus(raw: 1) == .answered)
    #expect(FaceTimeCallStatus(raw: 3) == .outgoing)
    #expect(FaceTimeCallStatus(raw: 4) == .incoming)
    #expect(FaceTimeCallStatus(raw: 6) == .disconnected)
    // The gaps are real — 2 and 5 are unused, and an unknown value must read as unknown
    // rather than as whichever case shares its number.
    #expect(FaceTimeCallStatus(raw: 2) == .unknown)
    #expect(FaceTimeCallStatus(raw: 99) == .unknown)
  }

  @Test("Status names are stable strings for the wire")
  func statusNames() {
    #expect(FaceTimeCallStatus.incoming.name == "incoming")
    #expect(FaceTimeCallStatus.answered.name == "answered")
    #expect(FaceTimeCallStatus.disconnected.name == "disconnected")
  }
}

/// Records what was asked for and replies with whatever the test wants.
private actor StubTransport: PrivateAPITransport {
  var isConnected: Bool { true }
  var connectedProcesses: Set<String> { ["com.apple.FaceTime"] }

  private(set) var actions: [String] = []
  private(set) var payloads: [WireJSON] = []
  private var replies: [String: WireJSON] = [:]

  init(replies: [String: WireJSON] = [:]) { self.replies = replies }
  func start() async throws {}
  func stop() async {}

  @discardableResult
  func request(action: String, data: WireJSON, timeout: Duration) async throws -> WireJSON? {
    actions.append(action)
    payloads.append(data)
    return replies[action]
  }

  func send(action: String, data: WireJSON) async throws {
    actions.append(action)
    payloads.append(data)
  }

  nonisolated var events: AsyncStream<PrivateAPIEvent> { AsyncStream { $0.finish() } }
  var lastPayload: WireJSON? { payloads.last }
}

@Suite("FaceTime over the wire")
struct FaceTimeWireTests {

  @Test("A link decodes with its URL and conversation")
  func decodesLink() async throws {
    let reply = WireJSON.object([
      "url": .string("https://facetime.apple.com/join#v=1&p=abc"),
      "groupUUID": .string("11111111-2222-3333-4444-555555555555"),
      "name": .string("Team call"),
    ])
    let client = PrivateAPIClient(
      transport: StubTransport(replies: ["generate-link": reply])
    )
    let link = try await client.generateFaceTimeLink(invitedAddresses: [])
    #expect(link.url == "https://facetime.apple.com/join#v=1&p=abc")
    #expect(link.groupUUID == "11111111-2222-3333-4444-555555555555")
    #expect(link.name == "Team call")
  }

  @Test("A missing link is an error, not an empty link")
  func linkRequiresURL() async throws {
    let client = PrivateAPIClient(transport: StubTransport())
    await #expect(throws: (any Error).self) {
      _ = try await client.generateFaceTimeLink(invitedAddresses: [])
    }
  }

  @Test("Generating a link for a call sends the callUUID")
  func linkForCallSendsUUID() async throws {
    let reply = WireJSON.object(["url": .string("https://facetime.apple.com/join#x")])
    let transport = StubTransport(replies: ["generate-link": reply])
    let client = PrivateAPIClient(transport: transport)
    _ = try await client.generateFaceTimeLinkForCall(callUUID: "CALL-1")
    #expect(await transport.actions == ["generate-link"])
    #expect(await transport.lastPayload?["callUUID"]?.stringValue == "CALL-1")
  }

  @Test("Dialing sends addresses and video, and decodes the call")
  func dialDecodes() async throws {
    let reply = WireJSON.object([
      "call": .object([
        "callUUID": .string("CALL-9"),
        "callStatus": .number(3),
        "handle": .string("+15550000001"),
        "isVideo": .bool(true),
      ])
    ])
    let transport = StubTransport(replies: ["dial-facetime": reply])
    let client = PrivateAPIClient(transport: transport)

    let call = try await client.dialFaceTime(
      FaceTimeStartRequest(addresses: ["+15550000001"], video: true)
    )
    #expect(call.callUUID == "CALL-9")
    #expect(call.status == .outgoing)
    #expect(call.handle?.value == "+15550000001")

    let payload = try #require(await transport.lastPayload)
    #expect(payload["addresses"]?.arrayValue?.first?.stringValue == "+15550000001")
    #expect(payload["video"]?.boolValue == true)
  }

  @Test("Admitting sends the conversation and handle in the shipping helper's field names")
  func admitPayload() async throws {
    let transport = StubTransport()
    let client = PrivateAPIClient(transport: transport)
    try await client.admitFaceTimeParticipant(
      conversationUUID: "GROUP-1", handle: "+15550000002"
    )
    #expect(await transport.actions == ["admit-pending-member"])
    let payload = try #require(await transport.lastPayload)
    #expect(payload["conversationUUID"]?.stringValue == "GROUP-1")
    // The Objective-C helper spells the handle field `handleUUID`.
    #expect(payload["handleUUID"]?.stringValue == "+15550000002")
  }

  @Test("Members decode, splitting pending from joined")
  func membersDecode() async throws {
    let reply = WireJSON.object([
      "members": .array([
        .object(["handle": .string("+15550000001"), "isPending": .bool(true)]),
        .object([
          "handle": .string("+15550000002"), "isPending": .bool(false),
          "nickname": .string("Sam"),
        ]),
        .object(["isPending": .bool(true)]),  // no handle — dropped
      ])
    ])
    let client = PrivateAPIClient(
      transport: StubTransport(replies: ["facetime-members": reply])
    )
    let members = try await client.faceTimeMembers(conversationUUID: "GROUP-1")
    #expect(members.count == 2)
    #expect(members.first?.isPending == true)
    #expect(members.last?.isPending == false)
    #expect(members.last?.nickname == "Sam")
  }

  /// The bug that killed three live calls: a browser sitting at "Waiting to be let in…"
  /// is on the conversation roster, so it decoded as joined and the Mac handed off to
  /// nobody. Presence comes from `isActive` alone.
  @Test("A roster member who is not an active participant is not joined")
  func rosterMembershipIsNotPresence() async throws {
    let reply = WireJSON.object([
      "members": .array([
        .object([
          "handle": .string("temp:11111111-2222-3333-4444-555555555555"),
          "nickname": .string("Zach"),
          "isActive": .bool(false),
          "isLightweight": .bool(true),
          "isPending": .bool(true),
          "isWaitingToBeLetIn": .bool(true),
          // True from the moment they knock — NOT proof of admission.
          "joinedFromLetMeIn": .bool(true),
        ])
      ])
    ])
    let client = PrivateAPIClient(
      transport: StubTransport(replies: ["facetime-members": reply])
    )
    let guest = try #require(try await client.faceTimeMembers(conversationUUID: "G").first)
    #expect(guest.isActive == false)
    #expect(guest.isWaitingToBeLetIn)
    #expect(guest.isLightweight)
    #expect(guest.nickname == "Zach")
  }

  /// A link guest has no FaceTime address, so the nickname is the only identity there is —
  /// which is what lets the hand-off tell the client apart from the people we dialled.
  @Test("A member without isActive falls back to the inverse of isPending")
  func activeDefaultsToNotPending() async throws {
    let reply = WireJSON.object([
      "members": .array([
        .object(["handle": .string("+15550000001"), "isPending": .bool(false)])
      ])
    ])
    let client = PrivateAPIClient(
      transport: StubTransport(replies: ["facetime-members": reply])
    )
    let member = try #require(try await client.faceTimeMembers(conversationUUID: "G").first)
    #expect(member.isActive)
    #expect(member.isLightweight == false)
  }

  @Test("Answer and leave send the callUUID")
  func answerLeavePayloads() async throws {
    let transport = StubTransport()
    let client = PrivateAPIClient(transport: transport)
    try await client.answerFaceTimeCall(callUUID: "CALL-1")
    try await client.leaveFaceTimeCall(callUUID: "CALL-1")
    #expect(await transport.actions == ["answer-call", "leave-call"])
    #expect(await transport.lastPayload?["callUUID"]?.stringValue == "CALL-1")
  }
}

@Suite("FaceTime event decoding")
struct FaceTimeEventTests {

  @Test("A call-status event parses into a typed call")
  func callStatusEvent() throws {
    let event = HelperEventDecoder.decode(
      name: "ft-call-status-changed",
      payload: [
        "callUUID": .string("CALL-1"),
        "callStatus": .number(4),
        "handle": .string("+15550000001"),
      ]
    )
    guard case .faceTimeCallChanged(let call, _) = event else {
      Issue.record("expected faceTimeCallChanged, got \(String(describing: event))")
      return
    }
    #expect(call.callUUID == "CALL-1")
    #expect(call.status == .incoming)
    #expect(call.handle?.value == "+15550000001")
  }

  @Test("A membership event parses the conversation and members")
  func membershipEvent() throws {
    let event = HelperEventDecoder.decode(
      name: "ft-members-changed",
      payload: [
        "conversationUUID": .string("GROUP-1"),
        "members": .array([
          .object(["handle": .string("+15550000002"), "isPending": .bool(false)])
        ]),
      ]
    )
    guard case .faceTimeMembershipChanged(let conversation, let members) = event else {
      Issue.record("expected faceTimeMembershipChanged, got \(String(describing: event))")
      return
    }
    #expect(conversation == "GROUP-1")
    #expect(members.first?.handle.value == "+15550000002")
    #expect(members.first?.isPending == false)
  }

  /// A status event with no call UUID is nothing a client can act on, so it is dropped
  /// rather than delivered as a call with an empty id.
  @Test("A call event with no UUID is dropped")
  func callEventNeedsUUID() {
    #expect(HelperEventDecoder.decode(name: "ft-call-status-changed", payload: [:]) == nil)
  }
}
