//  GamePigeonCodec
//  Reading and writing Game Pigeon's payload.
//
//  Game Pigeon is an ordinary iMessage app (`AppMessagePayload`), so the envelope is the
//  same one Polls uses. What is its own is the `URL`:
//
//      data:?ver=<N>&data=<scrambled>
//
//  `data` is a **permutation of a plain URL query string** — not encryption, not
//  compression. The permutation is a Fisher-Yates shuffle driven by `drand48` seeded with
//  `length * 0xEF`, so the only key is the string's own length and it reverses with no
//  secret at all. Unscrambled, the body is:
//
//      ?sender=<id>&version=5&game=pool&id=<session>&player=1&player2=<id>&replay=…
//
//  Written from the format, measured against real Game Pigeon threads on a Mac — the
//  round-trip test is what keeps it honest, and `docs/GAME_PIGEON.md` records what was
//  observed and how. This is an interoperability reimplementation: no third-party code.
//
//  The FIELDS are deliberately not modelled. Every game puts what it likes in there — pool
//  sends a physics `replay`, word games send letter grids — so this layer hands back a
//  dictionary and lets the client decide what a game means.

import Foundation

public enum GamePigeonCodec {

  /// The extension's bundle id suffix. The full `balloon_bundle_id` is the usual
  /// `com.apple.messages.MSMessageExtensionBalloonPlugin:<team>:<this>`, and the team id
  /// belongs to the developer, so a suffix match is what identifies it.
  public static let extensionSuffix = "com.gamerdelights.gamepigeon.ext"
  /// Its App Store id, which the archive carries as `appid`.
  public static let appStoreID = 1_124_197_642

  public static func isGamePigeon(balloonBundleID: String?) -> Bool {
    balloonBundleID?.hasSuffix(extensionSuffix) ?? false
  }

  /// A decoded payload: the wire version and every field, in order.
  public struct Payload: Equatable, Sendable {
    /// `ver` from the URL — Game Pigeon's own format version (45, 49, 50, 52 seen).
    public var version: Int
    /// The query string's fields, in the order they appeared.
    public var fields: [(name: String, value: String)]

    public init(version: Int, fields: [(name: String, value: String)]) {
      self.version = version
      self.fields = fields
    }

    public subscript(name: String) -> String? {
      fields.first { $0.name == name }?.value
    }

    /// The game, when the payload names one. An invite often does not — the caption says
    /// which game it is and the first move names it.
    public var game: String? { self["game"] }
    /// Game Pigeon's own session id, distinct from the `MSSession` UUID.
    public var gameID: String? { self["id"] }

    public static func == (lhs: Payload, rhs: Payload) -> Bool {
      lhs.version == rhs.version && lhs.fields.map(\.name) == rhs.fields.map(\.name)
        && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }
  }

  // MARK: - The shuffle

  /// `drand48`, which is what seeds the permutation. Reimplemented because Foundation's
  /// `drand48` is process-global state and this has to be re-seeded per string.
  struct Rand48 {
    private var state: UInt64 = 0
    private static let mask: UInt64 = (1 << 48) - 1

    init(seed: Int) { state = ((UInt64(truncatingIfNeeded: seed) << 16) &+ 0x330e) & Self.mask }

    mutating func next() -> Double {
      state = (25_214_903_917 &* state &+ 11) & Self.mask
      return Double(state) / Double(1 << 48)
    }
  }

  private static func seed(for length: Int) -> Int { length &* 0xEF }

  /// Scrambles a plain payload the way Game Pigeon does: draw characters out of the
  /// remaining pool at a random index, one at a time.
  public static func scramble(_ plain: String) -> String {
    var random = Rand48(seed: seed(for: plain.count))
    var remaining = Array(plain)
    var out = String.UnicodeScalarView()
    out.reserveCapacity(plain.unicodeScalars.count)
    var result = ""
    result.reserveCapacity(plain.count)
    for _ in 0..<remaining.count {
      let index = Int(floor(random.next() * Double(remaining.count)))
      guard remaining.indices.contains(index) else { break }
      result.append(remaining.remove(at: index))
    }
    return result
  }

  /// Reverses `scramble`. The draws depend only on the length, so they can be replayed and
  /// undone without knowing the plaintext.
  public static func unscramble(_ scrambled: String) -> String {
    let characters = Array(scrambled)
    var random = Rand48(seed: seed(for: characters.count))
    var offsets: [Int] = []
    offsets.reserveCapacity(characters.count)
    var modifier = 0
    for _ in characters {
      offsets.append(Int(floor(random.next() * Double(modifier + characters.count))))
      modifier -= 1
    }
    var out: [Character] = []
    out.reserveCapacity(characters.count)
    for (i, offset) in offsets.reversed().enumerated() {
      let source = characters.count - i - 1
      guard offset >= 0, offset <= out.count, characters.indices.contains(source) else {
        continue
      }
      out.insert(characters[source], at: offset)
    }
    return String(out)
  }

  // MARK: - The URL

  /// Decodes a Game Pigeon `data:` URL. Nil when it is not one.
  public static func decode(url: String) -> Payload? {
    guard url.hasPrefix("data:"), let query = url.firstIndex(of: "?") else { return nil }
    let outer = AppPayloadURL.parseQuery(String(url[url.index(after: query)...]))
    guard let scrambled = outer.first(where: { $0.name == "data" })?.value else { return nil }
    let version = outer.first { $0.name == "ver" }.flatMap { Int($0.value) } ?? 0
    let plain = unscramble(scrambled)
    // The unscrambled body is itself a query string, leading `?` and all.
    let body = plain.hasPrefix("?") ? String(plain.dropFirst()) : plain
    return Payload(version: version, fields: AppPayloadURL.parseQuery(body))
  }

  /// Builds a Game Pigeon `data:` URL from fields.
  public static func encode(_ payload: Payload) -> String {
    let body =
      "?"
      + payload.fields
      .map { "\(AppPayloadURL.escape($0.name))=\(AppPayloadURL.escape($0.value))" }
      .joined(separator: "&")
    return "data:?ver=\(payload.version)&data=\(AppPayloadURL.escape(scramble(body)))"
  }
}
