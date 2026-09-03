//  StickerHandlers
//  This Mac's sticker library: listing it, downloading from it, adding to it.
//
//  The three reads go straight to `stickers.stickerdb` through `StickerRepository` and need
//  no Private API, so they work on a Mac with no helper. The write needs the helper, because
//  the store's container is entitled to `com.apple.stickersd.group` and this server is not.
//
//  A Mac with no store at all is not an error: `stickers.stickerdb` does not exist until the
//  user has had a sticker, and a Mac without Full Disk Access cannot read the container it
//  lives in. Both answer with an empty list and a `metadata.reason` saying which, rather
//  than a 500 that a client cannot tell from a broken server. See `docs/STICKER_LIBRARY.md`.

import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

public enum StickerHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some StickerLibraryProviding & PrivateAPIProviding & UploadStoring
  ) {

    /// The library, newest first.
    ///
    /// `?source=` selects a shelf — `saved`, `recent`, or `all`, which is the default
    /// because a client showing the user "my stickers" wants the whole picker rather than
    /// half of it. Every row says which shelf it came from, so one request is enough to
    /// render both sections.
    ///
    /// No bytes here, deliberately. The store keeps the image inline in the same table, and
    /// a page of six stickers is already two megabytes of base64 — so the list is metadata
    /// and `:id/image` is the download.
    registry.register(.stickerList) { request in
      let shelves = try Self.shelves(request)
      guard let library = await context.stickerLibrary() else {
        return .data(
          .array([]), metadata: .object(["count": .int(0), "reason": .string(Self.absent)]))
      }
      let limit = min(max(request.integer("limit") ?? 100, 1), 1000)
      let offset = max(request.integer("offset") ?? 0, 0)
      let stickers = try await library.stickers(shelves: shelves, limit: limit, offset: offset)
      let counts = try await library.counts()

      // Both totals reported whatever `?source=` asked for, because a client rendering one
      // section still wants to know whether the other has anything in it.
      return .data(
        .array(stickers.map(Self.serialize)),
        metadata: .object([
          "count": .int(stickers.count),
          "limit": .int(limit),
          "offset": .int(offset),
          "total": .int(shelves.reduce(0) { $0 + (counts[$1] ?? 0) }),
          "saved": .int(counts[.saved] ?? 0),
          "recent": .int(counts[.recent] ?? 0),
        ])
      )
    }

    /// One sticker's metadata, including every representation it has.
    registry.register(.stickerDetail) { request in
      let identifier = try request.requirePathParameter("id")
      guard let library = await context.stickerLibrary() else {
        throw NotFound(Self.absent)
      }
      guard let sticker = try await library.sticker(identifier: identifier) else {
        throw NotFound("this Mac has no sticker with identifier \(identifier)")
      }
      return .data(Self.serialize(sticker))
    }

    /// The image itself.
    ///
    /// `?role=` picks a representation: `still` for the full-size one, `keyboard` for the
    /// picker thumbnail, or the store's own role string. Omitted takes the preferred one,
    /// which is the full-size image. A role this sticker does not have falls back to
    /// preferred rather than 404ing — "no thumbnail" is not "no sticker", and a client
    /// asking for a thumbnail wants an image either way.
    registry.register(.stickerImage) { request in
      let identifier = try request.requirePathParameter("id")
      guard let library = await context.stickerLibrary() else {
        throw NotFound(Self.absent)
      }
      guard
        let image = try await library.bytes(
          identifier: identifier, role: Self.role(request.queryParameters["role"])
        )
      else {
        throw NotFound(
          "this Mac has no sticker image for identifier \(identifier)"
        )
      }
      return .bytes(image.data, contentType: FileTypes.mimeType(forIdentifier: image.uti))
    }

    /// Puts a sticker on this Mac.
    ///
    /// Multipart, the same form as the attachment routes: the image under `attachment`,
    /// everything else as string fields. A JSON `filePath` naming a file an earlier
    /// `attachment/upload` staged is accepted too.
    ///
    /// It lands in RECENTS, not in the saved drawer, and the response says so in
    /// `shelf`. That is not a shortcut — donating to recents is the only write into the
    /// store Messages exposes, and creating a saved sticker is a Stickers-extension UI flow
    /// with no API behind it. `docs/STICKER_LIBRARY.md` has the measurements.
    registry.register(.stickerSave) { request in
      let api = try await context.requirePrivateAPI(for: "saving a sticker")
      // `nameField: nil` — on every other file route `name` renames the staged file,
      // because there it means "what the recipient sees". Here it is the STICKER's name,
      // so the file keeps its own filename and, importantly, its extension.
      let body = try UploadedFileBody.parse(
        request, filePart: "attachment", uploads: context.uploads, nameField: nil
      )
      // STAGED into Messages' container first, exactly as a sticker SEND is. The helper
      // runs inside Messages and inherits its sandbox, so a read of the server's own
      // uploads directory fails with EPERM — measured here, and the reason
      // `AttachmentStaging` exists. Skipping it cost a 500 that named the upload path.
      let saved = try await api.saveSticker(
        SaveStickerRequest(
          filePath: try AttachmentStaging.stage(body.path),
          name: body.values["name"]?.stringValue,
          accessibilityName: body.values["accessibilityName"]?.stringValue
        )
      )

      // Read back rather than echoed, and looked up by EXTERNAL URI rather than by the
      // identifier the donation was given.
      //
      // The store does not file the row under that identifier — it mints its own and
      // records the given one as the external URI. Answering with the donation's
      // identifier therefore hands a client an id that every read route 404s on, which is
      // what the first version of this route did.
      if let library = await context.stickerLibrary(),
        let sticker = try await library.sticker(externalURI: saved.externalURI)
      {
        return .data(Self.serialize(sticker))
      }

      // The store took it and this server cannot read the store back — a Mac without Full
      // Disk Access. Reported rather than 500'd, but WITHOUT an `identifier`, because the
      // only one available here is not one the read routes accept.
      return .data(
        .object([
          "external_uri": .string(saved.externalURI),
          "byte_count": .int(saved.byteCount),
          "shelf": .string(StickerShelf.recent.rawValue),
          "saved": .bool(true),
        ]),
        metadata: .object([
          "reason": .string(
            "the sticker was added, but this server cannot read the sticker store to "
              + "report its identifier — check Full Disk Access")
        ]))
    }
  }

  // MARK: - Reading the request

  private static let absent =
    "this Mac has no sticker store — either nothing has ever been added to it, or the "
    + "server does not have Full Disk Access to read it"

  /// `?source=saved|recent|all`, defaulting to every shelf.
  static func shelves(_ request: APIRequestContext) throws -> Set<StickerShelf> {
    guard let raw = request.queryParameters["source"]?.lowercased(), !raw.isEmpty else {
      return Set(StickerShelf.allCases)
    }
    if raw == "all" { return Set(StickerShelf.allCases) }
    // Comma-separated is accepted, so `?source=saved,recent` means the same as `all` and a
    // client building the parameter from a set of toggles does not have to special-case it.
    let wanted = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let shelves = try wanted.map { name -> StickerShelf in
      guard let shelf = StickerShelf(rawValue: name) else {
        throw BadRequest("`source` must be `saved`, `recent` or `all` — not `\(name)`")
      }
      return shelf
    }
    return Set(shelves)
  }

  /// `?role=` as a store role string.
  ///
  /// The two shorthands are accepted because the real values are long reverse-DNS strings
  /// that a client should not have to hard-code: `still` and `keyboard` map onto them.
  static func role(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw.lowercased() {
    case "still", "full": return StickerRepresentationRow.stillRole
    case "keyboard", "thumbnail", "preview": return StickerRepresentationRow.keyboardRole
    default: return raw
    }
  }

  // MARK: - Serialization

  static func serialize(_ sticker: StickerRow) -> JSONValue {
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

  static func serialize(_ representation: StickerRepresentationRow) -> JSONValue {
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
  static func kind(of externalURI: String) -> String {
    guard let components = URL(string: externalURI)?.pathComponents else { return "unknown" }
    let named = components.first { $0 != "/" && !$0.isEmpty }
    switch named {
    case "emoji", "memoji", "user": return named ?? "unknown"
    default: return named?.isEmpty == false ? "unknown" : "unknown"
    }
  }

  private static func milliseconds(_ date: Date?) -> JSONValue {
    guard let date else { return .null }
    return .int(Int(date.timeIntervalSince1970 * 1000))
  }
}
