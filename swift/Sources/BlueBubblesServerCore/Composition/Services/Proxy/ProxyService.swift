//  ProxyServices
//  One service per connection method, in an exclusive category.
//
//  This replaces a single `ProxyTunnelService` that switched on a `proxy_service` enum. The
//  enum could not say the things the model needs it to say: that these five are the same KIND
//  of thing, that only one may run at a time, that three of them run a program and two do not,
//  or that each has its own configuration. Most importantly it could not be EXTENDED — a
//  third-party tunnel cannot add a case to an enum compiled into this binary, so as long as
//  the choice was an enum, "plugins" could never include a connection method.
//
//  As five services in an exclusive category, all of that falls out: the registry starts them
//  all, four decline through `canRun`, and the validator reports it if two are somehow enabled
//  at once. Selection is "which service in this category is enabled", which is a question a
//  plugin can answer about itself.
//
//  The shared behaviour lives in `ProxyService<Method>` and each method supplies only a
//  manifest and a provider — deliberately thin, because that pair is the shape a plugin will
//  have.
//
//  It is a GENERIC over a descriptor rather than a base class with overrides, and the
//  difference is not stylistic. An abstract `class var manifest` has to trap when nobody
//  overrides it, so "forgot to override" is a crash at start-up instead of a compile error —
//  and a plugin author is exactly the person who will forget. It also forced every subclass to
//  restate `@unchecked Sendable`, because a non-final class cannot be checked.
//
//  Worse, it produced a real bug that is now unrepresentable: `ContextualService.scoped` is a
//  protocol-extension member, so its `Self.manifest` bound STATICALLY to the type declaring the
//  conformance — the abstract base — and every connection method reaching for a core setting
//  crashed the app at launch. With `Method.manifest` there is no dynamic dispatch to get wrong.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBDiagnostics
import BBProxy
import BBServiceKit
import BBSettings
import Foundation

/// What a connection method supplies. Everything else is `ProxyService`.
///
/// A protocol with two static requirements rather than a class to subclass: a method that
/// forgets one does not compile, where a missing override on a base class traps at start-up.
protocol ProxyMethod: Sendable {
  static var manifest: ServiceManifest { get }

  /// Builds this method's provider, or nil when it cannot — no binary, no credentials, no
  /// address. Returning nil is a normal, reported outcome; see `ProxyService.start`.
  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)?
}

/// What a method is handed to build its provider with.
///
/// The shared helpers moved here from the base class unchanged. They are on a value passed IN
/// rather than inherited, which is what lets `makeProvider` be a static on an enum — a method
/// is now data plus one function, with no instance and nothing to override.
struct ProxyHost: Sendable {

  let context: AppContext
  let manifest: ServiceManifest

  /// This service's scoped settings, resolved against the METHOD's manifest.
  ///
  /// Correct by construction now: the manifest is a stored property of this value, so there
  /// is no `Self` to bind to the wrong type. See the file header for the crash this replaces.
  var scoped: ScopedSettings { context.scopedSettings(for: manifest) }

  /// This service's own setting, read from its namespace.
  ///
  /// No entitlement needed and none possible to forget: ownership is the key's prefix, so a
  /// method physically cannot reach another's field through this.
  func own(_ field: String) async -> String { await scoped.own(field) }

  func ownFlag(_ field: String) async -> Bool { await scoped.ownFlag(field) }

  /// This service's own setting, or a fallback when it has never been written.
  ///
  /// `seedDefaults` fills a `select` in on first run, so this normally returns the stored
  /// value. It matters on the upgrade path: a field added to a manifest that a user already
  /// has configuration for is unset until the next seed, and an empty string passed on to
  /// cloudflared as `--protocol ''` is worse than the default it was meant to be.
  func ownOrDefault(_ field: String, _ fallback: String) async -> String {
    let value = await own(field).trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? fallback : value
  }

  /// The executable for this connection method's declared program.
  ///
  /// One line at each call site, and the resolution behind it — a binary the user pointed at,
  /// then the managed install, then whatever the app bundle happens to ship — is the same for
  /// every service that declares a tool, including one we did not write. That is the whole
  /// reason the tool is declared in the manifest rather than looked up by name here: a
  /// third-party connection method gets this by declaring, not by shipping code.
  func toolExecutable() async -> String? {
    guard let tool = manifest.tools.first else { return nil }
    return await context.tools.executablePath(for: tool.id)
  }

  /// The port to forward to — a CORE setting, so it goes through the scope and every
  /// connection method has to declare `.readSettings(keys: ["socket_port"])` for it. They all
  /// do; the declaration is what makes that visible on their permissions list.
  func forwardedPort() async -> Int {
    await scoped.getOrDefault(Settings.socketPort)
  }

  /// Reports a configuration this method cannot start with.
  ///
  /// **The body must NEVER quote a credential.** An alert is shown on screen, written to the
  /// log and carried in a diagnostic report, which is three more places than a token belongs.
  ///
  /// Shared because Cloudflare and zrok each had a private copy that differed only in the
  /// dedupe prefix — and only one of the two carried that warning.
  func complain(title: String, body: String, key: String) async {
    await context.alerts.raise(
      UserAlert(
        severity: .warning,
        title: title,
        body: body,
        source: "Connection",
        actions: [.openSettings(section: "settings")],
        dedupeKey: "proxy.\(manifest.id.rawValue).\(key)"
      )
    )
  }
}

