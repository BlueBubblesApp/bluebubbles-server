//  CapabilityDeclaration
//  How a delivery target says what it can accept.
//
//  Four kinds of target declare capability four different ways, and that is not an accident
//  of history: many installs have no FCM at all, so FCM registration cannot be the place
//  where codec support is declared:
//
//    | Target            | Declares via                                          |
//    |-------------------|-------------------------------------------------------|
//    | Socket client     | handshake query parameters `codecs=` and `publicKey=` |
//    | Paired device     | `supportedCodecs` + `publicKey` at enrollment          |
//    | FCM device        | nothing yet: `POST /api/v1/fcm/device` reads neither   |
//    | Webhook / ntfy    | a per-target column in its config row                 |
//
//  Every path funnels into `TargetCapabilities`, and the ones that arrive as request input
//  go through ONE parser, `declared`, so the socket and the HTTP surface cannot disagree
//  about what a declaration means: whether a list may be a string, whether the key is read,
//  how a malformed one degrades. Every path defaults to `legacy-v1` when it says nothing,
//  which is what every existing client says.
//
//  The FCM row is a gap rather than a design: `declared` takes that body's fields as readily
//  as enrollment's and the device table has the columns, but no push provider negotiates per
//  device yet, so reading the fields there would store a declaration nothing consults.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBSerialization
import Foundation

extension TargetCapabilities {

  /// The handshake query parameters a declaration travels under. A registration body names
  /// the same key `publicKey` and the list `supportedCodecs`; the handler spells those where
  /// it reads them, which is where the parameter-parity checks look for them.
  public enum DeclarationKey {
    /// The handshake's comma-separated list.
    public static let handshakeCodecs = "codecs"
    /// The X25519 public key, base64 (standard or URL-safe alphabet).
    public static let publicKey = "publicKey"
  }

  /// THE parser. Everything a client can declare, from whichever transport carried it.
  ///
  /// - Parameters:
  ///   - codecs: A JSON array of names, a comma-separated string, or nothing. Absent, empty,
  ///     or entirely unrecognised all mean legacy: a client that sends nonsense gets the
  ///     behaviour it has today rather than an error, because failing a handshake or a
  ///     registration over an unknown codec name would break clients we have not shipped yet.
  ///   - publicKey: Base64 of exactly 32 bytes, or nil. A wrong length reads as no key, which
  ///     the negotiator answers by falling back from `sealed-v2` to `reference-v2`.
  public static func declared(codecs: JSONValue?, publicKey: String?) -> TargetCapabilities {
    let names: [String]
    switch codecs {
    case .array(let list)?: names = list.compactMap(\.stringValue)
    case .string(let list)?: names = list.split(separator: ",").map(String.init)
    default: names = []
    }
    return TargetCapabilities(
      supportedCodecs: codecSet(names),
      publicKey: decodePublicKey(publicKey)
    )
  }

  /// The socket handshake's query parameters.
  ///
  /// **The key is read as well as the list.** Without it a socket client could never be
  /// offered `sealed-v2`: `CodecNegotiator.resolve` skips that codec for a target with no key,
  /// so a declaration of `sealed-v2` would quietly mean `reference-v2` whatever the server's
  /// ceiling. The effect is narrow by construction: a frame changes only on a server whose
  /// `event_payload_codec` was raised to `sealed-v2` (the default is `legacy-v1`), for a
  /// client that sent both parameters. Every other socket client's frames are byte-identical.
  ///
  /// The handshake query is decoded once, `+` as a space (`QueryStringDecoder`), so a key in
  /// the standard base64 alphabet must be percent-encoded; the URL-safe alphabet needs no
  /// encoding at all, which is why `decodePublicKey` accepts both.
  public static func fromSocketHandshake(
    codecs raw: String?,
    publicKey encodedKey: String? = nil
  ) -> TargetCapabilities {
    declared(codecs: raw.map(JSONValue.string), publicKey: encodedKey)
  }

  /// A comma-separated list, with legacy always included.
  public static func parseCodecList(_ raw: String?) -> Set<CodecIdentifier> {
    codecSet(raw.map { $0.split(separator: ",").map(String.init) } ?? [])
  }

  /// Names as identifiers, trimmed, empties dropped, with legacy always included.
  ///
  /// legacy-v1 is unioned in unconditionally: every client can read it by definition, and
  /// including it means negotiation always has something to fall back to rather than
  /// having to special-case an empty set.
  static func codecSet(_ names: [String]) -> Set<CodecIdentifier> {
    let identifiers =
      names
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { CodecIdentifier($0) }
    return Set(identifiers).union([.legacyV1])
  }

  /// Decodes a base64 X25519 public key, in the standard or the URL-safe alphabet.
  ///
  /// Length is checked here rather than at first use: an X25519 key is exactly 32 bytes,
  /// and accepting anything else means the failure surfaces during a send, where it looks
  /// like a delivery problem instead of a registration problem.
  ///
  /// The URL-safe alphabet (RFC 4648 section 5, padding optional) is accepted because the
  /// socket carries the key in a query string, where a standard `+` arrives as a space and a
  /// `/` or `=` invites a client to get the escaping wrong. `Base64URL.decode` reads both
  /// alphabets: the URL-safe characters are mapped, and the standard ones pass through.
  public static func decodePublicKey(_ encoded: String?) -> Data? {
    guard let encoded, !encoded.isEmpty else { return nil }
    guard let data = Base64URL.decode(encoded), data.count == 32 else { return nil }
    return data
  }
}

// MARK: - Advertisement

/// What `GET /api/v1/server/info` reports, so clients can discover what is on offer.
public struct CodecAdvertisement: Sendable, Equatable {
  /// Every codec this server could use.
  public let supported: [String]
  /// The server's preference ceiling: what a fully-capable client would actually get.
  public let preferred: String

  public init(supported: [String], preferred: String) {
    self.supported = supported
    self.preferred = preferred
  }

  /// The two fields added to `server/info`.
  ///
  /// Additive, so they are absent under a default configuration: the parity harness diffs
  /// strictly in both directions, and an added key fails it just as a missing one does.
  ///
  /// Gated on the PREFERENCE, not on how many codecs are registered. Those are different
  /// questions and conflating them is a parity break: the composition root registers all
  /// three codecs so the ceiling can be raised without a rebuild, so a default server has
  /// three registered and exactly one reachable. Advertising on the count would make a
  /// stock server announce `sealed-v2` it would never use.
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
