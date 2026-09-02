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
import BBInterfaces
import BBPrivateAPIContract
import BBProxy
import BBServiceKit
import BBSettings
import BBSystem
import BBTooling
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
      lastConnectionAt: { await app.lastClientActivityAt() },
      onAddressChanged: { address in
        // The one place the published address is written. Everything that needs it —
        // Firebase, the UI, server/info — reads it from settings.
        try? await app.settings.set(Settings.serverAddress, to: address)
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

// MARK: - Local network

enum LANMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.lan }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    let port = await host.forwardedPort()
    // A chosen address wins; empty falls back to the automatic pick. Resolved at CONNECT
    // time rather than captured, so a machine whose address changed while idle republishes
    // the new one rather than a stale value.
    let chosen = await host.own("address").trimmingCharacters(in: .whitespaces)
    return LANProxy(
      port: port,
      addressResolver: {
        guard !chosen.isEmpty else { return SystemInfo.primaryIPv4() }
        // Only if this Mac still HAS it — otherwise a pinned address that has since
        // moved gets published to every client as the way to reach a server that is
        // not there.
        let available = SystemInfo.localAddresses(.ipv4)
        return available.contains(chosen) ? chosen : SystemInfo.primaryIPv4()
      }
    )
  }
}

// MARK: - Dynamic DNS

enum DynamicDNSMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.dynamicDNS }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    // The one provider whose address is INPUT rather than output: the user maintains the
    // DNS record and this only republishes what they typed.
    let address = await host.own("address")
    guard !address.isEmpty else { return nil }
    return DynamicDNSProxy(address: address)
  }
}

// MARK: - Binary tunnels

enum NgrokMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.ngrok }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let path = await host.toolExecutable() else { return nil }

    let token = await host.own("auth_token").trimmingCharacters(in: .whitespaces)
    // ngrok refuses to open any tunnel without one, and it says so in output nobody
    // reads. Reported here, where the remedy is a field on this page.
    guard !token.isEmpty else {
      await host.context.alerts.raise(
        UserAlert(
          severity: .warning,
          title: "ngrok has no auth token",
          body: "ngrok will not open a tunnel without one. Paste the authtoken "
            + "from your ngrok dashboard on the ngrok page.",
          source: "Connection",
          actions: [.openSettings(section: "settings")],
          dedupeKey: "proxy.ngrok.token-missing"
        )
      )
      return nil
    }

    return Tunnels.ngrok(
      executablePath: path,
      port: await host.forwardedPort(),
      options: NgrokOptions(
        authToken: token,
        region: await host.ownOrDefault("region", NgrokOptions.Default.region),
        domain: await host.own("custom_domain"),
        hostHeader: await host.own("host_header"),
        disableInspection: await host.ownFlag("disable_inspection"),
        trafficPolicyFile: await host.own("traffic_policy_file"),
        verboseLogging: await host.ownFlag("verbose_logging"),
        // Declared on the manifest, so this read is allowed and is on the permissions
        // list. Not an ngrok option — it is a fact about the origin ngrok forwards to.
        originUsesTLS: await host.scoped.getOrDefault(Settings.useCustomCertificate)
      )
    )
  }
}

