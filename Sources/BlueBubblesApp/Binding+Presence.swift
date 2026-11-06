//  Binding+Presence
//  "Is there one?" as a presentation flag, and "put it away" as dismissing it.
//
//  A confirmation dialog or an alert presented over an optional (the webhook about to be
//  removed, the update about to be installed) needs a `Binding<Bool>`, and the page holds
//  the optional. Seven dialogs across five files wrote the same four lines by hand, in two
//  shapes: one cleared the optional on dismissal and one called a method on a model. Both
//  are here, once, so a dialog that forgets to clear what it was presenting cannot be
//  written by accident.
//
//  `ViewPlumbingPolicyTests` refuses the hand-written `get: { x != nil }` shape under
//  `Sources/BlueBubblesApp`.

import SwiftUI

extension Binding where Value == Bool {

  /// True while `source` holds something; dismissing sets it back to nil.
  ///
  /// Setting `true` does nothing: there is nothing to present until the caller puts a value
  /// in `source`, which is how every one of these is opened.
  @MainActor
  static func isPresent<Wrapped>(_ source: Binding<Wrapped?>) -> Binding<Bool> {
    Binding(
      get: { source.wrappedValue != nil },
      set: { isPresented in
        if !isPresented { source.wrappedValue = nil }
      }
    )
  }

  /// The same shape when what is presented lives on a model that clears it itself:
  /// `isPresent` answers whether there is anything to show, and `dismiss` is how the model
  /// is told the person put it away.
  @MainActor
  static func isPresent(
    _ isPresent: @escaping @MainActor () -> Bool,
    dismiss: @escaping @MainActor () -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { isPresent() },
      set: { isPresented in
        if !isPresented { dismiss() }
      }
    )
  }
}
