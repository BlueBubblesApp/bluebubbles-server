//  GenmojiHandlers
//  Generating a Genmoji, asking first whether this Mac can, and reading the Genmoji the person
//  already has.
//
//  Generation answers through `GenmojiInterface`, which runs Image Playground in this process;
//  the library through `GenmojiLibraryInterface`, which reads the sticker store. No helper is
//  involved in either, so no route here carries a Private API requirement. The status route
//  exists so a client checks before it offers generation: the create route's refusal is the
//  same sentence, but a client should not have to earn it.
//
//  The library routes are the only ones in the API that answer `If-None-Match` with a 304
//  (`CacheValidation`). A client keeps its copy of the library and of each image, and asks
//  again cheaply: the listing is compared by a revision of its rows, and an image by the
//  stored rendition, size and format it would be produced from, so a current copy is
//  answered before any image bytes are read.

import BBCore
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum GenmojiHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some GenmojiProviding & GenmojiLibraryProviding
  ) {

    /// Whether `POST genmoji` would work on this Mac, and if not, why.
    registry.register(.genmojiStatus) { _ in
      .data(GenmojiInterface.serialize(await context.genmoji.support()))
    }

    /// Draws `count` Genmoji for `description`, each staged as a PNG the send routes take.
    registry.register(.genmojiCreate) { request in
      let values = try request.values()
      let created = try await context.genmoji.create(
        GenmojiInterface.CreateRequest(
          description: try values.requireString("description"),
          count: try values.wholeNumber("count") ?? 1
        )
      )
      return .data(GenmojiInterface.serialize(created))
    }

    registry.register(.genmojiLibrary) { request in
      try await genmojiLibrary(request, library: await context.genmojiLibrary())
    }
    registry.register(.genmojiLibraryImage) { request in
      try await genmojiLibraryImage(request, library: await context.genmojiLibrary())
    }
    registry.register(.genmojiLibraryImages) { request in
      try await genmojiLibraryImages(request, library: await context.genmojiLibrary())
    }
    /// Removes a Genmoji from the library, on every device on the iCloud account.
    registry.register(.genmojiLibraryDelete) { request in
      let deleted = try await context.genmojiLibrary().delete(
        identifier: try request.requirePathParameter("id"))
      return .data(GenmojiLibraryInterface.serialize(deleted))
    }
  }

  /// The library, newest first, paged, with no bytes.
  ///
  /// `metadata.revision` changes whenever anything listed does, and the `ETag` carries it, so
  /// a client that sends it back in `If-None-Match` gets a 304 for an unchanged library. When
  /// the store cannot be read, or this macOS keeps no Genmoji, the list is empty and
  /// `metadata.reason` says which, as the sticker library's does.
  static func genmojiLibrary(
    _ request: APIRequestContext, library: GenmojiLibraryInterface
  ) async throws -> RouteResult {
    let read = try await library.library()
    let page = Page(
      limit: request.integer("limit"), offset: request.integer("offset"), defaultLimit: 100)
    let validation = CacheValidation.revalidated(
      "\(read.revision)-\(page.offset)-\(page.limit)")
    if validation.isSatisfied(byIfNoneMatch: request.header("If-None-Match")) {
      return .notModified(validation)
    }
    var extra: [String: JSONValue] = ["revision": .string(read.revision)]
    if let reason = read.unavailableReason { extra["reason"] = .string(reason) }
    let rows = read.genmoji.dropFirst(page.offset).prefix(page.limit)
    return .cached(
      .page(
        rows.map(GenmojiLibraryInterface.serialize), page, total: read.genmoji.count,
        extra: extra),
      validation)
  }

  /// One Genmoji's image, as bytes. `?size=` is the longest edge in pixels (1 to 1024,
  /// default 320) and `?format=` is `png` (default) or `heic`.
  static func genmojiLibraryImage(
    _ request: APIRequestContext, library: GenmojiLibraryInterface
  ) async throws -> RouteResult {
    let selection = try await library.select(
      identifier: try request.requirePathParameter("id"),
      size: try request.positiveInteger("size"),
      format: try request.enumeration(
        "format", as: GenmojiLibraryInterface.Format.self,
        rejection: "`format` must be `png` or `heic`"))
    let validation = CacheValidation.immutable(selection.tag)
    if validation.isSatisfied(byIfNoneMatch: request.header("If-None-Match")) {
      return .notModified(validation)
    }
    let image = try await library.image(for: selection)
    return .cached(.bytes(image.data, contentType: image.contentType), validation)
  }

  /// Up to fifty Genmoji at one size, inline, for filling a cache in one request. Identifiers
  /// that name nothing are listed in `missing` rather than refused.
  static func genmojiLibraryImages(
    _ request: APIRequestContext, library: GenmojiLibraryInterface
  ) async throws -> RouteResult {
    let values = try request.values()
    guard let identifiers = try values.strings("identifiers") else {
      throw BadRequest("`identifiers` is required: the Genmoji to read, by identifier")
    }
    let format: GenmojiLibraryInterface.Format?
    if let raw = values.string("format"), !raw.isEmpty {
      guard let parsed = GenmojiLibraryInterface.Format(rawValue: raw) else {
        throw BadRequest("`format` must be `png` or `heic`")
      }
      format = parsed
    } else {
      format = nil
    }
    let batch = try await library.images(
      identifiers: identifiers, size: try values.wholeNumber("size"), format: format)
    return .data(GenmojiLibraryInterface.serialize(batch))
  }
}
