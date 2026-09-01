//  PayloadCodec
//  Encoding as the final stage of delivery, behind a protocol.
//
//  Because it sits at the SINK boundary rather than at the emit site, no event producer ever
//  changes when the codec changes — which is the property that makes an encrypted payload
//  format shippable at all. The current design has no such seam: FCM payload construction is
//  inline in fcmService, so `encrypt_coms` had to reach into it and ended up force-disabled.
//
//  Selection is per-delivery-target and negotiated, not a global flip. One event can produce
//  a legacy-v1 socket frame, a sealed-v2 FCM payload, and a legacy-v1 webhook POST in the
//  same fan-out — which is what makes this deployable against a fleet that will never fully
//  upgrade.
//
//  See `docs/EVENTS.md`.

import BBSerialization
import Foundation

public struct CodecIdentifier: Hashable, Sendable, RawRepresentable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }

  /// The default, and byte-identical to what ships today.
  public static let legacyV1 = CodecIdentifier("legacy-v1")
  /// Identifiers only; the client hydrates over the authenticated API.
  public static let referenceV2 = CodecIdentifier("reference-v2")
  /// reference-v2's envelope with the body sealed under X25519 + ChaCha20-Poly1305.
  public static let sealedV2 = CodecIdentifier("sealed-v2")

  /// Preference order, strongest first. Negotiation takes the best both sides support.
  public static let preferenceOrder: [CodecIdentifier] = [.sealedV2, .referenceV2, .legacyV1]
}

/// What a delivery target can accept.
public struct TargetCapabilities: Sendable {
  public let supportedCodecs: Set<CodecIdentifier>
  /// X25519 public key, when the target registered one. Absent means sealed-v2 is not
  /// available for it however much it claims to support the codec.
  public let publicKey: Data?

  public init(supportedCodecs: Set<CodecIdentifier> = [.legacyV1], publicKey: Data? = nil) {
    self.supportedCodecs = supportedCodecs
    self.publicKey = publicKey
  }

  /// A target that declared nothing. Every existing client is one of these.
  public static let legacy = TargetCapabilities()
}

public struct EncodedPayload: Sendable {
  public let codec: CodecIdentifier
  /// For the socket: emitted as the raw argument to `emit(name, payload)`.
  /// For FCM: becomes `{type, data: <this, stringified>}`.
  /// For webhooks: becomes `{type, data: <this>}`.
  public let body: JSONValue

  public init(codec: CodecIdentifier, body: JSONValue) {
    self.codec = codec
    self.body = body
  }
}

public protocol EventPayloadCodec: Sendable {
  var identifier: CodecIdentifier { get }
  /// `projection` decides full-vs-trimmed; the codec decides encoding. Keeping them apart
  /// is what lets a sealed FCM payload and a plaintext socket frame carry the same event.
  func encode(
    _ event: ServerEvent,
    projection: PayloadProjection,
    capabilities: TargetCapabilities
  ) async throws -> EncodedPayload
}

// MARK: - legacy-v1

/// The default. Emits the serialized object unchanged.
///
/// There is deliberately nothing clever here — its correctness criterion is byte-identity
/// with recorded Node fixtures, and anything this codec "improves" is a client break.
public struct LegacyPayloadCodec: EventPayloadCodec {

  public let identifier = CodecIdentifier.legacyV1

  public init() {}

  public func encode(
    _ event: ServerEvent,
    projection: PayloadProjection,
    capabilities: TargetCapabilities
  ) async throws -> EncodedPayload {
    EncodedPayload(codec: identifier, body: event.payload(for: projection))
  }
}

// MARK: - Negotiation

public struct CodecNegotiator: Sendable {

  /// The server's preference CEILING, not its choice. A target still gets legacy-v1 unless
  /// it asks for more.
  public let serverPreference: CodecIdentifier
  private let codecs: [CodecIdentifier: any EventPayloadCodec]

  public init(serverPreference: CodecIdentifier = .legacyV1, codecs: [any EventPayloadCodec]) {
    self.serverPreference = serverPreference
    self.codecs = Dictionary(uniqueKeysWithValues: codecs.map { ($0.identifier, $0) })
  }

  /// The default configuration: legacy only, for every target.
  public static func legacyOnly() -> CodecNegotiator {
    CodecNegotiator(serverPreference: .legacyV1, codecs: [LegacyPayloadCodec()])
  }

  /// Resolves `min(serverPreference, targetSupport)`.
  ///
  /// Note the ceiling is applied first: with `serverPreference == .legacyV1`, a target
  /// advertising sealed-v2 still gets legacy-v1. That is what makes the default-off
  /// enforcement structural — a client cannot opt itself into a codec the server has not
  /// enabled.
  public func resolve(for capabilities: TargetCapabilities) -> any EventPayloadCodec {
    let ceilingIndex = CodecIdentifier.preferenceOrder.firstIndex(of: serverPreference) ?? 0
    let allowed = CodecIdentifier.preferenceOrder[ceilingIndex...]

    for candidate in allowed {
      guard capabilities.supportedCodecs.contains(candidate),
        let codec = codecs[candidate]
      else { continue }
      // sealed-v2 without a key is not sealed-v2. Falling through to reference-v2 is
      // the documented behavior; failing the delivery would be worse.
      if candidate == .sealedV2 && capabilities.publicKey == nil { continue }
      return codec
    }

    return codecs[.legacyV1] ?? LegacyPayloadCodec()
  }

  /// Advertised on `GET /api/v1/server/info` as `supported_payload_codecs`.
  public var supportedIdentifiers: [String] {
    CodecIdentifier.preferenceOrder
      .filter { codecs[$0] != nil }
      .map(\.rawValue)
  }
}
