//  OptimisticWrite
//  A switch shows its new position while the write behind it is in flight.
//
//  A toggle or picker bound straight to server state flips, snaps back on the next render
//  (the state has not moved yet), and flips again when the write lands: a visible round trip
//  that reads as a control refusing to move. One that asks for confirmation first snapped back
//  the instant it was clicked. So the value being written is HELD, and the control reads it
//  ahead of the stored one until the write finishes.
//
//  Held, and then always let go. The held value is cleared when the write returns, whether it
//  succeeded or not: a refused write has to snap the control back to what the server actually
//  holds, beside the error saying why. Four screens each built this in their own shape (a
//  held `SettingBox`, a mirrored `@State` re-seeded from the model, a held value cleared when
//  a run's outcome changed), and each had to get the failure path right on its own. Here it
//  is one `defer`.
//
//  Text fields are deliberately NOT optimistic. A rejected password must not sit in the field
//  looking saved; see `SettingRow`.

import SwiftUI

@MainActor
enum OptimisticWrite {

  /// Holds `value` in `pending` while `write` runs, and clears it whichever way `write` ends,
  /// unless a newer write has put its own value there meanwhile.
  ///
  /// `write` reports its own failure (a footnote, an alert): the held value is not the place
  /// to say anything about it, only the thing that must not outlive it.
  ///
  /// The comparison is what keeps two quick flips honest. Cleared unconditionally, the first
  /// write's ending let go of the SECOND write's position while it was still in flight, and
  /// the switch snapped back to the stored value for the rest of that write.
  static func perform<Value: Equatable>(
    _ value: Value,
    pending: Binding<Value?>,
    write: @MainActor (Value) async throws -> Void
  ) async rethrows {
    pending.wrappedValue = value
    defer { release(value, from: pending) }
    try await write(value)
  }

  /// Lets go of `value` if it is still the one held. A newer position is the newer write's
  /// to let go of.
  static func release<Value: Equatable>(_ value: Value, from pending: Binding<Value?>) {
    if pending.wrappedValue == value { pending.wrappedValue = nil }
  }
}

extension Binding where Value: Equatable {

  /// A binding that shows the value being written over `current` until the write ends.
  ///
  /// - Parameters:
  ///   - current: What the server holds, as last read.
  ///   - pending: Where the value in flight is held. `@State` on the view, nil at rest.
  ///   - asksFirst: Called with the new position before anything is written. Return true
  ///     when the caller has put up a confirmation instead: the position is held and NOT
  ///     written, the confirmation's accept runs `OptimisticWrite.perform` with it, and its
  ///     cancel sets `pending` back to nil, which is the snap back a person expects from a
  ///     declined dialog.
  ///   - write: The write. Its failure is its own to report.
  @MainActor
  static func optimistic(
    _ current: Value,
    pending: Binding<Value?>,
    asksFirst: @escaping @MainActor (Value) -> Bool = { _ in false },
    write: @escaping @MainActor (Value) async -> Void
  ) -> Binding<Value> {
    Binding(
      get: { pending.wrappedValue ?? current },
      set: { newValue in
        // Synchronously, so the very next render already shows the new position; the task
        // below would otherwise leave one frame of the old one.
        pending.wrappedValue = newValue
        guard !asksFirst(newValue) else { return }
        Task { await OptimisticWrite.perform(newValue, pending: pending, write: write) }
      }
    )
  }
}
