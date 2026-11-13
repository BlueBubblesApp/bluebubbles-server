//  BindingShapesTests
//  The two bindings every page used to write by hand: presence, and a held switch position.
//
//  `Binding` is not a `View`, so it can be built and driven from a test process; the bindings
//  here sit over a plain reference box standing in for a view's `@State`.

import SwiftUI
import Testing

@testable import BlueBubblesApp

@Suite("Binding shapes")
@MainActor
struct BindingShapesTests {

  /// A view's `@State`, without the view.
  final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
    var binding: Binding<Value> {
      Binding(get: { self.value }, set: { self.value = $0 })
    }
  }

  struct Refused: Error {}

  // MARK: - Presence

  @Test("Presence reads whether there is anything, and dismissing clears it")
  func presenceClearsOnDismiss() {
    let pending = Box<String?>(nil)
    let isPresented = Binding.isPresent(pending.binding)
    #expect(!isPresented.wrappedValue)

    pending.value = "webhook"
    #expect(isPresented.wrappedValue)

    isPresented.wrappedValue = false
    #expect(pending.value == nil, "a dismissed dialog left the thing it presented behind")
  }

  /// Presenting is the caller putting a value in, never the binding inventing one.
  @Test("Setting a presence binding true does nothing")
  func presenceDoesNotInvent() {
    let pending = Box<Int?>(nil)
    Binding.isPresent(pending.binding).wrappedValue = true
    #expect(pending.value == nil)
  }

  @Test("The model-owned shape dismisses through the model, and only on dismissal")
  func presenceDismissesThroughTheModel() {
    var dismissals = 0
    let isPresented = Binding.isPresent({ true }, dismiss: { dismissals += 1 })
    isPresented.wrappedValue = true
    #expect(dismissals == 0)
    isPresented.wrappedValue = false
    #expect(dismissals == 1)
  }

  // MARK: - Optimistic

  @Test("The held value is what the control shows while the write runs")
  func heldWhileWriting() async {
    let pending = Box<Bool?>(nil)
    var seenDuringWrite: Bool?
    await OptimisticWrite.perform(true, pending: pending.binding) { _ in
      seenDuringWrite = pending.value
    }
    #expect(seenDuringWrite == true)
  }

  @Test("A write that lands lets the held value go")
  func clearedOnSuccess() async {
    let pending = Box<Bool?>(nil)
    await OptimisticWrite.perform(true, pending: pending.binding) { _ in }
    #expect(pending.value == nil)
  }

  /// The half that matters: a refused write must snap the control back to what the server
  /// holds, beside the error, rather than leave it showing a position nothing accepted.
  @Test("A refused write lets the held value go too, and the refusal still reaches the caller")
  func clearedOnFailure() async {
    let pending = Box<String?>(nil)
    await #expect(throws: Refused.self) {
      try await OptimisticWrite.perform("new", pending: pending.binding) { _ in
        throw Refused()
      }
    }
    #expect(pending.value == nil, "a refused write left the control on the refused position")
  }

  @Test("The control reads the held value ahead of the stored one, and the stored one at rest")
  func readsHeldThenStored() {
    let pending = Box<Bool?>(nil)
    let control = Binding.optimistic(false, pending: pending.binding) { _ in }
    #expect(control.wrappedValue == false)
    pending.value = true
    #expect(control.wrappedValue == true)
  }

  /// A confirmation: the switch moves at once, nothing is written until the dialog says so.
  @Test("A change that asks first is held and not written")
  func asksFirstHoldsWithoutWriting() async {
    let pending = Box<Bool?>(nil)
    var writes = 0
    let control = Binding.optimistic(
      true, pending: pending.binding, asksFirst: { !$0 }, write: { _ in writes += 1 })

    control.wrappedValue = false
    #expect(pending.value == false, "the switch did not move while its dialog was up")
    #expect(control.wrappedValue == false)
    await Task.yield()
    #expect(writes == 0, "a change that asks first was written before anybody answered")
  }

  @Test("A plain change is held at once, before its write has run")
  func heldSynchronously() {
    let pending = Box<Bool?>(nil)
    let control = Binding.optimistic(false, pending: pending.binding) { _ in }
    control.wrappedValue = true
    // Read in the same turn as the set: the write's task has not run, and the control must
    // already show where it was moved to rather than one frame of where it was.
    #expect(control.wrappedValue == true)
  }

  /// Two quick flips: the first write's ending must not let go of the second's position
  /// while the second is still being written, or the switch snaps back mid-write.
  @Test("A write that ends after a newer one began leaves the newer position held")
  func olderWriteDoesNotReleaseNewer() async {
    let pending = Box<Bool?>(nil)
    await OptimisticWrite.perform(true, pending: pending.binding) { _ in
      // A second flip lands while the first is in flight.
      pending.value = false
    }
    #expect(pending.value == false, "the first write let go of the second's position")
    OptimisticWrite.release(false, from: pending.binding)
    #expect(pending.value == nil)
  }
}
