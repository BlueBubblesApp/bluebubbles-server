//  RouteResultPageTests
//  `RouteResult.page` builds the metadata every listing shares, and nothing else.
//
//  Pins the three shapes a listing can take, so that two branches of one route cannot
//  disagree about which keys it has, and that a route's own extra keys cannot replace a
//  shared one.

import BBCore
import BBSerialization
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("RouteResult.page")
struct RouteResultPageTests {

  private func parts(_ result: RouteResult) -> (data: JSONValue?, metadata: JSONValue?) {
    guard case .data(let data, let metadata, _) = result else {
      Issue.record("expected .data, got \(result)")
      return (nil, nil)
    }
    return (data, metadata)
  }

  @Test("A paged listing with a total answers offset, limit, total and count")
  func pagedWithTotal() {
    let rows: [JSONValue] = [.int(1), .int(2)]
    let (data, metadata) = parts(.page(rows, Page(limit: 50, offset: 100), total: 9))
    #expect(data == .array(rows))
    #expect(
      metadata
        == .object(["offset": .int(100), "limit": .int(50), "total": .int(9), "count": .int(2)]))
  }

  @Test("A paged listing with no total omits the key in every branch, empty or not")
  func pagedWithoutTotal() {
    let page = Page(limit: 50, offset: 0)
    let empty = parts(.page([], page)).metadata
    let full = parts(.page([.null], page)).metadata
    #expect(empty?.objectKeys == ["offset", "limit", "count"])
    #expect(full?.objectKeys == ["offset", "limit", "count"])
    #expect(empty?["count"] == .int(0))
  }

  @Test("An unpaged list answers count alone")
  func unpaged() {
    #expect(parts(.page([.null, .null])).metadata == .object(["count": .int(2)]))
  }

  @Test("A route's extra keys sit beside the shared ones and cannot replace them")
  func extraKeys() {
    let metadata = parts(
      .page(
        [.null], Page(limit: 10, offset: 0), total: 4,
        extra: ["saved": .int(1), "count": .int(99)])
    ).metadata
    #expect(metadata?["saved"] == .int(1))
    #expect(metadata?["count"] == .int(1))
  }

  @Test("The message override reaches the envelope")
  func messageOverride() {
    guard case .data(_, _, let message) = RouteResult.page([], message: "Fetched!") else {
      Issue.record("expected .data")
      return
    }
    #expect(message == "Fetched!")
  }
}