/// One connection method, running. Generic over the method so there is nothing to override.
final class ProxyService<Method: ProxyMethod>: ContextualService, ConfigurableService,
  GatedService
{

  static var manifest: ServiceManifest { Method.manifest }

  /// Watches the selection plus its own namespace, so a change to either restarts it.
  ///
  /// Derived rather than hand-listed: a service's own fields are exactly the keys under its
  /// namespace, which is the whole point of owning one. The zrok bug — watching
  /// `zrok_token`, which nothing read, and not `zrok_reserved_token`, which built the
  /// provider — is unrepresentable now, because the list is computed from the manifest that
  /// declares the fields.
  static var watchedSettings: Set<String> {
    Set(Method.manifest.fields.map { Method.manifest.storageKey(for: $0.key) })
      .union([Settings.connectionMethod.key, Settings.socketPort.key])
  }

  /// Replaces the current recovery path, which retries ten times and then relaunches the
  /// entire application because one tunnel failed.
  static var restartPolicy: RestartPolicy {
    .backoff(base: .seconds(5), max: .seconds(120), attempts: 10)
  }

  let context: AppContext
  let coordinator: ProxyCoordinator

  init(host: AppContext) {
    let app = host
    self.context = app
    let name = Self.manifest.name
    let identifier = Self.manifest.id.rawValue
    self.coordinator = ProxyCoordinator(
      lastConnectionAt: { app.clientActivity.last },
      onAddressChanged: { address in
        // The one place the published address is written. Everything that needs it —
        // Firebase, the UI, server/info — reads it from settings.
        guard await app.settings.trySet(Settings.serverAddress, to: address) else {
          // The tunnel is up and nobody will be told where. Clients keep the old
          // address; Firebase keeps the old address. That is an outage with no symptom
          // on this side, so it is raised, not logged.
          await app.alerts.raise(
            UserAlert(
              severity: .error,
              title: "Could not save the server address",
              body:
                "\(name) is running at \(address), but the address could not be written to "
                + "settings, so clients and Firebase will not learn it.",
              source: identifier,
              dedupeKey: "\(identifier).address-not-saved"
            )
          )
          return
        }
      },
      onFailure: { reason in
        // A tunnel that has stopped coming back is not a log line. Every client is now
        // holding an address that resolves to nothing, and nothing else on screen will
        // say so — `health` reports "not connected", which is a state, not a summons.
        await app.alerts.raise(
          UserAlert(
            severity: .error,
            title: "\(name) has stopped",
            body: reason,
            source: "Connection",
            actions: [.openSettings(section: "settings")],
            dedupeKey: "proxy.gave-up.\(identifier)",
            // Whether the tunnel is down is re-established the moment it tries again.
            isDurable: false
          )
        )
      }
    )
  }

  /// Only the selected connection method runs.
  ///
  /// The exclusive category expressed at runtime: all five are registered, and four decline
  /// here. That is `GatedService`'s existing meaning, so nothing new was needed for it.
  func canRun() async -> Bool {
    await context.settings.get(Settings.connectionMethod) == Self.manifest.id.rawValue
  }

  /// What the method is handed to build its provider with.
  private var proxyHost: ProxyHost {
    ProxyHost(context: context, manifest: Method.manifest)
  }

  func start() async throws {
    guard let provider = await Method.makeProvider(proxyHost) else {
      // NOT a silent return. Cloudflare is the DEFAULT, so starting this service, finding
      // no binary and returning without a log line or an alert leaves a connection method
      // selected in the UI and a server nobody can reach.
      //
      // The remedy travels with the problem: the program is a managed tool, so the alert
      // offers to install it rather than describing a state and leaving the user to find
      // the button.
      let name = Self.manifest.name
      context.logger.error(
        "The selected connection method has no usable binary",
        metadata: ["connectionMethod": .string(Self.manifest.id.rawValue)]
      )
      let body: String
      let actions: [AlertAction]
      if let tool = Self.manifest.tools.first {
        body =
          "\(name) needs the \(tool.displayName) program, which is not installed "
          + "on this Mac, so no address is being published. Install it and the "
          + "tunnel starts on its own."
        actions = [.installTool(id: tool.id)]
      } else {
        body =
          "This server cannot start \(name) because its program is not installed, "
          + "so no address is being published. Choose a different connection method, "
          + "or install the program and restart."
        actions = [.openSettings(section: "settings")]
      }
      await context.alerts.raise(
        UserAlert(
          severity: .error,
          title: "\(name) is selected but not installed",
          body: body,
          source: "Connection",
          actions: actions,
          dedupeKey: "proxy.binary-missing.\(Self.manifest.id.rawValue)",
          // Re-checked at every start, so the fresh answer replaces this one rather
          // than sitting behind it.
          isDurable: false
        )
      )
      return
    }
    try await coordinator.start(provider)
  }

  func stop() async { await coordinator.stop() }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async { await coordinator.address == nil ? .inactive(reason: "not connected") : .running }
  }

}
