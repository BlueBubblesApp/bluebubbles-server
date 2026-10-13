//  PreferenceWriter
//  A preference written back the moment it changes, without blocking the click, and in
//  order.
//
//  A `didSet` on a value somebody just changed cannot await a write, so each change used to
//  start a task of its own. Two quick changes were then two writes racing to the store, and
//  nothing promises they land in the order they were made: Basic, Advanced, Basic could
//  leave Advanced stored. Here one write runs at a time, and a change made while one is in
//  flight replaces whatever was waiting behind it, so the last value set is the last value
//  written and nothing in between is written for nobody.

import Foundation

@MainActor
final class PreferenceWriter<Value: Sendable> {

  private var next: (value: Value, write: @MainActor (Value) async -> Void)?
  private var isWriting = false

  init() {}

  /// Whether nothing is being written or waiting to be. For tests.
  var isIdle: Bool { !isWriting && next == nil }

  /// Writes `value` with `write`, after the write in flight if there is one.
  func submit(_ value: Value, write: @escaping @MainActor (Value) async -> Void) {
    next = (value, write)
    guard !isWriting else { return }
    isWriting = true
    Task { await drain() }
  }

  private func drain() async {
    while let pending = next {
      next = nil
      await pending.write(pending.value)
    }
    isWriting = false
  }
}
