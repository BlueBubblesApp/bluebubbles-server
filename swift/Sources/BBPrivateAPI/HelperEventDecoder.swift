//  HelperEventDecoder
//  Turns a helper's event frame into a typed `PrivateAPIEvent`.
//
//  Shared by both transports on purpose. The event NAMES are part of the compatibility
//  contract — `started-typing`, `aliases-removed` and the rest are what the shipping helper
//  emits — so the Swift helper keeps them rather than inventing a cleaner set. Two decoders
//  would be two places for that vocabulary to drift.

import BBPrivateAPIContract
import Foundation
import Logging

enum HelperEventDecoder {

  /// Event names the helper can send. Listed explicitly so an unhandled one is visible
  /// rather than silently dropped.
  enum Name: String {
    case ping
    case startedTyping = "started-typing"
    /// The shipping helper emits both spellings for the same thing.
    case typing
    case stoppedTyping = "stopped-typing"
    case aliasesRemoved = "aliases-removed"
    case newFindMyLocation = "new-findmy-location"
    case faceTimeCallStatusChanged = "ft-call-status-changed"
    case faceTimeMembershipChanged = "ft-members-changed"
  }

  /// Decodes one event.
  ///
  /// Returns nil for `ping`, which is registration rather than an event, and for anything
  /// unrecognised — both are the caller's to handle, because registration needs the
  /// connection and an unknown event is worth a log line.
  static func decode(name: String, payload: [String: WireJSON]) -> PrivateAPIEvent? {
    guard let known = Name(rawValue: name) else { return nil }

    switch known {
    case .ping:
      guard let process = payload["process"]?.stringValue, !process.isEmpty else { return nil }
      return .helperRegistered(
        process: process,
        protocolVersion: payload["protocolVersion"]?.intValue,
        // Which observation rung the helper attached to, or nil from a helper old
        // enough not to say. "none" means this macOS moved the listener surface and
        // inbound events are gone — worth reporting, because it is otherwise
        // indistinguishable from nobody having typed yet.
        eventRung: payload["events"]?.stringValue
      )

    case .startedTyping, .typing:
      guard let chat = payload["chatGuid"]?.stringValue else { return nil }
      return .typingChanged(chat: ChatIdentifier(chat), isTyping: true)

    case .stoppedTyping:
      guard let chat = payload["chatGuid"]?.stringValue else { return nil }
      return .typingChanged(chat: ChatIdentifier(chat), isTyping: false)

    case .aliasesRemoved:
      // Tolerates both shapes the helper has used: a list, or a single string.
      let aliases: [String]
      if let list = payload["aliases"]?.arrayValue {
        aliases = list.compactMap(\.stringValue)
      } else if let single = payload["aliases"]?.stringValue {
        aliases = [single]
      } else {
        aliases = []
      }
      return .iMessageAliasesRemoved(aliases: aliases)

    case .newFindMyLocation:
      return .findMyLocationUpdated(payload: flatten(payload))

    case .faceTimeCallStatusChanged:
      // The helper sends `callUUID` and a numeric `callStatus`; parse them into a typed
      // call, and keep the flattened payload for the fields the contract does not model.
      let flat = flatten(payload)
      guard
        let uuid = payload["callUUID"]?.stringValue
          ?? payload["call_uuid"]?.stringValue, !uuid.isEmpty
      else { return nil }
      let call = FaceTimeCall(
        callUUID: uuid,
        status: FaceTimeCallStatus(
          raw: payload["callStatus"]?.intValue ?? payload["call_status"]?.intValue ?? 0
        ),
        handle: payload["handle"]?.stringValue.map {
          FaceTimeHandle(value: $0, displayName: payload["displayName"]?.stringValue)
        },
        groupUUID: payload["groupUUID"]?.stringValue,
        isVideo: payload["isVideo"]?.boolValue ?? true,
        callerIDBlocked: payload["callerIDBlocked"]?.boolValue ?? false
      )
      return .faceTimeCallChanged(call: call, payload: flat)

    case .faceTimeMembershipChanged:
      guard let conversation = payload["conversationUUID"]?.stringValue,
        !conversation.isEmpty
      else { return nil }
      let members = (payload["members"]?.arrayValue ?? []).compactMap { entry -> FaceTimeMember? in
        guard let address = entry["handle"]?.stringValue, !address.isEmpty else { return nil }
        return FaceTimeMember(
          handle: FaceTimeHandle(
            value: address, displayName: entry["displayName"]?.stringValue
          ),
          nickname: entry["nickname"]?.stringValue,
          isPending: entry["isPending"]?.boolValue ?? false
        )
      }
      return .faceTimeMembershipChanged(conversationUUID: conversation, members: members)
    }
  }

  /// Flattens to `[String: String]`, which is the contract's payload shape.
  ///
  /// Scalars become their obvious string form; anything structured is re-encoded as JSON
  /// rather than dropped, so a payload the contract does not model yet still reaches the
  /// caller intact.
  static func flatten(_ payload: [String: WireJSON]) -> [String: String] {
    payload.compactMapValues { value in
      switch value {
      case .string(let string):
        string
      case .number(let number):
        number == number.rounded() ? String(Int64(number)) : String(number)
      case .bool(let flag):
        String(flag)
      case .null:
        nil
      case .array, .object:
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
      }
    }
  }
}
