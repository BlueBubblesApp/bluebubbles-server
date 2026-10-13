//  StickerInterface+Serialization
//  The sticker routes' wire shapes, projected from the store's rows.
//
//  Here rather than in the handlers so the app and the tests reach the projection the routes
//  send, and so a handler stays parse, call, serialize.

import BBCore
import BBIMessage
import BBPrivateAPIContract
import BBSystem
import Foundation

extension StickerInterface {

  /// What `sticker.save` answers when the store took the sticker and cannot be read back.
  ///
  /// A named function rather than an object literal, because it is a
  /// SHAPE a client has to decode and a literal is invisible to the OpenAPI table, which
  /// would then document the readable-store shape, with `identifier`, `kind` and `effect`
  /// required, for a response that carries none of them and does carry `saved`.
  /// `StickerResponseShapeTests` holds this against `ResponseBodies`.
  public static func serializeUnreadable(_ saved: SavedSticker) -> JSONValue {
    .object([
      "external_uri": .string(saved.externalURI),
      "byte_count": .int(saved.byteCount),
      "shelf": .string(StickerShelf.recent.rawValue),
      // Present only on this shape: the other fields cannot say on their own that the
      // save SUCCEEDED, and the identifier a client would look for is deliberately absent.
      "saved": .bool(true),
    ])
  }

  public static func serialize(_ sticker: StickerRow) -> JSONValue {
    .object([
      "identifier": .string(sticker.identifier),
      "shelf": .string(sticker.shelf.rawValue),
      "external_uri": .string(sticker.externalURI),
      // What the URI's first path component says this is: `emoji`, `memoji` or `user`.
      // Derived here rather than left to every client to parse the URI itself.
      "kind": .string(Self.kind(of: sticker.externalURI)),
      "name": sticker.name.map(JSONValue.string) ?? .null,
      "accessibility_name": sticker.accessibilityName.map(JSONValue.string) ?? .null,
      "search_text": sticker.searchText.map(JSONValue.string) ?? .null,
      "byte_count": .int(sticker.byteCount),
      "effect": .int(sticker.effect),
      "created_at": Self.milliseconds(sticker.createdAt),
      "last_used_at": Self.milliseconds(sticker.lastUsedAt),
      "library_index": sticker.libraryIndex.map(JSONValue.double) ?? .null,
      "attribution_name": sticker.attributionName.map(JSONValue.string) ?? .null,
      "attribution_bundle_id": sticker.attributionBundleID.map(JSONValue.string) ?? .null,
      "representations": .array(sticker.representations.map(Self.serialize)),
    ])
  }

  public static func serialize(_ representation: StickerRepresentationRow) -> JSONValue {
    .object([
      "identifier": .string(representation.identifier),
      "role": .string(representation.role),
      "uti": .string(representation.uti),
      "mime_type": .string(FileTypes.mimeType(forIdentifier: representation.uti)),
      "width": .double(representation.width),
      "height": .double(representation.height),
      "byte_count": .int(representation.byteCount),
      "is_preferred": .bool(representation.isPreferred),
    ])
  }

  /// `sticker:///memoji/cow/…` → `memoji`. `unknown` for a URI in a shape this does not
  /// recognise, which is the honest answer for a scheme Apple adds later.
  public static func kind(of externalURI: String) -> String {
    guard let components = URL(string: externalURI)?.pathComponents else { return "unknown" }
    let named = components.first { $0 != "/" && !$0.isEmpty }
    switch named {
    case "emoji", "memoji", "user": return named ?? "unknown"
    default: return named?.isEmpty == false ? "unknown" : "unknown"
    }
  }

  fileprivate static func milliseconds(_ date: Date?) -> JSONValue {
    guard let date else { return .null }
    return .int(Int(date.epochMilliseconds))
  }
}
