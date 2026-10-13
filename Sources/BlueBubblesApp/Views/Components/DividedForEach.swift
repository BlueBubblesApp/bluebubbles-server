//  DividedForEach
//  Rows with a `SettingsDivider` between each pair, and none above the first or below the
//  last.
//
//  Twelve lists drew this by hand, in two spellings: an enumerated sequence testing
//  `index > 0`, and a comparison against `first?.id`. Both are the same decision, and the
//  enumerated one keys the `ForEach` through a tuple, which is one refactor away from an
//  offset id. Here the rows are keyed by their own identity, and the divider belongs to the
//  row below it, so an insertion animates one row and its divider together.

import SwiftUI

struct DividedForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {

  let data: Data
  let id: KeyPath<Data.Element, ID>
  let content: (Data.Element) -> Content

  init(
    _ data: Data, id: KeyPath<Data.Element, ID>,
    @ViewBuilder content: @escaping (Data.Element) -> Content
  ) {
    self.data = data
    self.id = id
    self.content = content
  }

  var body: some View {
    let first = data.first.map { $0[keyPath: id] }
    ForEach(data, id: id) { element in
      if element[keyPath: id] != first { SettingsDivider() }
      content(element)
    }
  }
}

extension DividedForEach where Data.Element: Identifiable, ID == Data.Element.ID {
  init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
    self.init(data, id: \.id, content: content)
  }
}
