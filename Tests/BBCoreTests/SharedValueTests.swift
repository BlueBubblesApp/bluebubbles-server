//  SharedValueTests
//  The values-and-formats utilities in BBCore: what each answers, at the edges its callers
//  depend on.

import BBCore
import Foundation
import Testing

@Suite("Constant-time comparison")
struct ConstantTimeTests {

  @Test("Equal inputs match, and any difference does not")
  func equality() {
    #expect(ConstantTime.equals("hunter2", "hunter2"))
    #expect(!ConstantTime.equals("hunter2", "hunter3"))
    #expect(ConstantTime.equals("", ""))
    #expect(ConstantTime.equals(Data([1, 2, 3]), Data([1, 2, 3])))
    #expect(!ConstantTime.equals(Data([1, 2, 3]), Data([1, 2, 4])))
  }

  /// The one length policy: a mismatch is folded in, so neither a prefix nor an extension
  /// of the secret matches, and neither does a shorter value padded with what the walk
  /// substitutes past the end.
  @Test("A length mismatch never matches")
  func lengthMismatch() {
    #expect(!ConstantTime.equals("hunter2", "hunter22"))
    #expect(!ConstantTime.equals("hunter2", "hunter"))
    #expect(!ConstantTime.equals("", "x"))
    #expect(!ConstantTime.equals([0x61], [0x61, 0x00]))
  }

  @Test("Strings compare as their UTF-8 bytes")
  func unicode() {
    #expect(ConstantTime.equals("pässwörd🔐", "pässwörd🔐"))
    #expect(!ConstantTime.equals("pässwörd🔐", "passwörd🔐"))
  }
}

@Suite("base64url and raw Ed25519 keys")
struct Base64URLTests {

  /// JWT uses base64url without padding. Plain base64 is silently accepted by some parsers
  /// and rejected by Google's.
  @Test("Encoding is base64url and unpadded")
  func encoding() {
    // Bytes chosen to produce both + and / in standard base64.
    let encoded = Base64URL.encode(Data([0xFB, 0xEF, 0xFF, 0x00]))
    #expect(encoded == "--__AA")
  }

  @Test("Decoding restores the padding JWS leaves off")
  func decoding() {
    for length in 0..<8 {
      let data = Data((0..<length).map { UInt8(0xF0 + $0) })
      #expect(Base64URL.decode(Base64URL.encode(data)) == data, "length \(length)")
    }
    // One past a multiple of four cannot be completed by any padding.
    #expect(Base64URL.decode("A") == nil)
    #expect(Base64URL.decode("not base64!") == nil)
  }

  @Test("A raw key is 32 bytes, trimmed of surrounding whitespace")
  func rawKey() throws {
    let bytes = Data(repeating: 0x42, count: 32)
    let encoded = "  \(bytes.base64EncodedString())\n"
    #expect(try Ed25519Keys.rawBytes(fromBase64: encoded) == bytes)
  }

  @Test("Each failure is told apart, because the callers word them differently")
  func failures() {
    #expect(throws: Ed25519Keys.ParseError.empty) {
      try Ed25519Keys.rawBytes(fromBase64: " \n")
    }
    #expect(throws: Ed25519Keys.ParseError.notBase64) {
      try Ed25519Keys.rawBytes(fromBase64: "not base64!")
    }
    #expect(throws: Ed25519Keys.ParseError.wrongLength(16)) {
      try Ed25519Keys.rawBytes(fromBase64: Data(count: 16).base64EncodedString())
    }
  }

  /// Sparkle exports the libsodium layout, the seed followed by the public key. Only a
  /// caller loading a PRIVATE key asks for it to be accepted.
  @Test("The 64-byte libsodium layout is the seed, and only when asked for")
  func libsodiumLayout() throws {
    let seed = Data(repeating: 0x11, count: 32)
    let encoded = (seed + Data(repeating: 0x22, count: 32)).base64EncodedString()
    #expect(
      try Ed25519Keys.rawBytes(fromBase64: encoded, acceptingLibsodiumSecretKey: true) == seed)
    #expect(throws: Ed25519Keys.ParseError.wrongLength(64)) {
      try Ed25519Keys.rawBytes(fromBase64: encoded)
    }
  }
}

