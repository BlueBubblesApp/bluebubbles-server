//  FaceTimeEventShapeTests
//  A FaceTime call's status goes out in the shape the reference sends, in both of its modes.
//
//  `PrivateApiFaceTimeStatusHandler.ts` branches on `facetime_calling` (here
//  `facetime_incoming_handoff`). Off, a ringing call is `incoming-facetime` with a JSON STRING
//  payload, `{"caller","timestamp"}`. On, every status but outgoing and answered is
//  `ft-call-status-changed` with a fixed snake_case shape, and a ringing call is announced
//  once. This server sent neither: an object where the string goes, `callUuid` and every
//  field flattened to a string where `uuid`, `status_id` and booleans go, outgoing and
//  answered calls announced, and membership churn under the status event's name.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBEvents
import BBPrivateAPIContract
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("FaceTime event shapes")
struct FaceTimeEventShapeTests {

  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func call(_ status: FaceTimeCallStatus, handle: String? = "someone@example.com")
    -> FaceTimeCall
  {
    FaceTimeCall(
      callUUID: "CALL-1", status: status, handle: handle.map { FaceTimeHandle(value: $0) })
  }

  @Test("Without hand-off, a ringing call is incoming-facetime with a JSON string payload")
  func standardModeIsAString() throws {
    let mapped = try #require(
      PrivateAPIGatedService.faceTimeEvent(
        call(.incoming), payload: [:], calling: false, isNewSession: true, handle: nil,
        now: Self.now))
    #expect(mapped.event.name == .incomingFaceTime)
    let text = try #require(mapped.event.fullPayload.stringValue)
    let decoded = try JSONValue.parse(Data(text.utf8))
    #expect(decoded["caller"]?.stringValue == "someone@example.com")
    #expect(decoded["timestamp"]?.intValue == Int(Self.now.epochMilliseconds))

    // Nothing else is announced in this mode.
    for status in [FaceTimeCallStatus.answered, .outgoing, .disconnected, .unknown] {
      #expect(
        PrivateAPIGatedService.faceTimeEvent(
          call(status), payload: [:], calling: false, isNewSession: true, handle: nil,
          now: Self.now) == nil)
    }
  }

  @Test("With hand-off, a status change carries the reference's keys and types")
  func callingModeShape() throws {
    let handle = JSONValue.object(["address": .string("someone@example.com")])
    let mapped = try #require(
      PrivateAPIGatedService.faceTimeEvent(
        call(.disconnected),
        payload: ["ended_reason": "2", "is_outgoing": "false", "is_sending_audio": "true"],
        calling: true, isNewSession: false, handle: handle, now: Self.now))
    #expect(mapped.event.name == .faceTimeCallStatusChanged)
    let body = mapped.event.fullPayload
    #expect(body["uuid"]?.stringValue == "CALL-1")
    #expect(body["status"]?.stringValue == "disconnected")
    #expect(body["status_id"]?.intValue == 6)
    #expect(body["address"]?.stringValue == "someone@example.com")
    #expect(body["handle"] == handle)
    #expect(body["ended_reason"]?.stringValue == "2")
    #expect(body["ended_error"] == .null)
    #expect(body["image_url"] == .null)
    #expect(body["is_outgoing"]?.boolValue == false)
    #expect(body["is_audio"]?.boolValue == true)
    #expect(body["is_video"]?.boolValue == true)
    guard case .object(let fields) = body else {
      Issue.record("the payload is not an object")
      return
    }
    #expect(
      Set(fields.keys) == [
        "uuid", "status", "status_id", "ended_error", "ended_reason", "address", "handle",
        "image_url", "is_outgoing", "is_audio", "is_video",
      ])
  }

  @Test("With hand-off, outgoing and answered calls are not announced, and a ringing one once")
  func callingModeSkips() {
    func mapped(_ status: FaceTimeCallStatus, isNew: Bool) -> Bool {
      PrivateAPIGatedService.faceTimeEvent(
        call(status), payload: [:], calling: true, isNewSession: isNew, handle: nil,
        now: Self.now) != nil
    }
    #expect(!mapped(.outgoing, isNew: true))
    #expect(!mapped(.answered, isNew: true))
    #expect(mapped(.incoming, isNew: true))
    #expect(!mapped(.incoming, isNew: false))
  }

  @Test("Membership churn is not sent under the call-status event")
  func membershipIsNotAStatus() {
    let event = PrivateAPIEvent.faceTimeMembershipChanged(conversationUUID: "GROUP-1", members: [])
    #expect(PrivateAPIGatedService.serverEvent(for: event) == nil)
  }
}
