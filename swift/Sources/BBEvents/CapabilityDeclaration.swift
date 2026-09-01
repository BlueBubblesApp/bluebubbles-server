//  CapabilityDeclaration
//  How a delivery target says what it can accept.
//
//  Four kinds of target declare capability four different ways, and that is not an accident
//  of history — many installs have no FCM at all, so FCM registration cannot be the place
//  where codec support is declared:
//
//    | Target            | Declares via                                          |
//    |-------------------|-------------------------------------------------------|
//    | Socket client     | handshake query parameter `codecs=`                   |
//    | Paired device     | `supportedCodecs` + `publicKey` at enrollment          |
//    | FCM device        | optional fields on `POST /api/v1/fcm/device`          |
//    | Webhook / ntfy    | a per-target column in its config row                 |
//
//  Every path funnels into `TargetCapabilities`, so negotiation has one shape to reason
//  about, and every path defaults to `legacy-v1` when it says nothing — which is what every
//  existing client says.
//
//  See `docs/EVENTS.md`.

import BBSerialization
import Foundation

extension TargetCapabilities {

  /// Parses the socket handshake's `codecs=` parameter.
  ///
  /// - Parameter raw: A comma-separated list, e.g. `sealed-v2,reference-v2`. Absent, empty,
  ///   or entirely unrecognised all mean legacy — a client that sends nonsense gets the
  ///   behaviour it has today rather than an error, because failing a handshake over an
  ///   unknown codec name would break clients we have not shipped yet.
  public static func fromSocketHandshake(
    codecs raw: String?,
    publicKey encodedKey: String? = nil
  ) -> TargetCapabilities {
    TargetCapabilities(
      supportedCodecs: parseCodecList(raw),
      publicKey: decodePublicKey(encodedKey)
    )
  }

  /// Parses the optional fields on `POST /api/v1/fcm/device` and on device enrollment.
  ///
  /// Both carry the same two fields, so they share a parser — the difference between them
  /// is which table the row lands in, not what it means.
  public static func fromRegistration(_ body: JSONValue) -> TargetCapabilities {
    let declared: Set<CodecIdentifier>
    if let list = body["supportedCodecs"]?.arrayValue {
      let parsed = Set(list.compactMap(\.stringValue).map { CodecIdentifier($0) })
      declared = parsed.isEmpty ? [.legacyV1] : parsed.union([.legacyV1])
    } else {
      declared = parseCodecList(body["supportedCodecs"]?.stringValue)
    }

    return TargetCapabilities(
      supportedCodecs: declared,
      publicKey: decodePublicKey(body["publicKey"]?.stringValue)
    )
  }

  /// A comma-separated list, with legacy always included.
  ///
  /// legacy-v1 is unioned in unconditionally: every client can read it by definition, and
  /// including it means negotiation always has something to fall back to rather than
  /// having to special-case an empty set.
  public static func parseCodecList(_ raw: String?) -> Set<CodecIdentifier> {
    guard let raw, !raw.isEmpty else { return [.legacyV1] }
    let names =
      raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !names.isEmpty else { return [.legacyV1] }
    return Set(names.map { CodecIdentifier($0) }).union([.legacyV1])
  }

  /// Decodes a base64 X25519 public key.
  ///
  /// Length is checked here rather than at first use: an X25519 key is exactly 32 bytes,
  /// and accepting anything else means the failure surfaces during a send, where it looks
  /// like a delivery problem instead of a registration problem.
  public static func decodePublicKey(_ encoded: String?) -> Data? {
    guard let encoded, !encoded.isEmpty,
      let data = Data(base64Encoded: encoded),
      data.count == 32
    else { return nil }
    return data
  }
}

// MARK: - Advertisement

/// What `GET /api/v1/server/info` reports, so clients can discover what is on offer.
public struct CodecAdvertisement: Sendable, Equatable {
  /// Every codec this server could use.
  public let supported: [String]
  /// The server's preference ceiling — what a fully-capable client would actually get.
  public let preferred: String

  public init(supported: [String], preferred: String) {
    self.supported = supported
    self.preferred = preferred
  }

  /// The two fields added to `server/info`.
  ///
  /// Additive, so they are absent under a default configuration — the parity harness diffs
  /// strictly in both directions, and an added key fails it just as a missing one does.
  ///
  /// Gated on the PREFERENCE, not on how many codecs are registered. Those are different
  /// questions and conflating them is a parity break: the composition root registers all
  /// three codecs so the ceiling can be raised without a rebuild, so a default server has
  /// three registered and exactly one reachable. Advertising on the count made a
  /// stock server announce `sealed-v2` it would never actually use — caught by curling
  /// `server/info` on a default build, not by any unit test.
  public func fields(includeWhenLegacyOnly: Bool = false) -> [String: JSONValue] {
    guard includeWhenLegacyOnly || preferred != CodecIdentifier.legacyV1.rawValue else {
      return [:]
    }
    return [
      "supported_payload_codecs": .array(supported.map { .string($0) }),
      "payload_codec": .string(preferred),
    ]
  }
}

extension CodecNegotiator {
  public var advertisement: CodecAdvertisement {
    CodecAdvertisement(
      supported: supportedIdentifiers,
      preferred: serverPreference.rawValue
    )
  }

  /// Every codec, for a server that has opted into the alternates.
  ///
  /// - Parameter preference: The ceiling. Left at `.legacyV1` this registers the codecs
  ///   without using them, which is exactly the "built to be switchable, not switched"
  ///   default the plan requires.
  public static func full(
    preference: CodecIdentifier = .legacyV1,
    hint: NotificationHint = .none
  ) -> CodecNegotiator {
    CodecNegotiator(
      serverPreference: preference,
      codecs: [
        LegacyPayloadCodec(),
        ReferencePayloadCodec(hint: hint),
        SealedPayloadCodec(hint: hint),
      ]
    )
  }
}
