//  Chunking
//  Splitting a collection into runs, for statements that take a bounded number of bindings.
//
//  SQLite's default host-parameter limit is 999, and this server's read routes accept a
//  1000-row page and hydrate arbitrary lists of GUIDs. An `IN (...)` built from a page's worth
//  of ids does not fit in one statement, and the failure is at runtime rather than at compile
//  time -- so the batching is a shared function rather than a loop each caller writes.

extension Array {

  /// Splits into runs of at most `size`, in order.
  ///
  /// Named `into` rather than `by` because `chunked(by:)` reads as a predicate -- the shape
  /// `split(whereSeparator:)` has -- and the compiler will happily try to resolve an `Int`
  /// against one.
  ///
  /// An empty array gives no chunks rather than one empty chunk, which is what a caller
  /// looping over the result wants: nothing to do.
  public func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return isEmpty ? [] : [self] }
    guard count > size else { return isEmpty ? [] : [self] }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