enum CloudflareMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.cloudflare }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let path = await host.toolExecutable() else { return nil }

    let mode = CloudflareOptions.Mode(rawValue: await host.ownOrDefault("mode", "quick")) ?? .quick
    let hostname = await host.own("hostname").trimmingCharacters(in: .whitespaces)
    let imported = await host.own("config_file").trimmingCharacters(in: .whitespaces)

    // Both named modes route a hostname the user owns, and cloudflared never prints it —
    // so without being told, there is nothing to publish to clients. Refusing here beats
    // starting a tunnel whose address this server cannot name.
    if mode != .quick, hostname.isEmpty {
      await host.complain(
        title: "Cloudflare needs the hostname your tunnel uses",
        body: "cloudflared does not report the address of a tunnel you configured "
          + "yourself. Enter it as the Public Hostname on the Cloudflare Tunnel page.",
        key: "hostname-missing"
      )
      return nil
    }

    var token = ""
    if mode == .token {
      // Read from the Keychain, because the field is declared `isSecret`. It goes no
      // further than `CloudflareOptions.environment` from here.
      token = await host.own("token").trimmingCharacters(in: .whitespaces)
      if token.isEmpty {
        await host.complain(
          title: "Cloudflare has no tunnel token",
          body: "Paste the token from your tunnel's page in the Cloudflare Zero "
            + "Trust dashboard on the Cloudflare Tunnel page.",
          key: "token-missing"
        )
        return nil
      }
    }

    if mode == .configuration {
      // A file the user pointed at but which is no longer there is reported, not
      // silently swapped for the generated one. Falling back quietly would start a quick
      // tunnel under a configuration the user believes is running theirs, publish a
      // trycloudflare address nobody expects, and give no hint why.
      guard !imported.isEmpty, FileManager.default.isReadableFile(atPath: imported) else {
        await host.complain(
          title: "The Cloudflare configuration file cannot be read",
          body: imported.isEmpty
            ? "Choose the `config.yml` for your tunnel on the Cloudflare Tunnel page."
            : "This server cannot read \(imported). Choose the file again on the "
              + "Cloudflare Tunnel page, or switch back to a quick tunnel.",
          key: "config-unreadable"
        )
        return nil
      }
    }

    // Their file when they supplied one; ours otherwise. Never cloudflared's own default
    // location — see `generatedConfigFile`.
    let configFile = mode == .configuration ? imported : Self.generatedConfigFile()
    guard let configFile else { return nil }

    return Tunnels.cloudflare(
      executablePath: path,
      port: await host.forwardedPort(),
      options: CloudflareOptions(
        configFile: configFile,
        mode: mode,
        token: token,
        hostname: hostname,
        transportProtocol: await host.ownOrDefault(
          "protocol", CloudflareOptions.Default.transportProtocol
        ),
        edgeIPVersion: await host.ownOrDefault(
          "edge_ip_version", CloudflareOptions.Default.edgeIPVersion
        ),
        region: await host.ownOrDefault("region", CloudflareOptions.Default.region),
        verboseLogging: await host.ownFlag("verbose_logging"),
        // Declared on the manifest, so this read is allowed and is on the permissions
        // list. Not a Cloudflare option and not offered as one — see `CloudflareOptions`.
        originUsesTLS: await host.scoped.getOrDefault(Settings.useCustomCertificate)
      )
    )
  }

  /// This service's own, deliberately empty, cloudflared configuration file.
  ///
  /// It exists so that cloudflared can be pointed AWAY from `~/.cloudflared/config.yml`.
  /// Cloudflare documents quick tunnels as unsupported when cloudflared finds a configuration
  /// of its own, so a user who runs cloudflared for something else had this server's default
  /// connection method fail with nothing on screen to explain it.
  ///
  /// Rewritten on every start rather than only when absent: the cost is one small write, and
  /// the alternative is trusting a file on disk that anything could have edited since.
  private static func generatedConfigFile() -> String? {
    let directory = SocketLocation.supportDirectory + "/cloudflared"
    let path = directory + "/config.yml"
    let contents = """
      # Written by BlueBubbles. Do not edit.
      #
      # Deliberately empty. Its only job is to be the file cloudflared reads INSTEAD of
      # ~/.cloudflared/config.yml, which would otherwise stop quick tunnels working for
      # anyone who runs cloudflared for something else. Everything this server configures
      # is passed on the command line.
      #
      # To run a tunnel of your own, import its configuration on the Cloudflare Tunnel
      # page rather than editing this file — it is overwritten every time the tunnel
      # starts.

      """
    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
      )
      try contents.write(toFile: path, atomically: true, encoding: .utf8)
      return path
    } catch {
      return nil
    }
  }
}