@Suite("Epoch milliseconds")
struct EpochMillisecondsTests {

  @Test("The default truncates toward zero, as the reference's dates do")
  func truncates() {
    #expect(Date(timeIntervalSince1970: 1.2349).epochMilliseconds == 1234)
    #expect(Date(timeIntervalSince1970: -1.2349).epochMilliseconds == -1234)
  }

  @Test("A site that rounds says so, and gets what it asked for")
  func explicitRule() {
    let date = Date(timeIntervalSince1970: 1.2346)
    #expect(date.epochMilliseconds(rounded: .toNearestOrAwayFromZero) == 1235)
    #expect(date.epochMilliseconds(rounded: .down) == 1234)
    #expect(Date(timeIntervalSince1970: -1.2341).epochMilliseconds(rounded: .down) == -1235)
  }

  @Test("An Apple timestamp converts through the same rule")
  func appleTimestamp() {
    let stamp = AppleTimestamp(rawValue: 1_500_000_000, unit: .nanoseconds)
    #expect(stamp.epochMilliseconds == stamp.date?.epochMilliseconds)
  }
}

@Suite("The running version")
struct AppVersionTests {

  /// A test process has no bundle version, so this is the unbundled answer each reader
  /// relies on: nil for the readers that print nothing, the marker for the rest.
  @Test("An unbundled build is the development marker, never an empty string")
  func unbundled() {
    #expect(AppVersion.current == (AppVersion.bundled ?? AppVersion.developmentMarker))
    #expect(!AppVersion.current.isEmpty)
    #expect(SemanticVersion(AppVersion.developmentMarker) < SemanticVersion("0.0.1"))
  }
}

@Suite("Epoch milliseconds, read")
struct EpochMillisecondsReadingTests {

  @Test("A request value is read as the validator's numeric rule reads it")
  func readsWhatNumericAccepts() {
    let moment = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(Date(epochMilliseconds: JSONValue.int(1_700_000_000_000)) == moment)
    #expect(Date(epochMilliseconds: JSONValue.int64(1_700_000_000_000)) == moment)
    #expect(Date(epochMilliseconds: JSONValue.double(1_700_000_000_000)) == moment)
    // The case that was dropped: a numeric STRING passes `numeric` and must mean the same.
    #expect(Date(epochMilliseconds: JSONValue.string("1700000000000")) == moment)
  }

  @Test(
    "Anything else is no date, never a nonsense one",
    arguments: [
      JSONValue.string("soon"), .string("inf"), .string("nan"), .bool(true), .null,
      .array([]),
    ])
  func refusesTheRest(_ value: JSONValue) {
    #expect(Date(epochMilliseconds: value) == nil)
  }
}

@Suite("Hexadecimal")
struct HexTests {
  @Test("Two digits per byte, with the case asked for")
  func hex() {
    #expect([UInt8]([0x00, 0x0F, 0xA0, 0xFF]).hexString() == "000fa0ff")
    #expect([UInt8]([0x00, 0x0F, 0xA0, 0xFF]).hexString(uppercase: true) == "000FA0FF")
    #expect([UInt8]().hexString().isEmpty)
  }
}

@Suite("Loose booleans")
struct LooseBoolTests {
  @Test("One reading of a boolean written as text")
  func reading() {
    for text in ["1", "true", "YES", " True "] { #expect(Bool(loose: text) == true) }
    for text in ["0", "false", "No"] { #expect(Bool(loose: text) == false) }
    for text in ["", "maybe", "2", "on"] { #expect(Bool(loose: text) == nil) }
  }
}
