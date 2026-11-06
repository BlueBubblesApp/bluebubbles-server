//  FaceTimeBridge+CallStatus
//  Announces each call's status change to the server as `ft-call-status-changed`.
//
//  Rung 1 of the observation ladder: `TUCallCenterCallStatusChangedNotification`, posted by
//  TelephonyUtilities inside FaceTime.app with the call as its object, and its
//  `…VideoCallStatusChangedNotification` sibling. The server turns each announcement into
//  `incoming-facetime` or `ft-call-status-changed`, depending on its hand-off setting
//  (`PrivateAPIGatedService.faceTimeEvent`). This file is the only source of either event.
//
//  Both names were read from the TelephonyUtilities symbols of the same names on macOS
//  27.0.1, and each constant's value is its own name. Every selector read here is in the
//  `TUCall` dumps for 14.6.1, 15.6.1, 26.5.2 and 27.0.1. NOT VERIFIED AGAINST A LIVE CALL:
//  that the notification fires in an injected FaceTime.app, and that its object is the
//  `TUCall`, are TelephonyUtilities' convention rather than a measurement. An object that is
//  not a call decodes with no UUID and is dropped, so a wrong guess costs the event, not
//  the host.
//
//  One flow's worth of `FaceTimeBridge`; its static state is declared beside the enum.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FaceTimeBridge {

  /// The notifications a call's status change may be posted under. A video call may be
  /// posted under both, which `announcedStatus` absorbs.
  static let callStatusNotifications = [
    NSNotification.Name("TUCallCenterCallStatusChangedNotification"),
    NSNotification.Name("TUCallCenterVideoCallStatusChangedNotification"),
  ]

  /// Starts announcing call status changes. Called once, from the helper's `onLaunch`.
  static func observeCallStatus() {
    for name in callStatusNotifications {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        notification in
        let call = PostedCall(object: notification.object as AnyObject?)
        MainActor.assumeIsolated { callStatusChanged(call.object) }
      }
    }
  }

  /// Announces `object`'s status, unless it is not a call or its status has not moved.
  static func callStatusChanged(_ object: AnyObject?) {
    guard let object else { return }
    let call = decodeCall(object)
    guard !call.callUUID.isEmpty else { return }
    guard announcedStatus[call.callUUID] != call.status else { return }
    // A finished call is kept only until the next one finishes: long enough to absorb the
    // second notification for its disconnect, without growing for the life of FaceTime.
    if call.status == .disconnected {
      announcedStatus = announcedStatus.filter { $0.value != .disconnected }
    }
    announcedStatus[call.callUUID] = call.status
    BlueBubblesFaceTimeHelper.log.info("FaceTime call status is now \(call.status.rawValue)")
    emit(.faceTimeCallStatusChanged, callStatusPayload(call, details: object))
  }

  /// The call through `FaceTimeCall`'s codec, which the server's decoder reads, plus the
  /// details the reference's event carries that the codec does not model.
  ///
  /// Each `try?` is a detail this call cannot give: the key is left out, which the server
  /// reads as the reference's null or default for it. The call itself is still announced.
  static func callStatusPayload(_ call: FaceTimeCall, details object: AnyObject) -> WireObject {
    var payload = call.wire
    payload[.endedError] = (try? IMCoreRuntime.string(object, "endedErrorString")) ?? nil
    payload[.endedReason] = (try? IMCoreRuntime.string(object, "endedReasonString")) ?? nil
    payload[.imageURL] =
      ((try? IMCoreRuntime.send(object, "imageURL")) as? URL)?
      .absoluteString
    payload[.isOutgoing] = try? IMCoreRuntime.bool(object, "isOutgoing")
    payload[.isSendingAudio] = try? IMCoreRuntime.bool(object, "isSendingAudio")
    payload[.isSendingVideo] = try? IMCoreRuntime.bool(object, "isSendingVideo")
    return payload
  }
}

/// A notification's object, carried into the main actor.
///
/// Unchecked because a `TUCall` is an Objective-C object that TelephonyUtilities mutates. It
/// does not cross a thread: the observer runs on the main queue, and the main actor reads it
/// there.
private struct PostedCall: @unchecked Sendable {
  let object: AnyObject?
}
