//  CacheValidation
//  An entity tag and a `Cache-Control` directive for a response, and the `If-None-Match` test
//  that turns a repeat request into a 304.
//
//  For the few routes whose answer a client keeps and asks for again: the Genmoji library and
//  its images. The rest of the API is live data a client must not cache, and sends neither
//  header, which is the default this keeps.
//
//  Three decisions:
//
//    - **Every tag is WEAK** (`W/"…"`). A JSON body may be gzipped or not and a PNG is
//      re-encoded on each request, so the bytes can differ when the content does not. A weak
//      tag says "the same content", which is all `If-None-Match` compares (RFC 9110 §13.1.2
//      uses the weak comparison there), and it never claims a byte-for-byte match this
//      server does not promise.
//    - **Every directive is `private`.** These answers sit behind a password, and a tunnel can
//      put a shared cache in front of this server: `private` is what tells it not to keep one
//      person's library for the next request. Nothing here is ever `public`.
//    - **`nosniff` rides with them**, so a browser-based client never reinterprets an image
//      as something it would execute.

import Foundation

public struct CacheValidation: Sendable, Equatable {

  /// The `ETag` header's value, quoted and weak.
  public let entityTag: String
  /// The `Cache-Control` header's value.
  public let cacheControl: String

  /// For a listing: keep it, and ask whether it is current before using it again.
  public static func revalidated(_ tag: String) -> CacheValidation {
    CacheValidation(entityTag: weak(tag), cacheControl: "private, no-cache")
  }

  /// For content a tag names forever, such as one rendition of an image at one size: keep it
  /// for a year without asking.
  public static func immutable(_ tag: String) -> CacheValidation {
    CacheValidation(
      entityTag: weak(tag), cacheControl: "private, max-age=31536000, immutable")
  }

  /// Whether a request's `If-None-Match` names this response's tag, so a 304 answers it.
  ///
  /// The header may list several tags, comma-separated, or be `*`. Weak comparison: the `W/`
  /// prefix is ignored on both sides.
  public func isSatisfied(byIfNoneMatch header: String?) -> Bool {
    guard let header else { return false }
    let mine = Self.opaque(entityTag)
    for candidate in header.split(separator: ",") {
      let trimmed = candidate.trimmingCharacters(in: .whitespaces)
      if trimmed == "*" || Self.opaque(trimmed) == mine { return true }
    }
    return false
  }

  /// The tag between its quotes, without `W/`.
  private static func opaque(_ tag: String) -> String {
    var value = Substring(tag)
    if value.hasPrefix("W/") { value = value.dropFirst(2) }
    return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  /// `W/"tag"`, with anything that cannot sit inside the quotes dropped: an entity tag may not
  /// carry a quote, a backslash or a control character, and the tags made here are hex and
  /// dashes anyway.
  private static func weak(_ tag: String) -> String {
    let safe = tag.unicodeScalars.filter {
      $0.isASCII && $0.value > 0x20 && $0 != "\"" && $0 != "\\" && $0.value != 0x7F
    }
    return "W/\"\(String(String.UnicodeScalarView(safe)))\""
  }
}
