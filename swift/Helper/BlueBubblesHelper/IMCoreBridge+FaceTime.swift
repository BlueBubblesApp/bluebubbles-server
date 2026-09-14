//  IMCoreBridge+FaceTime
//  FaceTime, which is NOT implemented here: this helper is injected into Messages,
//  and TelephonyUtilities' call machinery traps in any host but FaceTime.app. Every method
//  below says so through one shared error rather than pretending to be unported.
//  `FaceTimeControl`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  //
  // The Messages helper CANNOT do FaceTime: TelephonyUtilities' call machinery is registered
  // by FaceTime.app and traps in any other host. FaceTime lives in the dedicated
  // BlueBubblesFaceTimeHelper, injected into FaceTime.app, and the server routes FaceTime
  // actions to that connection. These conformances exist only because IMCoreBridge is the
  // type that satisfies PrivateAPI; from the Messages host they report, honestly, that
  // FaceTime is not available here.
  private func faceTimeUnavailable(_ method: String) -> PrivateAPIError {
    .unavailableOnThisOS(
      method: method,
      requires: "the FaceTime helper (injected into FaceTime.app); the Messages helper "
        + "cannot reach TelephonyUtilities"
    )
  }

  public func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink {
    throw faceTimeUnavailable("generateFaceTimeLink")
  }

  public func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall {
    throw faceTimeUnavailable("dialFaceTime")
  }

  public func generateFaceTimeLinkForCall(callUUID: String) async throws -> FaceTimeLink {
    throw faceTimeUnavailable("generateFaceTimeLinkForCall")
  }

  public func answerFaceTimeCall(callUUID: String) async throws {
    throw faceTimeUnavailable("answerFaceTimeCall")
  }

  public func leaveFaceTimeCall(callUUID: String) async throws {
    throw faceTimeUnavailable("leaveFaceTimeCall")
  }

  public func admitFaceTimeParticipant(conversationUUID: String, handle: String) async throws {
    throw faceTimeUnavailable("admitFaceTimeParticipant")
  }

  public func faceTimeMembers(conversationUUID: String) async throws -> [FaceTimeMember] {
    throw faceTimeUnavailable("faceTimeMembers")
  }

  public func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String] {
    throw faceTimeUnavailable("invalidateFaceTimeLinks")
  }

  public func silenceFaceTimeCall(callUUID: String) async throws -> (
    muted: Bool, sendingVideo: Bool
  ) {
    throw faceTimeUnavailable("silenceFaceTimeCall")
  }

  public func faceTimeDebugState(conversationUUID: String) async throws -> [String: String] {
    throw faceTimeUnavailable("faceTimeDebugState")
  }

  public func faceTimeActiveCalls() async throws -> [FaceTimeCall] {
    throw faceTimeUnavailable("faceTimeActiveCalls")
  }

  public func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus {
    throw faceTimeUnavailable("faceTimeCallStatus")
  }

  public func faceTimeWindows() async throws -> [String] {
    throw faceTimeUnavailable("faceTimeWindows")
  }

  public func dismissFaceTimeAlert() async throws -> Int {
    throw faceTimeUnavailable("dismissFaceTimeAlert")
  }
}
