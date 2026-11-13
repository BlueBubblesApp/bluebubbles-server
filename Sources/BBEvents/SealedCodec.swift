//  SealedCodec
//  sealed-v2: the full payload, encrypted to the device that will read it.
//
//  Why not a shared passphrase
//  ---------------------------
//  AES with the server password as a shared key is one key for every device, no forward
//  secrecy, and no separation of confidentiality from integrity: anyone holding the
//  password can both read and forge payloads, and a password change invalidates everything
//  at once.
//
//  The construction here
//  ---------------------
//  Per message: a fresh ephemeral X25519 keypair on the server, agreed against the device's
//  registered public key, run through HKDF-SHA256, and used once with ChaCha20-Poly1305.
//
//    - **Forward secrecy per message.** The ephemeral private key is discarded immediately,
//      so a later compromise of the device's long-term key does not decrypt captured traffic.
//    - **AEAD, not just encryption.** The routing metadata that stays in the clear (the
//      version and the event name) is passed as additional authenticated data, so an
//      attacker cannot relabel a sealed `typing-indicator` as a `new-message`. Encrypting
//      without binding the plaintext header is a standard way to get this wrong.
//    - **A fresh nonce per message**, from the system CSPRNG. Nonce reuse under ChaCha20 is
//      catastrophic rather than merely bad, which is why it is never derived from a counter
//      here.
//
//  Layered on reference-v2 rather than replacing it: the envelope keeps the same plaintext
//  routing fields, so a server can hold a mixed fleet and the two codecs interoperate at the
//  routing level.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBSerialization
import Crypto
import Foundation

public enum SealedPayloadError: BBError, Equatable {
  /// The target advertised sealed-v2 but registered no key. The negotiator falls back
  /// before reaching here; this exists so a direct call cannot silently send plaintext.
  case missingPublicKey
  /// The target's key could not be used: the wrong length, or a point no agreement can be
  /// made with. The TARGET's to fix, by registering again.
  case invalidPublicKey
  /// This server could not seal a payload with a key it accepted. Ours to fix.
  case encryptionFailed
  /// An envelope handed to `open` is not one this codec produced.
  case malformedEnvelope
}

public struct SealedPayloadCodec: EventPayloadCodec {

  public let identifier = CodecIdentifier.sealedV2

  /// Names the whole construction, so a future change is a new value rather than a silent
  /// reinterpretation of the same bytes.
  public static let algorithm = "x25519-chacha20poly1305"

  /// Domain separation for HKDF. Two protocols sharing a key agreement must not derive the
  /// same key, and this is what keeps them apart.
  static let hkdfInfo = Data("bluebubbles-sealed-v2".utf8)

  private let hint: NotificationHint

  /// - Parameter hint: Applies to the PLAINTEXT part only. Defaults to `.none`, and that
  ///   default matters more here than for reference-v2: a user who chose an encrypted codec
  ///   has expressed a preference that content not travel in the clear, and a hint would
  ///   put some of it back.
  public init(hint: NotificationHint = .none) {
    self.hint = hint
  }

  public func encode(
    _ event: ServerEvent,
    projection: PayloadProjection,
    capabilities: TargetCapabilities
  ) async throws -> EncodedPayload {
    guard let publicKeyData = capabilities.publicKey else {
      throw SealedPayloadError.missingPublicKey
    }
    let sealed = try Self.seal(
      payload: event.payload(for: projection),
      eventName: event.name.rawValue,
      occurredAt: event.occurredAt,
      to: publicKeyData,
      hint: hint
    )
    return EncodedPayload(codec: identifier, body: sealed)
  }

