//  RouteResult
//  What a controller hands back, and the signature every controller implements.
//
//  Wrapping into the envelope happens once, in `HTTPAPIBuilder.response(for:…)`, so a handler
//  never builds an envelope and the shape stays the same across every route.

import BBCore
import BBSerialization
import Foundation

/// Signature every controller implements. Returning a `JSONValue` rather than a
/// `ResponseEnvelope` keeps controllers from having to know about the envelope at all:
/// wrapping happens once, in `HTTPAPIBuilder`, which is how the shape stays consistent across ~90 routes.
public typealias RouteHandler = @Sendable (APIRequestContext) async throws -> RouteResult

public enum RouteResult: Sendable {
  /// Wrapped in the standard envelope with status 200.
  ///
  /// `message` overrides the route's entry in `SuccessMessages`, for the handful of routes
  /// whose string depends on what they found: the reference's theme and settings reads say
  /// "No saved themes!" for an empty list and "Successfully fetched theme(s)!" otherwise,
  /// and only the handler knows which.
  case data(JSONValue?, metadata: JSONValue? = nil, message: String? = nil)
  /// 201 "No Data". POST /facetime/leave/:call_uuid, and nothing else.
  case noData
  /// A pre-built envelope, for the handful of routes that set their own status.
  case envelope(status: Int, ResponseEnvelope)
  /// Streamed from disk. Never buffered: a 500 MB video must not enter the heap.
  case file(path: String, filename: String?, contentType: String?)
  /// Raw bytes with a content type. Used by the avatar and blurhash routes.
  case bytes(Data, contentType: String)
}

extension RouteResult {

  /// A listing: the rows as `data`, and the metadata every listing shares.
  ///
  /// `count` is always present. `offset` and `limit` come with a window, `total` when the
  /// route can count under the same filter. See `Page` for the keys and why the window is
  /// the clamped one. A list with no paging at all (pinned chats, pending Send Later
  /// messages) passes neither and answers `count` alone, which is the shape it had.
  ///
  /// - Parameter extra: route-specific keys beside the shared ones (the sticker shelves'
  ///   own totals). They cannot replace a shared key: the shared value wins, so a route
  ///   cannot report a count that disagrees with its rows.
  public static func page(
    _ items: [JSONValue], _ window: Page? = nil, total: Int? = nil,
    extra: [String: JSONValue] = [:], message: String? = nil
  ) -> RouteResult {
    var shared = window?.metadata(count: items.count, total: total) ?? ["count": .int(items.count)]
    if window == nil, let total { shared["total"] = .int(total) }
    let metadata = extra.merging(shared) { $1 }
    return .data(.array(items), metadata: .object(metadata), message: message)
  }
}
