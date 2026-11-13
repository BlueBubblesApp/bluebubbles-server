//  Binding+Membership
//  "Is this one in the set?" as a switch.
//
//  A tick box per item over a `Set` (the sections of an archive, the events a webhook
//  wants, the alerts whose details are open) needs a `Binding<Bool>` per item, and four
//  views wrote the same get-contains, set-insert-or-remove closure by hand. Once here, so a
//  tick box cannot insert on the way on and forget to remove on the way off.

import SwiftUI

extension Binding where Value == Bool {

  /// True while `set` holds `element`; switching it on inserts it, and off removes it.
  @MainActor
  init<Element: Hashable>(contains element: Element, in set: Binding<Set<Element>>) {
    self.init(
      get: { set.wrappedValue.contains(element) },
      set: { isOn in
        if isOn {
          set.wrappedValue.insert(element)
        } else {
          set.wrappedValue.remove(element)
        }
      }
    )
  }
}
