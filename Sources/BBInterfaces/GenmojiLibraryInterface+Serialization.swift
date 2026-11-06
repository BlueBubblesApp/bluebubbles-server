//  GenmojiLibraryInterface+Serialization
//  The Genmoji library routes' wire shapes.
//
//  v2, so our own fields are `snake_case`. A listed Genmoji carries no bytes: the images are
//  their own requests, by identifier, so a client that already holds one never downloads it
//  again.

import BBCore
import BBIMessage
import Foundation

extension GenmojiLibraryInterface {

  /// One entry of `GET genmoji/library`.
  public static func serialize(_ genmoji: GenmojiRow) -> JSONValue {
    .object([
      "identifier": .string(genmoji.identifier),
      "description": .string(genmoji.description),
      "language": genmoji.languageIdentifier.map(JSONValue.string) ?? .null,
      "created_at": milliseconds(genmoji.createdAt),
      "last_used_at": milliseconds(genmoji.lastUsedAt),
      // Saved first, the shelf that syncs, so the order says something rather than nothing.
      "shelves": .array(
        StickerShelf.allCases.reversed().filter(genmoji.shelves.contains)
          .map { .string($0.rawValue) }),
      "sticker_identifiers": .array(genmoji.stickerIdentifiers.map(JSONValue.string)),
      "sizes": .array(
        Array(Set(genmoji.renditions.map(\.width))).sorted().map(JSONValue.int)),
    ])
  }

  /// `DELETE genmoji/library/:id`.
  public static func serialize(_ deleted: Deleted) -> JSONValue {
    .object([
      "identifier": .string(deleted.identifier),
      "sticker_identifiers": .array(deleted.stickerIdentifiers.map(JSONValue.string)),
    ])
  }

  /// One image, inline, for the batch route.
  public static func serialize(_ image: Image) -> JSONValue {
    .object([
      "identifier": .string(image.identifier),
      "content_type": .string(image.contentType),
      "width": .int(image.width),
      "height": .int(image.height),
      "byte_count": .int(image.data.count),
      "data": .string(image.data.base64EncodedString()),
    ])
  }

  /// `POST genmoji/library/images`.
  public static func serialize(_ batch: Batch) -> JSONValue {
    .object([
      "images": .array(batch.images.map(serialize)),
      "missing": .array(batch.missing.map(JSONValue.string)),
    ])
  }

  private static func milliseconds(_ date: Date?) -> JSONValue {
    guard let date else { return .null }
    return .int(Int(date.epochMilliseconds))
  }
}