  /// Builds the sealed envelope.
  ///
  /// Split out and internal so the tests can exercise it against a known keypair, which is
  /// the only way to assert that what comes out actually decrypts.
  static func seal(
    payload: JSONValue,
    eventName: String,
    occurredAt: Date,
    to publicKeyData: Data,
    hint: NotificationHint,
    ephemeralKey: Curve25519.KeyAgreement.PrivateKey? = nil
  ) throws -> JSONValue {
    let recipient: Curve25519.KeyAgreement.PublicKey
    do {
      recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
    } catch {
      throw SealedPayloadError.invalidPublicKey
    }

    // Fresh per message. The parameter exists only so a test can pin a vector; production
    // always generates.
    let ephemeral = ephemeralKey ?? Curve25519.KeyAgreement.PrivateKey()

    // The agreement fails only for a recipient key that is a low-order point, which yields
    // an all-zero secret: a bad KEY, the target's, not a failure to encrypt. The ephemeral
    // half is freshly generated and cannot be the cause.
    let symmetricKey: SymmetricKey
    do {
      let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
      // The ephemeral public key is the salt, which binds the derived key to this
      // exact exchange.
      symmetricKey = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: ephemeral.publicKey.rawRepresentation,
        sharedInfo: hkdfInfo,
        outputByteCount: 32
      )
    } catch {
      throw SealedPayloadError.invalidPublicKey
    }

    // The plaintext header. Everything here is visible to Google, and everything here is
    // authenticated, so it can be read but not altered.
    var header: [String: JSONValue] = [
      "v": .int(2),
      "t": .string(eventName),
      "alg": .string(algorithm),
      "ts": .int64(occurredAt.epochMilliseconds),
    ]
    // The same hints reference-v2 sends, from the same reader.
    header.merge(NotificationHints(payload: payload).fields(for: hint)) { $1 }

    let plaintext = try payload.serialize()
    let sealedBox: ChaChaPoly.SealedBox
    do {
      sealedBox = try ChaChaPoly.seal(
        plaintext,
        using: symmetricKey,
        nonce: ChaChaPoly.Nonce(),
        // The header is bound to the ciphertext. Without this an attacker could take
        // a sealed typing-indicator and relabel it a new-message: the body would
        // still decrypt, and the client would act on a header nobody signed.
        authenticating: try authenticatedData(for: header)
      )
    } catch {
      throw SealedPayloadError.encryptionFailed
    }

