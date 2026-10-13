//  Page
//  The window a paged listing actually served, and the metadata that describes it.
//
//  Two decisions, made once.
//
//  **The window is CLAMPED, never echoed.** `limit` goes into `LIMIT ?`, and SQLite reads a
//  negative LIMIT as no limit at all, so `{"limit": -1}` meant "the whole table". The
//  reference refuses a `limit` outside 1...1000 in its validators; this server clamps it, which
//  is safe in both directions, and the metadata reports the clamped values because a client
//  pages against them: echoing a requested 5000 back told a client it had been given 5000,
//  so its next page started 5000 further on and skipped the 4000 it never received.
//
//  **The metadata keys are the reference's.** The four v1 listings that page
//  (`POST /message/query`, `POST /chat/query`, `GET /chat/:guid/message`,
//  `POST /handle/query`) each answer `{offset, limit, total, count}`: `messageRouter.ts:235`,
//  `chatRouter.ts:114` and `:144`, `handleRouter.ts:48`, and the four recorded fixtures carry
//  exactly those keys. `count` is the rows on THIS page and `total` is the rows under the
//  same filter on every page, so a client knows whether to ask again. A listing that has no
//  total to give (a call log read a page at a time) omits it rather than inventing one.

import BBCore
import Foundation

public struct Page: Sendable, Equatable {

  /// The largest page any listing serves, matching the reference's `max:1000`.
  public static let maximumLimit = 1000

  public let limit: Int
  public let offset: Int

  /// Folds a request into the range a query will run with.
  ///
  /// - Parameter maximumLimit: the ceiling, for the few listings whose rows are expensive
  ///   enough to want a lower one than `Page.maximumLimit`.
  public init(limit: Int, offset: Int, maximumLimit: Int = Page.maximumLimit) {
    self.limit = min(max(1, limit), maximumLimit)
    self.offset = max(0, offset)
  }

  /// As above, for a request that may not have named either; absent takes the route's default.
  public init(
    limit: Int?, offset: Int?, defaultLimit: Int, maximumLimit: Int = Page.maximumLimit
  ) {
    self.init(limit: limit ?? defaultLimit, offset: offset ?? 0, maximumLimit: maximumLimit)
  }

  /// `offset`, `limit` and `count`, plus `total` when there is one.
  public func metadata(count: Int, total: Int?) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [
      "offset": .int(offset),
      "limit": .int(limit),
      "count": .int(count),
    ]
    if let total { fields["total"] = .int(total) }
    return fields
  }
}
