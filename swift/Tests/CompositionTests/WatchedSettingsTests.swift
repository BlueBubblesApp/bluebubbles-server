//  WatchedSettingsTests
//  A service's declared settings have to be real, and services that read settings have to
//  declare them.
//
//  `watchedSettings` is already a per-service declaration of which settings matter — it is
//  just not checked against anything. Two live bugs came out of comparing it to what each
//  service actually reads:
//
//    - `ProxyTunnelService` watched `zrok_token`, which NOTHING reads, and did not watch
//      `zrok_reserved_token`, which is what actually builds the provider. Changing the
//      reserved share restarted nothing and silently did not apply until relaunch; changing
//      the account token restarted the tunnel for no reason. The declaration was inverted.
//    - `ChangeDetectionService` was not `ConfigurableService` at all, so `db_poll_interval`
//      was inert — a user lowering it for faster delivery saw nothing until relaunch.
//
//  Both are the same failure: a setting that appears in the UI, saves successfully, and does
//  nothing. Swift cannot introspect which settings a method reads, so the read side stays a
//  review question; what IS checkable is that every declared key exists, and that a service
//  claiming to be configurable actually names something.
//
//  See `.claude/docs/architecture.md`.

import BBServiceKit
import BBSettings
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Watched settings")
struct WatchedSettingsTests {

  /// Every configurable service, named explicitly.
  ///
  /// A list rather than reflection because Swift has no way to enumerate conformers, and a
  /// service missing from here is a service nobody checks — so adding one is a deliberate
  /// act, the same way registering it with the registry is.
  static let configurable: [(name: String, watched: Set<String>)] = [
    ("HTTPService", HTTPService.watchedSettings),
    ("SocketService", SocketService.watchedSettings),
    ("PrivateAPIGatedService", PrivateAPIGatedService.watchedSettings),
    ("PushDeliveryService", PushDeliveryService.watchedSettings),
    ("WebhookDeliveryService", WebhookDeliveryService.watchedSettings),
    ("ProxyService<LANMethod>", ProxyService<LANMethod>.watchedSettings),
    ("ProxyService<NgrokMethod>", ProxyService<NgrokMethod>.watchedSettings),
    ("ProxyService<ZrokMethod>", ProxyService<ZrokMethod>.watchedSettings),
    ("SleepPreventionService", SleepPreventionService.watchedSettings),
    ("ChangeDetectionService", ChangeDetectionService.watchedSettings),
  ]

  @Test("Every watched key is a real setting")
  func watchedKeysExist() {
    // A typo here is silent in both directions: the change never routes, and nothing
    // reports an unknown key.
    //
    // A key is real if the CORE registry declares it or a service's MANIFEST does. Those
    // are the two places settings come from now, and a namespaced key belongs to exactly
    // one service by construction — which is what makes the second list checkable rather
    // than an escape hatch.
    let manifestKeys = Set(
      BuiltInManifests.all.flatMap { manifest in
        manifest.fields.map { manifest.storageKey(for: $0.key) }
      }
    )
    for service in Self.configurable {
      for key in service.watched {
        #expect(
          Settings.allKeys.contains(key) || manifestKeys.contains(key),
          "\(service.name) watches '\(key)', which no registry or manifest declares"
        )
      }
    }
  }

  @Test("A configurable service watches at least one setting")
  func configurableServicesWatchSomething() {
    // Declaring `ConfigurableService` and watching nothing is a service that can never be
    // reconfigured, which is almost certainly a mistake rather than a decision.
    for service in Self.configurable {
      #expect(!service.watched.isEmpty, "\(service.name) is configurable but watches nothing")
    }
  }

  @Test("A connection method watches its own namespace, derived not hand-listed")
  func proxyWatchesItsOwnFields() {
    // The zrok bug is now unrepresentable. `watchedSettings` is COMPUTED from the fields
    // the manifest declares, so watching `zrok_token` while reading `zrok_reserved_token`
    // cannot happen — there is only one list and both come from it.
    let watched = ProxyService<ZrokMethod>.watchedSettings
    for field in BuiltInManifests.zrok.fields {
      #expect(
        watched.contains(BuiltInManifests.zrok.storageKey(for: field.key)),
        "zrok declares '\(field.key)' but does not watch it"
      )
    }
    // And the selection itself, so switching connection method restarts it.
    #expect(watched.contains("connection_method"))
  }

  @Test("Settings that no service watches are deliberate, not forgotten")
  func unwatchedSettingsAreAccountedFor() {
    // Not every setting belongs to a service — some are read per request, some are pure
    // UI, some are bookkeeping. This asserts the REMAINDER is a known list, so a new
    // setting that nothing reacts to shows up here rather than being quietly inert.
    let watched = Self.configurable.reduce(into: Set<String>()) { $0.formUnion($1.watched) }

    // Applied by `SettingsPropagation` rather than by a service, because the object they
    // configure is shared and belongs to none of them.
    let unowned = SettingsPropagation.unownedKeys.union(["server_address"])

    let unaccounted = Set(Settings.allKeys)
      .subtracting(watched)
      .subtracting(unowned)
      // Read once while the composition is ASSEMBLED — the route table, the codec
      // negotiator, the feature flags that decide which route groups mount. Nothing
      // watches them because a service restart would not apply them; they raise the
      // restart notice instead. Subtracted from the source rather than transcribed,
      // so a new structural key does not need a second edit here.
      .subtracting(SettingsPropagation.structuralKeys)
      .subtracting(Self.readPerUseOrUIOnly)

    #expect(
      unaccounted.isEmpty,
      """
      these settings are watched by nothing and are not on the known list — either a \
      service should react to them, or they belong in `readPerUseOrUIOnly` with a \
      reason: \(unaccounted.sorted())
      """
    )
  }

  /// Settings that legitimately need no service to react.
  ///
  /// Three kinds, and the distinction matters: values read fresh on every use (so a change
  /// applies immediately with no restart), values that only the app's own UI consumes, and
  /// bookkeeping the user never sets.
  static let readPerUseOrUIOnly: Set<String> = [
    // Read per request or per operation — a change is picked up on the next one.
    "log_level", "event_payload_codec", "auth_mode", "additive_endpoints",
    "update_feed_url", "check_for_updates", "auto_install_updates",
    "encrypt_coms", "facetime_calling", "landing_page_path",
    // Read at each cleanup sweep rather than held by a service, so a change applies to
    // the next sweep with no restart.
    "facetime_link_ttl_hours",
    // Applied at launch only, and honestly so: they describe how the process itself was
    // started and cannot change without restarting it.
    "start_delay", "start_via_terminal", "headless", "disable_gpu",
    "auto_start_method", "start_minimized", "hide_dock_icon", "dock_badge",
    "auto_lock_mac", "open_findmy_on_startup",
    // App UI only.
    "tutorial_is_done",
    // Bookkeeping, never user-set.
    "last_fcm_restart", "legacy_config_imported",
    // Private API detail read when the helper is launched.
    "enable_ft_private_api",
  ]
}
