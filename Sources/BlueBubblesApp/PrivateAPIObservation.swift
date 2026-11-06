//  PrivateAPIObservation
//  Following the Private API runtime's state, so the settings page draws what is true now.
//
//  The runtime is published into the container by `PrivateAPIGatedService` when that
//  service starts and withdrawn when it stops, so there is no one object to subscribe to for
//  the life of the server. The registry's health stream is the trigger instead: every
//  snapshot re-resolves the runtime, and a new one is followed from that moment, which is
//  before injection finishes, because the service publishes first and starts second. The
//  runtime is read from the composition the health stream belongs to, never from
//  `AppModel.server`, which is not assigned until every service is up.

import BBBuiltIns
import BBPrivateAPI
import BBServiceKit
import BBSystem

extension AppModel {

  /// The three states the settings page draws, from the followed runtime.
  ///
  /// With no runtime to follow the answer depends on why. The service is still starting:
  /// treated as connected, so the page does not accuse the user of a broken setup for the
  /// second before it knows. Anything else: the service declined, which is the Private API
  /// being off.
  var privateAPIPresence: PrivateAPIPresence {
    if let state = privateAPIState {
      return PrivateAPIPresence(outcome: state.outcome, isConnected: state.isConnected)
    }
    if case .starting? = serviceHealths[BuiltInManifests.ID.privateAPI] { return .connected }
    return .notEnabled
  }

  /// Whether SIP stands in the way, from the permission state the model already follows.
  var privateAPIPrerequisite: PrivateAPIPrerequisite {
    PrivateAPIPrerequisite(configuration: permissions.systemIntegrity)
  }

  /// Re-points the follow at whatever runtime the container holds now.
  ///
  /// Compared by identity: a restart of the Private API service withdraws one runtime and
  /// publishes another, and a follow left on the old one would report a helper that is
  /// never coming back.
  ///
  /// - Parameter resolve: reads the runtime from the composition being followed, which is
  ///   not `server` while the services are starting; see `followServiceHealth`.
  func syncPrivateAPIRuntime(_ resolve: @MainActor () async -> PrivateAPIRuntime?) async {
    let runtime = await resolve()
    let identity = runtime.map(ObjectIdentifier.init)
    guard identity != followedPrivateAPIRuntime else { return }
    followedPrivateAPIRuntime = identity
    await follows.cancel(.privateAPIRuntime)
    follows.onStop(.privateAPIRuntime) { [weak self] in
      self?.privateAPIState = nil
      self?.followedPrivateAPIRuntime = nil
    }
    guard let runtime else {
      privateAPIState = nil
      return
    }
    follow(
      .privateAPIRuntime,
      subscribe: { await runtime.states() },
      seed: { $0.privateAPIState = await runtime.state },
      apply: { $0.privateAPIState = $1 },
      reset: nil)
  }
}
