//  ReactionWireType
//  `associatedMessageType` is a STRING on the wire, not the integer chat.db stores.
//
//  This was found by diffing a live Electron server against this one: `message.query` returned
//  `"associatedMessageType": 0` here and `null` there, on every message. The cause is a TypeORM
//  transformer (`databases/transformers/MessageTypeTransformer.ts`) that the port had no
//  counterpart for — the column is declared `type: "text"` on the entity and mapped through
//  `ReactionIdToString` on the way out, so what a client has always received is `"love"`,
//  `"-like"`, or `null`.
//
//  The consequence is not cosmetic. Every client branches on this value to render a tapback,
//  so emitting `2000` where a client expects `"love"` means reactions stop rendering — and it
//  fails silently, because the key is present and the type is plausible.
//
//  The write path already had these numbers right (`ReactionType.associatedMessageType` in
//  `BBPrivateAPIContract`, transcribed from the helper). This is the read half, and it lives
//  here rather than being shared with that enum for two reasons: `BBSerialization` must not
//  depend on the Private API contract, and this map is strictly larger — it carries `sticker`
//  and a numeric fallback that the send path has no use for.
//
//  See `.claude/docs/api.md`.

import Foundation

public enum ReactionWireType {

  /// Transcribed from `ReactionIdToString`.
  ///
  /// 2000-series adds a tapback, 3000-series removes the corresponding one, and the removal
  /// is spelled with a leading `-`. `sticker` is the odd one out and is not a tapback at
  /// all.
  private static let names: [Int: String] = [
    1000: "sticker",
    2000: "love", 2001: "like", 2002: "dislike",
    2003: "laugh", 2004: "emphasize", 2005: "question",
    3000: "-love", 3001: "-like", 3002: "-dislike",
    3003: "-laugh", 3004: "-emphasize", 3005: "-question",
  ]

  /// The wire value, or nil for "not an association" — which reaches the client as an
  /// explicit `null`, not an absent key.
  ///
  /// An unrecognised id becomes its own DIGITS AS A STRING rather than nil or a number.
  /// That looks like a mistake and is the reference's behaviour exactly
  /// (`dbValue.toString()`): Apple adds association types, and a client that has learned to
  /// switch on this field copes better with an unknown string than with a type change
  /// halfway down the range. Returning nil instead would erase the distinction between "no
  /// association" and "an association this server has not heard of".
  public static func name(for associatedMessageType: Int) -> String? {
    if associatedMessageType == 0 { return nil }
    return names[associatedMessageType] ?? String(associatedMessageType)
  }
}
