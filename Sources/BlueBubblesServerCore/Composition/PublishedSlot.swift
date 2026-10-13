//  PublishedSlot
//  Something a service hands to the container while it runs, and takes back when it stops.
//
//  A service that constructs a runtime (`ServiceCapabilities.swift`, "Publishing a runtime
//  into the container") publishes it so handlers, the app and `interfaces()` can reach it. The
//  publication is half of a pair, and the other half is the easy one to leave out: a runtime
//  left published after its service stops is still reached through the interfaces, as though
//  the service were running. A slot is built from BOTH halves at once, so a service holding
//  one has said how it will take the value back, and its `stop()` calls `withdraw()`.

/// One value a service publishes for as long as it runs.
///
/// Remembers whether it published, so `withdraw()` takes back only what this slot handed over:
/// a stop that follows a start which never got as far as publishing withdraws nothing.
actor PublishedSlot<Value: Sendable> {

  private let publishing: @Sendable (Value) async -> Void
  private let withdrawing: @Sendable () async -> Void
  /// What this slot has handed over and not yet taken back.
  private(set) var value: Value?

  /// - Parameters:
  ///   - publish: hands a value to the container, replacing whatever it held.
  ///   - withdraw: clears it. The two come from ONE capability protocol, never two: see
  ///     `ServiceCapabilities.swift`.
  init(
    publish: @escaping @Sendable (Value) async -> Void,
    withdraw: @escaping @Sendable () async -> Void
  ) {
    self.publishing = publish
    self.withdrawing = withdraw
  }

  /// Hands `value` to the container.
  func publish(_ value: Value) async {
    self.value = value
    await publishing(value)
  }

  /// Takes back what `publish` handed over, or does nothing if it handed over nothing.
  func withdraw() async {
    guard value != nil else { return }
    value = nil
    await withdrawing()
  }
}
