//  FaceTimeDispatch
//  Wire action -> FaceTimeBridge, the FaceTime peer of the Messages helper's HelperDispatch.
//
//  Same shape as the Messages dispatch: it turns an action name and a payload back into a
//  typed call, and encodes the reply in the contract's vocabulary. It handles ONLY FaceTime
//  actions: this dylib is injected into FaceTime.app, and the server routes FaceTime actions
//  to this connection, so an action it does not recognise is a genuine "unknown action,"
//  reported distinctly from an unavailable one.

import BBPrivateAPIContract
import Foundation
import HelperShared

enum FaceTimeDispatch {

  /// Runs one request and returns its payload, if any.
  ///
  /// `@MainActor` for the same reason the Messages dispatch is: TelephonyUtilities, like
  /// IMCore, asserts the main queue and traps off it, so the hop happens once here at the
  /// boundary rather than being re-derived in every call.
  @MainActor
  static func perform(_ request: HelperProtocol.Request) async throws -> WireObject? {
    let data = request.data ?? [:]

    func string(_ key: WireKey) throws -> String {
      guard let value = data[key]?.stringValue else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "\(request.action) requires '\(key)'"
        )
      }
      return value
    }
    func optionalString(_ key: WireKey) -> String? { data[key]?.stringValue }

    guard let action = FaceTimeHelperAction(rawValue: request.action) else {
      // A protocol mismatch, not a missing feature. The server should not be routing a
      // non-FaceTime action here at all (the typed transport overloads make that
      // unexpressible) so this is version skew between server and helper.
      throw PrivateAPIError.rejectedByMessages(
        reason: "unknown action '\(request.action)'"
      )
    }

    switch action {

    case .generateLink:
      // `callUUID` present → a link for an existing call (Flow B/C); absent → a fresh
      // link (Flow A). One action for both, matching the shipping helper.
      if let callUUID = optionalString(.callUUID) {
        return encode(try await FaceTimeBridge.generateLink(forCall: callUUID))
      }
      let invited = (data[.addresses]?.arrayValue ?? []).compactMap(\.stringValue)
      return encode(try await FaceTimeBridge.generateLink(invitedAddresses: invited))

    case .dialFaceTime:
      let addresses = (data[.addresses]?.arrayValue ?? []).compactMap(\.stringValue)
      let call = try await FaceTimeBridge.dial(
        FaceTimeStartRequest(addresses: addresses, video: data[.video]?.boolValue ?? true)
      )
      return [.call: encode(call)]

    case .answerCall:
      try await FaceTimeBridge.answer(callUUID: try string(.callUUID))
      return nil

    case .leaveCall:
      try await FaceTimeBridge.leave(callUUID: try string(.callUUID))
      return nil

    case .admitPendingMember:
      try await FaceTimeBridge.admit(
        conversationUUID: try string(.conversationUUID),
        handle: try string(.handleUUID)
      )
      return nil

    case .faceTimeMembers:
      let members = try await FaceTimeBridge.members(
        conversationUUID: try string(.conversationUUID)
      )
      return [.members: members.map(encode)]

    case .faceTimeActiveCalls:
      return [.calls: try await FaceTimeBridge.activeCalls().map(encode)]

    case .faceTimeCallStatus:
      return [
        .callStatus: try await FaceTimeBridge.callStatus(
          callUUID: try string(.callUUID)
        ).rawValue
      ]

    case .faceTimeWindows:
      return [.windows: await MainActor.run { FaceTimeBridge.windowSummaries() }]

    case .faceTimeDismissAlert:
      return [.dismissed: await MainActor.run { FaceTimeBridge.dismissBlockingAlerts() }]

    case .faceTimeDebug:
      // Free-form by design: a diagnostic dump of whatever the bridge found, keyed by what
      // it found. The server reads every field it gets. The one reply not built from
      // `WireKey`, and the initialiser's label says so.
      return WireObject(
        untyped: try await FaceTimeBridge.debugState(
          conversationUUID: try string(.conversationUUID)
        ))

    case .silenceFaceTimeCall:
      let state = try await FaceTimeBridge.silence(callUUID: try string(.callUUID))
      return [.muted: state.muted, .sendingVideo: state.sendingVideo]

    case .invalidateFaceTimeLinks:
      // `urls` absent → invalidate all created links.
      let urls = data[.urls]?.arrayValue?.compactMap(\.stringValue)
      let invalidated = try await FaceTimeBridge.invalidateLinks(matching: urls)
      return [.invalidated: invalidated]

    }
  }

  // MARK: - Encoding

  private static func encode(_ link: FaceTimeLink) -> WireObject {
    WireObject([
      .url: link.url,
      .groupUUID: link.groupUUID,
      .name: link.name,
      .expiresAt: link.expiresAt.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) },
    ])
  }

  private static func encode(_ call: FaceTimeCall) -> WireObject {
    WireObject([
      .callUUID: call.callUUID,
      .callStatus: call.status.rawValue,
      .status: call.status.name,
      .handle: call.handle?.value,
      .displayName: call.handle?.displayName,
      .groupUUID: call.groupUUID,
      .isVideo: call.isVideo,
      .callerIDBlocked: call.callerIDBlocked,
    ])
  }

  private static func encode(_ member: FaceTimeMember) -> WireObject {
    WireObject([
      .handle: member.handle.value,
      .displayName: member.handle.displayName,
      .nickname: member.nickname,
      .isActive: member.isActive,
      .isLightweight: member.isLightweight,
      .isPending: member.isPending,
      .isWaitingToBeLetIn: member.isWaitingToBeLetIn,
      .joinedFromLetMeIn: member.joinedFromLetMeIn,
    ])
  }

  // MARK: - Error text

  /// Error text for the wire. See `PrivateAPIError.wireDescription(of:app:)` for the rule
  /// it has to keep; never an empty string.
  static func describe(_ error: any Error) -> String {
    PrivateAPIError.wireDescription(of: error, app: "FaceTime")
  }
}
