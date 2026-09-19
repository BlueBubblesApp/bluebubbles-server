//  HandlePageClampTests
//  A handle query runs with the page it will answer, not the page it was asked for.
//
//  The reference's validator refuses a `limit` outside 1…1000 (`handleValidator.ts`); this
//  server folds the request into that range the way `MessageQuery` does. Before the clamp,
//  `POST handle/query` was the one read that passed `limit` and `offset` to `LIMIT ? OFFSET ?`
//  exactly as sent.

import Testing

@testable import BBInterfaces

@Suite("Handle query pages are clamped")
struct HandlePageClampTests {

  @Test("A limit inside the range is kept, and offset is left alone")
  func inRangeIsUnchanged() {
    let page = HandleInterface.clampedPage(limit: 250, offset: 500)
    #expect(page.limit == 250)
    #expect(page.offset == 500)
  }

  @Test("A limit above the maximum is folded down to it")
  func oversizedIsCapped() {
    let page = HandleInterface.clampedPage(limit: 1_000_000, offset: 0)
    #expect(page.limit == HandleInterface.maximumPageSize)
    #expect(HandleInterface.maximumPageSize == 1000)
  }

  @Test("Zero and negative values become the smallest page at the start")
  func nonPositiveIsFloored() {
    let zero = HandleInterface.clampedPage(limit: 0, offset: -10)
    #expect(zero.limit == 1)
    #expect(zero.offset == 0)
    let negative = HandleInterface.clampedPage(limit: -5, offset: 0)
    #expect(negative.limit == 1)
  }
}
