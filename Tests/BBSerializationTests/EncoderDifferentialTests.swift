import Foundation
import Testing

@testable import BBSerialization

/// The encoder, against `JSONSerialization`, on randomly generated payloads.
///
/// Replacing an encoder is the change most able to break a frozen wire quietly, and a
/// hand-written case list only covers what its author thought of. This generates the awkward
/// things instead: every JSON escape, control bytes, NUL, U+2028, emoji, CJK, subnormal and
/// huge doubles, negative zero, `Int64` extremes, and nesting to four levels.
///
/// Compared by PARSING both and requiring the same value, not by comparing bytes: key order
/// in a `[String: JSONValue]` is arbitrary and always has been, and the two paths deliberately
/// differ on double spelling (shortest round-trip, matching the reference server, where
/// Foundation writes seventeen significant digits).
///
/// Fixed seed, so a failure is reproducible and the suite is not flaky.
@Suite("Encoder differential")
struct EncoderDifferentialTests {
  /// A deterministic PRNG, so a failure is reproducible from its seed.
  struct Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }
  }

  static func value(_ rng: inout Rng, depth: Int) -> JSONValue {
    let pick = Int.random(in: 0..<10, using: &rng)
    switch pick {
    case 0: return .null
    case 1: return .bool(Bool.random(using: &rng))
    case 2: return .int(Int.random(in: -1_000_000...1_000_000, using: &rng))
    case 3: return .int64(Int64.random(in: Int64.min...Int64.max, using: &rng))
    case 4:
      // Every shape of finite double, including subnormals and huge magnitudes.
      let choices: [Double] = [
        0, -0.0, 1, -1, 0.1, 1.0 / 3, 1e-300, 1e300, 2.2250738585072014e-308,
        Double(Int64.max), Double.leastNormalMagnitude, Double.greatestFiniteMagnitude,
        Double(bitPattern: rng.next() >> 12),
      ]
      let d = choices[Int.random(in: 0..<choices.count, using: &rng)]
      return d.isFinite ? .double(d) : .double(0)
    case 5, 6:
      // Strings containing everything awkward: escapes, control bytes, emoji, CJK.
      let alphabet: [Character] = [
        "a", "\"", "\\", "/", "\n", "\t", "\r", "\u{08}", "\u{0C}", "\u{01}", "\u{1F}",
        "\u{7F}", "é", "😀", "中", "\u{2028}", " ", "\u{00}",
      ]
      let n = Int.random(in: 0..<12, using: &rng)
      return .string(
        String((0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }))
    case 7 where depth < 4:
      let n = Int.random(in: 0..<4, using: &rng)
      return .array((0..<n).map { _ in value(&rng, depth: depth + 1) })
    case 8 where depth < 4:
      let n = Int.random(in: 0..<4, using: &rng)
      var object: [String: JSONValue] = [:]
      for i in 0..<n { object["k\(i)"] = value(&rng, depth: depth + 1) }
      return .object(object)
    default: return .string("plain")
    }
  }

  @Test("Randomly generated payloads agree with the Foundation path")
  func differential() throws {
    var rng = Rng(state: 0x5EED)
    var checked = 0
    for iteration in 0..<2_000 {
      // Wrapped in an object: JSONSerialization rejects bare fragments by default.
      let payload = JSONValue.object(["v": Self.value(&rng, depth: 0)])
      let direct = try payload.serialize()
      let viaFoundation = try JSONSerialization.data(
        withJSONObject: payload.foundationObject, options: [])
      let a = try JSONValue.parse(direct)
      let b = try JSONValue.parse(viaFoundation)
      if a != b {
        Issue.record(
          "iteration \(iteration) diverged:\n  direct=\(String(decoding: direct, as: UTF8.self))\n  found =\(String(decoding: viaFoundation, as: UTF8.self))"
        )
        return
      }
      checked += 1
    }
    #expect(checked == 2_000)
  }
}