/// zrok, which is the only connection method with a SETUP as well as a configuration.
///
/// cloudflared and ngrok are handed a credential and start. zrok is not: this Mac has to be
/// enabled against a zrok account first, and a share that keeps its address has to be reserved
/// by a separate command that hands back a token to remember. The TypeScript `ZrokManager` did
/// all of that; the port did none of it, so the Account Token field on the zrok page was
/// collected, stored, and read by nothing — the tunnel ran as an anonymous share or not at all.
///
/// The one-shot half lives in `ZrokEnvironment`. This is where it is decided WHICH of those
/// commands need to run, which is a question only the stored configuration can answer.
enum ZrokMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.zrok }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let path = await host.toolExecutable() else { return nil }

    let accountToken = await host.own("account_token").trimmingCharacters(in: .whitespaces)
    guard !accountToken.isEmpty else {
      await host.complain(
        title: "zrok has no account token",
        body: "zrok cannot share anything until this Mac is linked to a zrok account. "
          + "Create a free account at zrok.io and paste the account token on the "
          + "zrok page.",
        key: "account-token-missing"
      )
      return nil
    }

    var options = ZrokOptions(
      verboseLogging: await host.ownFlag("verbose_logging"),
      // Declared on the manifest, so this read is allowed and is on the permissions
      // list. Not a zrok option — it is a fact about the origin zrok proxies to.
      originUsesTLS: await host.scoped.getOrDefault(Settings.useCustomCertificate),
      apiEndpoint: await host.own("api_endpoint")
    )

    let environment = ZrokEnvironment(
      executablePath: path,
      // The same environment for every zrok invocation — the share, the enable, the
      // reserve — so a self-hosted controller cannot be reached by some of them and not
      // by others.
      environment: options.environment,
      logger: host.context.logger
    )

    do {
      if try await environment.enableIfNeeded(accountToken: accountToken) {
        host.context.logger.info("Linked this Mac to a zrok account")
      }
    } catch let error as ZrokError {
      await host.complain(
        title: error == .invalidAccountToken
          ? "zrok rejected the account token"
          : "zrok could not be set up on this Mac",
        body: error == .invalidAccountToken
          ? "Check the account token on the zrok page against the one on your zrok "
            + "account, and paste it again."
          : "zrok said: \(error.message)",
        key: "enable-failed"
      )
      return nil
    } catch {
      return nil
    }

    let port = await host.forwardedPort()
    let endpoint = options.target(port: port)

    if await host.ownFlag("reserve_tunnel") {
      guard
        let token = await reservedShareToken(
          host: host,
          using: environment, endpoint: endpoint, backendMode: options.backendMode
        )
      else { return nil }
      options.reservedToken = token
    } else {
      // Reserving is off, so anything reserved earlier is now unused. Letting go of it
      // is what the TypeScript server did, and leaving it would quietly go on occupying
      // a name on the user's account that they can no longer see from here.
      await forgetReservedShare(host: host, using: environment)
    }

    return Tunnels.zrok(executablePath: path, port: port, options: options)
  }

  // MARK: - Reserved shares

  /// The token of the reserved share this server should use, reserving one if it must.
  ///
  /// Returns nil only when it could not get one AND has said so.
  private static func reservedShareToken(
    host: ProxyHost,
    using environment: ZrokEnvironment,
    endpoint: String,
    backendMode: String
  ) async -> String? {
    let storedToken = await host.own("reserved_token").trimmingCharacters(in: .whitespaces)
    let desiredName = await host.own("reserved_name").trimmingCharacters(in: .whitespaces)

    // Shares belonging to THIS Mac. The filter is not optional: one zrok account can hold
    // several machines' environments, and without it two servers sharing an account would
    // each adopt the other's share.
    let existing: [ZrokShare]
    do {
      existing = try await environment.shares(ownedBy: SystemInfo.computerIdentifier())
    } catch {
      // zrok could not be asked. Reserving anyway would create a duplicate every time
      // the network is down, so the stored token is used as-is and the problem is left
      // to the tunnel itself to report.
      host.context.logger.warning(
        "Could not read the zrok share list; using the stored share",
        metadata: ["error": .string(String(describing: error))]
      )
      guard !storedToken.isEmpty else {
        await host.complain(
          title: "zrok could not be reached",
          body: "This server needs to ask zrok about your reserved shares before it "
            + "can start one, and that request failed. Check this Mac's internet "
            + "connection, or switch reserving off to use a throwaway share.",
          key: "overview-failed"
        )
        return nil
      }
      return storedToken
    }

    // A share reserved with `--unique-name X` HAS `X` as its token, which is what makes
    // "the name changed" detectable at all.
    let wantedToken = desiredName.isEmpty ? storedToken : desiredName

    if !wantedToken.isEmpty,
      let share = existing.first(where: { $0.token == wantedToken }),
      share.matches(endpoint: endpoint, backendMode: backendMode)
    {
      // Already exactly what is wanted. Written back only when it differs, because every
      // settings write is broadcast and this service restarts on its own keys — an
      // unconditional write here would restart the tunnel on every launch, forever.
      if storedToken != share.token {
        try? await host.scoped.setOwn(share.token, field: "reserved_token")
      }
      return share.token
    }

    // Whatever is stored is stale — the port moved, the name changed, or the share was
    // deleted from the zrok dashboard. Let go of it before reserving its replacement, or
    // the account accumulates one abandoned share per change.
    if !storedToken.isEmpty {
      await forgetReservedShare(host: host, using: environment)
    }

    do {
      let token = try await environment.reserve(
        endpoint: endpoint, name: desiredName, backendMode: backendMode
      )
      try? await host.scoped.setOwn(token, field: "reserved_token")
      host.context.logger.info("Reserved a zrok share")
      return token
    } catch let error as ZrokError {
      await host.complain(
        title: "zrok could not reserve a share",
        body: "zrok said: \(error.message)",
        key: "reserve-failed"
      )
      return nil
    } catch {
      return nil
    }
  }

  /// Releases the stored reserved share and forgets its token.
  ///
  /// Honours "Keep Reserved Shares", which exists because deleting something from a user's
  /// zrok account is not a thing a toggle on a settings page should do silently.
  private static func forgetReservedShare(host: ProxyHost, using environment: ZrokEnvironment)
    async
  {
    let token = await host.own("reserved_token").trimmingCharacters(in: .whitespaces)
    guard !token.isEmpty else { return }

    if await host.ownFlag("keep_share") {
      host.context.logger.info("Leaving a reserved zrok share in place, as configured")
    } else {
      await environment.release(token: token)
    }
    // Forgotten either way: this server is no longer using it, and a token left behind is
    // one that would be adopted again the next time reserving is switched on.
    try? await host.scoped.setOwn("", field: "reserved_token")
  }

}

// MARK: - Binaries

/// Where a BUNDLED tunnel executable is found.
///
/// No longer the primary source: `ToolManager` downloads and version-manages these, and this
/// is the last thing it falls back to. Kept rather than deleted for two cases that are both
/// real — a build that deliberately ships its binaries (offline or enterprise installs), and
/// a development tree with one dropped next to the executable.
///
/// `Packaging/build-app.sh` still copies nothing here, so on a stock build this returns nil
/// and the managed install is what serves every user.
public enum BundledBinaries {
  /// Inside the app bundle when packaged; alongside the executable in development.
  static func path(for name: String) -> String? {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path,
      Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent(name).path,
    ].compactMap { $0 }

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
