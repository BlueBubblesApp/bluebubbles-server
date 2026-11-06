//  ServiceRegistry+SettingsChanges
//  Routing a settings change to the services that watch the key, and acting on what they ask.
//
//  Its own file so a reader chasing a restart loop reads the routing and nothing else. The
//  changes deferred during startup are declared in `ServiceRegistry.swift`.

import BBCore
import BBSettings
import Foundation
import Logging

extension ServiceRegistry {

  // MARK: - Settings changes

  /// Routes a change to the services that care, and acts on what they return.
  ///
  /// This is the whole of what handleConfigUpdate did, minus the if-chain and the manual
  /// `proxiesRestarted` latch: coalescing falls out of collecting the requests first and
  /// acting once.
  public func apply(_ change: SettingsChange) async {
    guard !isStarting else {
      deferredChange.formUnion(change.changedKeys)
      return
    }

    // Enablement first, and separately, because it is the one change that must reach a
    // service with NO INSTANCE. The loop below routes a change to `instances[id]`, so a
    // service that is switched off cannot be told that it has been switched back on:
    // it would stay off until the next full restart, which is indistinguishable from the
    // switch not working.
    if change.intersects(enablementSettings) {
      await applyEnablement()
    }

    var toRestart: Set<ServiceIdentifier> = []

    for id in startOrder {
      guard let registration = registrations[id],
        registration.watchedSettings.isEmpty == false,
        change.intersects(registration.watchedSettings),
        let configurable = instances[id] as? any ConfigurableService
      else { continue }

      do {
        switch try await configurable.apply(change) {
        case .none, .reconfigure:
          break
        case .restart:
          toRestart.insert(id)
        }
      } catch {
        logger.error(
          "Service rejected settings change",
          metadata: [
            "service": .string(id.rawValue),
            "error": .string(String(describing: error)),
          ])
        await onAlert(id, error)
      }
    }

    // Services with NO INSTANCE whose gate reads one of the keys that just changed.
    //
    // The loop above can only route a change to `instances[id]`, and a `GatedService` that
    // declined at startup does not have one. Without this, turning the Private API on would
    // write `enable_private_api`, reach nothing, and leave the helper uninjected until the
    // next full restart of the server: indistinguishable, from the UI, from the switch not
    // working.
    //
    // `applyEnablement` covers the same shape for the Integrations switch; a gate is the
    // other way a service can be absent. A gate reads settings, so the keys that can open
    // it are the keys the service already declares it watches.
    //
    // `performStart` re-checks permissions, enablement and the gate, and returns early when
    // an instance exists, so an attempt that should still decline simply declines again,
    // and one `applyEnablement` has already started is a no-op.
    for id in startOrder
    where instances[id] == nil
      && registrations[id].map({ change.intersects($0.watchedSettings) }) == true
    {
      await start(id)
    }

    // Expand to dependents once, so a socket_port change restarts the HTTP service and
    // the proxies that depend on it without anyone hand-coding that relationship.
    var expanded: Set<ServiceIdentifier> = []
    for id in toRestart { expanded.formUnion(dependents(of: id).union([id])) }

    let ordered = startOrder.filter { expanded.contains($0) }
    guard !ordered.isEmpty else { return }

    logger.info(
      "Restarting services for settings change",
      metadata: [
        "services": .string(ordered.map(\.rawValue).joined(separator: ", "))
      ])
    for id in ordered.reversed() { await stop(id) }
    for id in ordered { await start(id) }
  }

  /// Brings what is running into line with what the user has switched on.
  ///
  /// Stops in reverse order and starts in forward order, for the same reason `startAll`
  /// does: a service switched off may be one another depends on.
  ///
  /// `start` is attempted for anything not running rather than only for services
  /// known to have been switched off: it re-checks permissions and gates itself, so the
  /// worst case is that a service inactive for some other reason stays inactive.
  private func applyEnablement() async {
    var switchedOff: Set<ServiceIdentifier> = []
    for id in startOrder where await !enablementCheck(id) { switchedOff.insert(id) }

    // Everything switched off, plus everything that depends on it.
    var toStop: Set<ServiceIdentifier> = []
    for id in switchedOff { toStop.formUnion(dependents(of: id).union([id])) }

    // The REASON is recorded for everything in the set, and the stop only for what is
    // actually running. Those are different populations, and conflating them reported the
    // wrong thing: switch off the HTTP API and its socket together, then switch the SOCKET
    // back on, and the socket is enabled but still blocked: it cannot run without the
    // listener. It was not running, so it was not visited, so it went on saying "switched
    // off" about itself when the truth had moved to the thing it depends on.
    for id in startOrder.reversed() where toStop.contains(id) {
      if instances[id] != nil {
        logger.info(
          "Stopping service: switched off",
          metadata: [
            "service": .string(id.rawValue)
          ])
        await stop(id)
      }
      notRunning[id] = .inactive(
        reason: switchedOff.contains(id)
          ? ServiceHealth.RoutineReason.switchedOff
          : ServiceHealth.RoutineReason.dependencySwitchedOff)
      blocked.insert(id)
    }

    // Forward order, so a dependency is running again before its dependents are asked to
    // start. `start` re-checks permissions and gates itself, so attempting one that is
    // inactive for some other reason simply leaves it inactive.
    for id in startOrder where instances[id] == nil && !toStop.contains(id) {
      blocked.remove(id)
      await start(id)
    }
  }
}