    var envelope = header
    envelope["epk"] = .string(ephemeral.publicKey.rawRepresentation.base64EncodedString())
    envelope["n"] = .string(Data(sealedBox.nonce).base64EncodedString())
    // Ciphertext and tag together, which is what `combined` gives and what the client
    // feeds straight back to its own AEAD open.
    envelope["ct"] = .string((sealedBox.ciphertext + sealedBox.tag).base64EncodedString())
    return .object(envelope)
  }

  /// The additional authenticated data: the plaintext header, as one canonical byte string.
  ///
  /// Both sides must produce identical bytes or every tag check fails, and the receiver
  /// rebuilds them from a header it has PARSED, so the form has to be a specification a
  /// client can implement, not whatever a JSON library happens to emit. It is written out
  /// here rather than delegated to `JSONSerialization`, whose escaping is a library default
  /// rather than an option (it writes `/` as `\/`, which most other encoders do not, and the
  /// preview hint is message text, where a `/` is common) and whose `.sortedKeys` order is
  /// not byte order.
  ///
  /// The form, which is the one `JSONSerialization` with `.sortedKeys` produced for every
  /// header this codec writes, so nothing already implemented against it changes:
  ///
  /// - `{`, then each `"key":value` joined by `,` with no whitespace, then `}`.
  /// - Keys in ascending order of their UTF-8 bytes. (Every key this codec writes is
  ///   lowercase ASCII, where that and Foundation's order agree.)
  /// - A string in double quotes, its UTF-8 written as is except: `"` as `\"`, `\` as `\\`,
  ///   `/` as `\/`, U+0008 `\b`, U+0009 `\t`, U+000A `\n`, U+000C `\f`, U+000D `\r`, and any
  ///   other code point below U+0020 as `\u00xx` in lowercase hex.
  /// - An integer in decimal; `true` and `false` for a boolean.
  ///
  /// Anything else in a header (a fraction, a null, a nested value) is not one this codec
  /// writes, and is refused as a malformed envelope rather than given a form of its own.
  /// `SealedCodecTests.authenticatedDataVector` pins the bytes.
  static func authenticatedData(for header: [String: JSONValue]) throws -> Data {
    var bytes: [UInt8] = [UInt8(ascii: "{")]
    let keys = header.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    for (index, key) in keys.enumerated() {
      if index > 0 { bytes.append(UInt8(ascii: ",")) }
      appendString(key, to: &bytes)
      bytes.append(UInt8(ascii: ":"))
      switch header[key] {
      case .string(let value)?: appendString(value, to: &bytes)
      case .int(let value)?: bytes.append(contentsOf: String(value).utf8)
      case .int64(let value)?: bytes.append(contentsOf: String(value).utf8)
      case .bool(let value)?: bytes.append(contentsOf: (value ? "true" : "false").utf8)
      default: throw SealedPayloadError.malformedEnvelope
      }
    }
    bytes.append(UInt8(ascii: "}"))
    return Data(bytes)
  }

  private static func appendString(_ string: String, to bytes: inout [UInt8]) {
    bytes.append(UInt8(ascii: "\""))
    for byte in string.utf8 {
      switch byte {
      case UInt8(ascii: "\""): bytes.append(contentsOf: #"\""#.utf8)
      case UInt8(ascii: "\\"): bytes.append(contentsOf: #"\\"#.utf8)
      case UInt8(ascii: "/"): bytes.append(contentsOf: #"\/"#.utf8)
      case 0x08: bytes.append(contentsOf: #"\b"#.utf8)
      case 0x09: bytes.append(contentsOf: #"\t"#.utf8)
      case 0x0A: bytes.append(contentsOf: #"\n"#.utf8)
      case 0x0C: bytes.append(contentsOf: #"\f"#.utf8)
      case 0x0D: bytes.append(contentsOf: #"\r"#.utf8)
      case ..<0x20:
        let hex = String(byte, radix: 16)
        bytes.append(contentsOf: (#"\u00"# + (hex.count == 1 ? "0" : "") + hex).utf8)
      default:
        // Every byte of a multi-byte sequence is 0x80 or above, so non-ASCII passes
        // through whole.
        bytes.append(byte)
      }
    }
    bytes.append(UInt8(ascii: "\""))
  }

  /// Opens a sealed envelope. The client's half of the protocol.
  ///
  /// Present in the server for one reason: it is what the tests use to prove that what the
  /// encoder produced can actually be decrypted, and that a tampered envelope cannot. A
  /// codec verified only against itself proves nothing.
  public static func open(
    envelope: JSONValue,
    using privateKey: Curve25519.KeyAgreement.PrivateKey
  ) throws -> JSONValue {
    guard case .object(let fields) = envelope,
      let epk = fields["epk"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
      let nonceData = fields["n"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
      let combined = fields["ct"]?.stringValue.flatMap({ Data(base64Encoded: $0) })
    else { throw SealedPayloadError.malformedEnvelope }

    let ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk)
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
    let symmetricKey = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: epk,
      sharedInfo: hkdfInfo,
      outputByteCount: 32
    )

    // The header is everything except the three ciphertext fields: exactly what the
    // sealer authenticated.
    var header = fields
    for key in ["epk", "n", "ct"] { header.removeValue(forKey: key) }

    // The tag is the trailing 16 bytes of `combined`.
    guard combined.count > 16 else { throw SealedPayloadError.malformedEnvelope }
    let box = try ChaChaPoly.SealedBox(
      nonce: ChaChaPoly.Nonce(data: nonceData),
      ciphertext: combined.prefix(combined.count - 16),
      tag: combined.suffix(16)
    )
    let plaintext = try ChaChaPoly.open(
      box, using: symmetricKey, authenticating: try authenticatedData(for: header)
    )
    return try JSONValue.parse(plaintext)
  }
}

extension SealedPayloadError {
  public var code: String {
    switch self {
    case .missingPublicKey: "codec.missing_public_key"
    case .invalidPublicKey: "codec.invalid_public_key"
    case .encryptionFailed: "codec.encryption_failed"
    case .malformedEnvelope: "codec.malformed_envelope"
    }
  }

  public var domain: String { "Events" }

  public var title: String { "An event could not be sealed" }

  public var body: String {
    switch self {
    case .missingPublicKey:
      "The target has not published a public key, so its payload cannot be encrypted."
    case .invalidPublicKey:
      "The target's public key could not be read."
    case .encryptionFailed:
      "The payload could not be encrypted."
    case .malformedEnvelope:
      "The sealed envelope is missing a field or is not one this server produced."
    }
  }
}
