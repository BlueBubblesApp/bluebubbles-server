//  HelperEventDecoder
//  Turns a helper's event frame into a typed `PrivateAPIEvent`.
//
//  The event NAMES are part of the compatibility contract: `started-typing`,
//  `aliases-removed` and the rest are what the shipping helper emits, and they live in
//  `HelperEventName`, in the contract, so the helper that emits one and this decoder that
//  switches over it spell it from one enum. The payload fields are read by `WireKey` for the
//  same reason.

import BBPrivateAPIContract
import Foundation
import Logging

enum HelperEventDecoder {

  /// Decodes one event.
  ///
  /// Returns nil for `ping`, which is registration rather than an event, and for anything
  /// unrecognised; both are the caller's to handle, because registration needs the
  /// connection and an unknown event is worth a log line.
  static func decode(name: String, payload: [String: WireJSON]) -> PrivateAPIEvent? {
    guard let known = HelperEventName(rawValue: name) else { return nil }

    switch known {
    case .ping:
      guard let process = payload[.process]?.stringValue, !process.isEmpty else { return nil }
      return .helperRegistered(
        process: process,
        protocolVersion: payload[.protocolVersion]?.intValue,
        // Which observation rung the helper attached to, or nil from a helper old
        // enough not to say. "none" means this macOS moved the listener surface and
        // inbound events are gone; worth reporting, because it is otherwise
        // indistinguishable from nobody having typed yet.
        eventRung: payload[.events]?.stringValue
      )

    case .startedTyping, .typing:
      guard let chat = payload[.chatGuid]?.stringValue else { return nil }
      return .typingChanged(chat: ChatIdentifier(chat), isTyping: true)

    case .stoppedTyping:
      guard let chat = payload[.chatGuid]?.stringValue else { return nil }
      return .typingChanged(chat: ChatIdentifier(chat), isTyping: false)

    case .aliasesRemoved:
      // Tolerates both shapes the helper has used: a list, or a single string.
      let aliases: [String]
      if let list = payload[.aliases]?.arrayValue {
        aliases = list.compactMap(\.stringValue)
      } else if let single = payload[.aliases]?.stringValue {
        aliases = [single]
      } else {
        aliases = []
      }
      return .iMessageAliasesRemoved(aliases: aliases)

    case .newFindMyLocation:
      return .findMyLocationUpdated(payload: flatten(payload))

    case .faceTimeCallStatusChanged:
      // The call is `FaceTimeCall`'s contract codec, the one the reply to
      // `facetime-active-calls` uses; the flattened payload rides along for the fields the
      // contract does not model. This server injects only its own helpers, which encode a
      // call with that codec wherever they send one; the Objective-C helper's `call_uuid` /
      // `call_status` spelling (with `handle` as an object) never reaches this socket, so no
      // fallback reads it. A call with no UUID is nothing a client can act on, and is dropped.
      guard let call = decoded(FaceTimeCall.self, from: payload, of: known),
        !call.callUUID.isEmpty
      else { return nil }
      return .faceTimeCallChanged(call: call, payload: flatten(payload))

    case .faceTimeMembershipChanged:
      // Each member is `FaceTimeMember`'s contract codec, the one the reply to
      // `facetime-members` uses.
      guard
        let fields = try? WireReader(event: known, fields: payload),
        let conversation = try? fields.string(.conversationUUID), !conversation.isEmpty,
        let members = try? fields.decodeList(.members, as: FaceTimeMember.self)
      else { return nil }
      return .faceTimeMembershipChanged(conversationUUID: conversation, members: members)
    }
  }

  /// A FaceTime event's fields through the contract's codec.
  ///
  /// Nil for an event the codec refuses: a helper from another build. Every `try?` in this
  /// decoder lands there, and the caller logs a nil as an unhandled event and drops it, which
  /// is all an unsolicited frame with nobody waiting on it can do; the same mismatch on a
  /// REPLY throws `protocolMismatch`.
  private static func decoded<T: WireCodable>(
    _ type: T.Type, from payload: [String: WireJSON], of event: HelperEventName
  ) -> T? {
    try? T(wire: WireReader(event: event, fields: payload))
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
        // `Int64(exactly:)`, because `Int64(_:)` traps on a whole number past its range.
        Int64(exactly: number).map(String.init) ?? String(number)
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
