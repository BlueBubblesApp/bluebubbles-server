//  EqualHeightGrid
//  An adaptive grid whose items are all the height of the tallest one.
//
//  `LazyVGrid` sizes each item to its own content, so a row of cards holding different
//  amounts of text is a row of different heights, and a dashboard of them reads as ragged.
//  This measures every item at the column width, takes the tallest, and gives every item that
//  height, so each group of cards is one even block. An item fills the height only if it lets
//  itself grow: `GlassCard` and `ContentCard` content should end in
//  `.frame(maxHeight: .infinity, alignment: .top)`.
//
//  Measured once per width, not once per call. `sizeThatFits` and `placeSubviews` both need
//  the same numbers for the same width, and SwiftUI asks `sizeThatFits` more than once in a
//  pass, so without the cache every card, charts included, was measured two to three times
//  per layout. The cache lives in `Layout`'s own `Cache`, which SwiftUI resets through
//  `updateCache` when the subviews change; Apple's `Layout` documentation keeps subview sizes
//  in that cache in its own example, which is the contract this relies on.
//
//  Not lazy, which is right for what uses it: a handful of cards, all on screen together. A
//  long list belongs in a `LazyVGrid` or a `Table`.

import SwiftUI

struct EqualHeightGrid: Layout {
  /// Columns are added while each can be at least this wide.
  var minimumColumnWidth: CGFloat
  var spacing: CGFloat = 12

  struct Metrics {
    let columns: Int
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    let rows: Int
  }

  /// The last measurement and the width it was for.
  struct Cache {
    var width: CGFloat?
    var metrics: Metrics?
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let metrics = measure(width: proposal.width, subviews: subviews, cache: &cache)
    let width =
      CGFloat(metrics.columns) * metrics.columnWidth + CGFloat(metrics.columns - 1) * spacing
    let height =
      CGFloat(metrics.rows) * metrics.rowHeight + CGFloat(max(0, metrics.rows - 1)) * spacing
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    guard !subviews.isEmpty else { return }
    let metrics = measure(width: bounds.width, subviews: subviews, cache: &cache)
    let size = ProposedViewSize(width: metrics.columnWidth, height: metrics.rowHeight)
    for (index, subview) in subviews.enumerated() {
      let column = index % metrics.columns
      let row = index / metrics.columns
      subview.place(
        at: CGPoint(
          x: bounds.minX + CGFloat(column) * (metrics.columnWidth + spacing),
          y: bounds.minY + CGFloat(row) * (metrics.rowHeight + spacing)),
        proposal: size)
    }
  }

  private func measure(
    width proposed: CGFloat?, subviews: Subviews, cache: inout Cache
  ) -> Metrics {
    let width = proposed ?? minimumColumnWidth
    if cache.width == width, let metrics = cache.metrics { return metrics }
    let columns = Self.columns(
      for: width, minimumColumnWidth: minimumColumnWidth, spacing: spacing,
      itemCount: subviews.count)
    let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    let rowHeight =
      subviews
      .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
      .max() ?? 0
    let rows = (subviews.count + columns - 1) / columns
    let metrics = Metrics(
      columns: columns, columnWidth: columnWidth, rowHeight: rowHeight, rows: rows)
    cache.width = width
    cache.metrics = metrics
    return metrics
  }

  /// How many columns fit. Never more than there are items, so three cards on a wide window
  /// share the width rather than leaving an empty fourth column.
  static func columns(
    for width: CGFloat, minimumColumnWidth: CGFloat, spacing: CGFloat, itemCount: Int
  ) -> Int {
    let fitting = Int((width + spacing) / (minimumColumnWidth + spacing))
    return max(1, min(fitting, max(1, itemCount)))
  }
}
