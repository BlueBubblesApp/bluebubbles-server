//  FaceTimeCallStatusTests
//  The FaceTime helper announces a call's status in the frame the server decodes.
//
//  `ft-call-status-changed` was decoded by the server and never sent by the helper: nothing
//  called `FaceTimeBridge.emit`, so neither it nor `incoming-facetime` ever reached a client.
//  These drive the helper's handler with a stand-in for `TUCall` and decode what it emits
//  with the server's own decoder. What they cannot show is TelephonyUtilities posting the
//  notification inside FaceTime.app; that needs a live call.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBPrivateAPI
@testable import BlueBubblesFaceTimeHelper

/// The selectors `FaceTimeBridge` reads from a `TUCall`, and nothing else.
private final class FakeCall: NSObject {
  @objc let callUUID: String
  @objc var callStatus: Int32
  @objc let handle: FakeHandle
  @objc let isSendingVideo = true
  @objc let isSendingAudio = true
  @objc let isOutgoing = false
  @objc let callerIDBlocked = false
  @objc var endedReasonString: String?

  init(uuid: String, status: FaceTimeCallStatus) {
    callUUID = uuid
    callStatus = Int32(status.rawValue)
    handle = FakeHandle()
  }
}

private final class FakeHandle: NSObject {
  @objc let value = "someone@example.com"
}

@Suite("FaceTime call status announcements", .serialized)
@MainActor
struct FaceTimeCallStatusTests {

  /// Captures what the bridge emits, as the JSON the socket client would write.
  private func capturing(_ body: () -> Void) -> [(name: String, payload: [String: WireJSON])] {
    let frames = Locked<[(String, Data)]>([])
    FaceTimeBridge.setEmitter { event, payload in
      // `try!`: a payload the serialiser refuses is the failure under test.
      let data = try! JSONSerialization.data(withJSONObject: payload.jsonObject)
      frames.withLock { $0.append((event.rawValue, data)) }
    }
    body()
    FaceTimeBridge.setEmitter { _, _ in }
    return frames.value.map { name, data in
      (name, (try? JSONDecoder().decode([String: WireJSON].self, from: data)) ?? [:])
    }
  }

  @Test("A status change is emitted in the frame the server decodes")
  func statusChangeDecodes() throws {
    let call = FakeCall(uuid: "CALL-\(UUID().uuidString)", status: .incoming)
    let frames = capturing { FaceTimeBridge.callStatusChanged(call) }

    let frame = try #require(frames.first)
    #expect(frames.count == 1)
    #expect(frame.name == HelperEventName.faceTimeCallStatusChanged.rawValue)
    let event = HelperEventDecoder.decode(name: frame.name, payload: frame.payload)
    guard case .faceTimeCallChanged(let decoded, let details)? = event else {
      Issue.record("expected faceTimeCallChanged, got \(String(describing: event))")
      return
    }
    #expect(decoded.callUUID == call.callUUID)
    #expect(decoded.status == .incoming)
    #expect(decoded.handle?.value == "someone@example.com")
    #expect(details[WireKey.isOutgoing.rawValue] == "false")
    #expect(details[WireKey.isSendingAudio.rawValue] == "true")
    #expect(details[WireKey.endedReason.rawValue] == nil)
  }

  /// A video call can be posted under both notification names, and a call's other
  /// properties change without its status moving. Each status is announced once.
  @Test("Each status is announced once, and a finished call is forgotten by the next")
  func statusAnnouncedOnce() {
    let call = FakeCall(uuid: "CALL-\(UUID().uuidString)", status: .incoming)
    let frames = capturing {
      FaceTimeBridge.callStatusChanged(call)
      FaceTimeBridge.callStatusChanged(call)
      call.callStatus = Int32(FaceTimeCallStatus.disconnected.rawValue)
      call.endedReasonString = "remote ended"
      FaceTimeBridge.callStatusChanged(call)
      FaceTimeBridge.callStatusChanged(call)
    }
    #expect(frames.count == 2)
    #expect(frames.last?.payload[WireKey.callStatus.rawValue] == .number(6))
    #expect(frames.last?.payload[WireKey.endedReason.rawValue] == .string("remote ended"))

    let next = FakeCall(uuid: "CALL-\(UUID().uuidString)", status: .disconnected)
    _ = capturing { FaceTimeBridge.callStatusChanged(next) }
    #expect(FaceTimeBridge.announcedStatus[call.callUUID] == nil)
    #expect(FaceTimeBridge.announcedStatus[next.callUUID] == .disconnected)
  }

  @Test("An object that is not a call is not announced")
  func nonCallIgnored() {
    let frames = capturing {
      FaceTimeBridge.callStatusChanged(NSObject())
      FaceTimeBridge.callStatusChanged(nil)
    }
    #expect(frames.isEmpty)
  }
}
