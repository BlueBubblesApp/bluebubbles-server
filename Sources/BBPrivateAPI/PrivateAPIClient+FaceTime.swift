//  PrivateAPIClient+FaceTime
//  The `FaceTimeControl` role: links, calls and their members, through the FaceTime
//  helper.
//
//  One slice of `PrivateAPIClient`; the type, its transport and the payload shapes every
//  role shares are in `PrivateAPIClient.swift`.

import BBPrivateAPIContract
import Foundation

extension PrivateAPIClient: FaceTimeControl {

  // Action names match the Objective-C helper's where one exists (`generate-link`,
  // `answer-call`, `leave-call`, `admit-pending-member`) so an older FaceTime helper
  // understands them; the new ones (`dial-facetime`, `facetime-members`) are additive. The
  // helper answers in the contract's vocabulary: the narrowing happens in-process.

  public func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink {
    let data: WireJSON =
      invitedAddresses.isEmpty
      ? .emptyObject
      : .object([.addresses: .array(invitedAddresses.map(WireJSON.string))])
    let result = try await transport.request(
      action: .generateLink, data: data
    )
    return try FaceTimeLink(reply: result, to: .generateLink)
  }

  public func generateFaceTimeLinkForCall(callUUID: String) async throws -> FaceTimeLink {
    let result = try await transport.request(
      action: .generateLink, data: .object([.callUUID: .string(callUUID)])
    )
    return try FaceTimeLink(reply: result, to: .generateLink)
  }

  public func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall {
    let result = try await transport.request(
      action: .dialFaceTime,
      data: .object([
        .addresses: .array(request.addresses.map { .string($0) }),
        .video: .bool(request.video),
      ]))
    let call = try WireReader(reply: result, to: .dialFaceTime)
      .decode(.call, as: FaceTimeCall.self)
    // TelephonyUtilities can hand back a call object with no UUID; that is FaceTime placing
    // nothing a client could answer or leave, not a reply in the wrong shape.
    guard !call.callUUID.isEmpty else {
      throw PrivateAPIError.rejectedByMessages(reason: "the helper placed no call")
    }
    return call
  }

  public func answerFaceTimeCall(callUUID: String) async throws {
    try await transport.request(
      action: .answerCall, data: .object([.callUUID: .string(callUUID)])
    )
  }

  public func leaveFaceTimeCall(callUUID: String) async throws {
    try await transport.request(
      action: .leaveCall, data: .object([.callUUID: .string(callUUID)])
    )
  }

  public func admitFaceTimeParticipant(conversationUUID: String, handle: String) async throws {
    try await transport.request(
      action: .admitPendingMember,
      data: .object([
        // Field spellings are the shipping helper's: `conversationUUID` / `handleUUID`.
        .conversationUUID: .string(conversationUUID),
        .handleUUID: .string(handle),
      ]))
  }

  public func faceTimeMembers(conversationUUID: String) async throws -> [FaceTimeMember] {
    let result = try await transport.request(
      action: .faceTimeMembers,
      data: .object([.conversationUUID: .string(conversationUUID)])
    )
    return try WireReader(reply: result, to: .faceTimeMembers).decodeList(.members)
  }

  public func silenceFaceTimeCall(callUUID: String) async throws -> (
    muted: Bool, sendingVideo: Bool
  ) {
    let result = try await transport.request(
      action: .silenceFaceTimeCall,
      data: .object([.callUUID: .string(callUUID)])
    )
    let reply = try WireReader(reply: result, to: .silenceFaceTimeCall)
    return (muted: try reply.bool(.muted), sendingVideo: try reply.bool(.sendingVideo))
  }

  public func faceTimeActiveCalls() async throws -> [FaceTimeCall] {
    let result = try await transport.request(
      action: .faceTimeActiveCalls, data: .emptyObject
    )
    // A call with no UUID cannot be answered, left or linked, so it is not listed.
    return try WireReader(reply: result, to: .faceTimeActiveCalls)
      .decodeList(.calls, as: FaceTimeCall.self)
      .filter { !$0.callUUID.isEmpty }
  }

  public func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus {
    let result = try await transport.request(
      action: .faceTimeCallStatus,
      data: .object([.callUUID: .string(callUUID)])
    )
    return FaceTimeCallStatus(
      raw: try WireReader(reply: result, to: .faceTimeCallStatus).int(.callStatus))
  }

  public func faceTimeWindows() async throws -> [String] {
    let result = try await transport.request(
      action: .faceTimeWindows, data: .emptyObject
    )
    return try WireReader(reply: result, to: .faceTimeWindows).strings(.windows)
  }

  public func dismissFaceTimeAlert() async throws -> Int {
    let result = try await transport.request(
      action: .faceTimeDismissAlert, data: .emptyObject
    )
    return try WireReader(reply: result, to: .faceTimeDismissAlert).int(.dismissed)
  }

  public func faceTimeDebugState(conversationUUID: String) async throws -> [String: String] {
    let result = try await transport.request(
      action: .faceTimeDebug,
      data: .object([.conversationUUID: .string(conversationUUID)])
    )
    // Free-form: every key is whatever the bridge found, so none is required, and an empty
    // dump is an empty answer.
    return try WireReader(reply: result, to: .faceTimeDebug).stringFields
  }

  public func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String] {
    let data: WireJSON =
      urls.map { list in
        WireJSON.object([.urls: .array(list.map(WireJSON.string))])
      } ?? .emptyObject
    let result = try await transport.request(
      action: .invalidateFaceTimeLinks, data: data
    )
    return try WireReader(reply: result, to: .invalidateFaceTimeLinks).strings(.invalidated)
  }
}
