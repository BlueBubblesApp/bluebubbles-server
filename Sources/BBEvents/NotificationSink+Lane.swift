//  NotificationSink+Lane
//  Joining and leaving the one notification lane that every push transport shares.
//
//  `NotificationSink` is ONE sink with ONE `SinkID`, and each transport (Firebase, ntfy) is a
//  provider attached to it by its own service. The lane on the bus therefore belongs to
//  whichever services still have a provider attached: it goes when the LAST one leaves, never
//  when any one does, or switching push off silently stops ntfy too.
//
//  Both halves live here rather than in each service because the rule spans two actors. The
//  services each asked the sink whether it was empty and then, in a second hop, told the bus
//  to unregister it; a provider that attached and registered between those hops was taken
//  off the bus by the departing service. Here the detach and the emptiness check are one
//  step on the sink, so a joiner's bus call queues behind the unregister.

extension NotificationSink {

  /// Attaches `provider` and puts the sink on `bus` if it is not there already.
  ///
  /// Not re-registered when already active: `EventBus.register` replaces the lane, which
  /// would cut over every transport's queue for one transport's start.
  public func join(_ provider: any NotificationProvider, on bus: EventBus) async {
    attach(provider)
    if await !bus.activeSinks.contains(id) {
      await bus.register(self)
    }
  }

  /// Detaches the provider named `providerID`, and takes the sink off `bus` only when no
  /// provider is left.
  public func leave(providerID: String, from bus: EventBus) async {
    detach(providerID: providerID)
    guard attachedProviderIDs.isEmpty else { return }
    await bus.unregister(id)
    // A backstop for a joiner whose bus call overtook the unregister. The bus does not
    // promise to run calls in the order they arrive, so this is not provably dead; no test
    // can force that interleaving, which is why it is a re-check rather than a lock.
    if !attachedProviderIDs.isEmpty {
      await bus.register(self)
    }
  }
}
