//  BBPrivateAPIContract: Events
//  What the helper reports back, unprompted.
//
//
//  Inbound events are NOT polled. The helper observes them from inside Messages.app; see
//  `EventObservation` and `docs/OBSERVATION_LADDER.md`. That mechanism is the most
//  version-fragile part of the port, and a moved selector must cost the event, never the
//  process.

import Foundation

public enum PrivateAPIEvent: Sendable {
  /// Sent by the helper immediately on connect, carrying its bundle identifier.
  /// Sent by the helper immediately on connect.
  ///
  /// `eventRung` names the observation ladder rung it managed to attach to
  /// (`"daemon-listener"`, or `"none"`), and is nil from a helper that predates the field.
  case helperRegistered(process: String, protocolVersion: Int?, eventRung: String?)
  /// The helper's socket closed. Raised by the transport, never sent by a helper: a process
  /// that crashed or was quit says nothing on the way out.
  case helperDisconnected(process: String)
  case typingChanged(chat: ChatIdentifier, isTyping: Bool)
  case iMessageAliasesRemoved(aliases: [String])
  case findMyLocationUpdated(payload: [String: String])
  /// A call changed state. Carries the parsed call, so a client sees `incoming` /
  /// `answered` / `disconnected` as a typed status rather than a magic number. The raw
  /// payload is still forwarded for fields the contract does not model.
  case faceTimeCallChanged(call: FaceTimeCall, payload: [String: String])
  /// A conversation's membership changed: someone joined, or is knocking. This is the
  /// signal Flows B and C wait on before the Mac drops: dropping on a timer instead is what
  /// hangs up on the caller.
  case faceTimeMembershipChanged(conversationUUID: String, members: [FaceTimeMember])
}
