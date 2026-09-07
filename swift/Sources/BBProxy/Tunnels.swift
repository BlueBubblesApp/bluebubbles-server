//  Tunnels
//  The five proxy options.
//
//  Three drive a bundled binary through DaemonProcess; two do not tunnel at all and exist so
//  the rest of the server does not have to special-case "no tunnel".
//
//  See `.claude/docs/performance.md`.

import BBCore
import BBServiceKit
import BBSystem
import Foundation
import Logging

// MARK: - Binary-backed tunnels

/// Shared shape for the three that spawn a process and scrape a URL out of its output.
public actor BinaryTunnel: ProxyProviding {

  public nonisolated let identifier: ServiceIdentifier
  public nonisolated let requiresRefresh: Bool

  private let daemon: DaemonProcess
  private let readiness: ReadinessSignal
  private let logger: Logger
  private let restartDelay: Duration
  private var address: String?
  private var observer: ProxyObserver?
  private var reconnectTask: Task<Void, Never>?
  /// Whether a start is in flight, and whether the daemon died during one. See `runDaemon`.
  private var isBusy = false
  private var pendingExit = false

  public init(
    identifier: ServiceIdentifier,
    requiresRefresh: Bool,
    configuration: DaemonConfiguration,
    readiness: ReadinessSignal,
    logger: Logger = Logger(label: "bluebubbles.proxy.tunnel")
  ) {
    self.identifier = identifier
    self.requiresRefresh = requiresRefresh
    self.readiness = readiness
    self.logger = logger
    self.restartDelay = configuration.restartDelay
    self.daemon = DaemonProcess(configuration: configuration, logger: logger)
  }

  public var currentAddress: String? { address }

  public func observe(_ observer: ProxyObserver) async {
    self.observer = observer
  }

  public func connect() async throws -> String {
    // `DaemonProcess` has carried a restart budget and a `shouldRestart()` to spend it
    // since it was written, and NOTHING production ever called either: `onExit` was left
    // at its default no-op, so a tunnel that died stayed dead. The server went on
    // publishing an address that resolved to nothing, and the only way back was to
    // restart the whole application.
    await daemon.onTermination { [weak self] code in
      await self?.handleUnexpectedExit(code: code)
    }

    do {
      guard let url = try await runDaemon() else {
        throw ProxyError.addressUnavailable
      }
      address = url
      // It may ALREADY be dead. A daemon that prints its URL and exits immediately —
      // cloudflared rate-limited, a port taken — terminates while this call is still
      // unwinding, and `handleUnexpectedExit` deliberately does nothing in that window.
      // Acting on it here, once the address is settled, is what keeps the two off each
      // other's toes.
      if consumePendingExit() { startReconnect() }
      return url
    } catch let error as DaemonError {
      // The daemon's own output is the only useful explanation — "ngrok exited with 1"
      // tells the user nothing, while its message usually names the actual problem
      // (an expired authtoken, a port already forwarded, a missing login).
      throw ProxyError.tunnelFailed(reason: Self.describe(error))
    }
  }

  public func disconnect() async {
    reconnectTask?.cancel()
    reconnectTask = nil
    await daemon.stop()
    address = nil
    pendingExit = false
  }

  // MARK: - Coming back

  /// Starts the daemon, marking the tunnel busy for the duration.
  ///
  /// The busy window is what makes the restart safe. `DaemonProcess.start` owns a single
  /// readiness continuation, so a second start racing the first leaves one of the two waiters
  /// with nothing to resume it — the caller then waits out the whole readiness timeout and is
  /// told the tunnel never reported a URL, while the tunnel is up and running.
  private func runDaemon() async throws -> String? {
    isBusy = true
    defer { isBusy = false }
    return try await daemon.start(waitingFor: readiness)
  }

  /// The tunnel process died without being asked to.
  private func handleUnexpectedExit(code: Int32) async {
    logger.warning(
      "The tunnel exited on its own",
      metadata: [
        "kind": .string(identifier.shortName),
        "code": .stringConvertible(code),
      ])
    address = nil

    // Somebody is inside `daemon.start` right now and owns the readiness continuation.
    // Recorded rather than acted on; whoever is in there picks it up when they are done.
    guard !isBusy else {
      pendingExit = true
      return
    }
    startReconnect()
  }

  private func startReconnect() {
    // One reconnect at a time. Each failed attempt inside the loop produces its own
    // termination, and without this every one of them would start a competing loop.
    guard reconnectTask == nil else { return }
    reconnectTask = Task { [weak self] in await self?.reconnect() }
  }

  /// Reads and clears the "it died while we were starting it" flag.
  private func consumePendingExit() -> Bool {
    defer { pendingExit = false }
    return pendingExit
  }

  /// Restarts the daemon until it comes back or the budget runs out.
  private func reconnect() async {
    defer { reconnectTask = nil }

    while !Task.isCancelled {
      // The budget resets itself once the tunnel has run for longer than the
      // configuration's restart window, so a tunnel that dies once a day is retried
      // forever while one that cannot start at all gives up after ten tries.
      guard await daemon.shouldRestart() else {
        let reason =
          "The \(identifier.shortName) tunnel exited repeatedly and will not be "
          + "restarted again. Check the server log for what it printed on the way out."
        logger.error("Giving up on the tunnel", metadata: ["kind": .string(identifier.shortName)])
        await observer?.failed(reason)
        return
      }

      try? await Task.sleep(for: restartDelay)
      if Task.isCancelled { return }

      do {
        guard let url = try await runDaemon() else { return }
        address = url
        // Published unconditionally rather than only when it differs. For a quick
        // tunnel it always differs — that is the whole reason this path exists — and
        // for a stable one re-publishing the same string costs a settings write.
        await observer?.addressChanged(url)

        // Up, and then straight back down: a tunnel that is being rate-limited comes
        // back just long enough to announce itself. Looping keeps it inside the restart
        // budget, which is what eventually reports the problem instead of hiding it in
        // an endless cycle of announcements.
        if consumePendingExit() { continue }

        logger.info("The tunnel is back", metadata: ["kind": .string(identifier.shortName)])
        return
      } catch let error as DaemonError {
        // A start that fails resumes its own readiness continuation, so no termination
        // callback follows it. Looping here is what keeps trying.
        _ = consumePendingExit()
        logger.warning(
          "The tunnel did not come back yet",
          metadata: [
            "kind": .string(identifier.shortName),
            "reason": .string(Self.describe(error)),
          ])
      } catch {
        return
      }
    }
  }

  static func describe(_ error: DaemonError) -> String {
    switch error {
    case .executableMissing(let path):
      "the tunnel program is missing at \(path)"
    case .launchFailed(let reason):
      reason
    case .exitedBeforeReady(let code, let output):
      output.isEmpty ? "the tunnel exited with code \(code)" : output
    case .readyTimeout(let after):
      "the tunnel did not report a URL within \(Int(after.seconds)) seconds"
    }
  }
}

// MARK: - Cloudflare

/// Everything about a Cloudflare tunnel that is not the port it forwards to.
///
/// A struct rather than a widening argument list because most of it is optional and defaulted,
/// and a call site passing six bare strings in the right order is one refactor away from
/// passing them in the wrong one.
public struct CloudflareOptions: Sendable, Equatable {

  /// cloudflared's OWN defaults, named so the argument builder can tell "the user left this
  /// alone" apart from "the user chose this", and skip a flag that would only restate a
  /// default. See the note in `Tunnels.cloudflare`.
  public enum Default {
    public static let transportProtocol = "auto"
    public static let edgeIPVersion = "4"
    public static let region = "global"
  }

  /// How this tunnel is established, which decides the whole command line.
  public enum Mode: String, Sendable, Equatable, CaseIterable {
    /// No account. cloudflared invents a `trycloudflare.com` address and prints it.
    case quick
    /// A named tunnel, run from a token issued by the Cloudflare Zero Trust dashboard.
    /// Its routing lives in the dashboard, not here.
    case token
    /// A named tunnel described by a `config.yml` the user wrote and imported.
    case configuration = "config"
  }

  public var mode: Mode
  /// The tunnel token, for `.token`.
  ///
  /// Passed to cloudflared through the environment rather than on the command line — see
  /// `environment`. Held here as a plain `String` only for as long as it takes to build that
  /// environment; at rest it lives in the Keychain.
  public var token: String
  /// The configuration file cloudflared is pointed at, which is never left to chance.
  ///
  /// Either the file the user imported or an empty one this server owns and writes.
  public var configFile: String
  /// The address to publish, for a tunnel whose hostname this server cannot discover.
  ///
  /// Empty for a quick tunnel, where the address is scraped from cloudflared's output
  /// instead — which is the only case where scraping is possible at all.
  public var hostname: String
  public var transportProtocol: String
  public var edgeIPVersion: String
  public var region: String
  public var verboseLogging: Bool
  /// Whether THIS server terminates TLS, from `use_custom_certificate`. Not a Cloudflare
  /// setting and deliberately not offered as one — it is a fact about the origin that
  /// cloudflared has to be told, and asking the user to keep two switches in agreement is
  /// how they end up disagreeing.
  public var originUsesTLS: Bool

  public init(
    configFile: String,
    mode: Mode = .quick,
    token: String = "",
    hostname: String = "",
    transportProtocol: String = Default.transportProtocol,
    edgeIPVersion: String = Default.edgeIPVersion,
    region: String = Default.region,
    verboseLogging: Bool = false,
    originUsesTLS: Bool = false
  ) {
    self.mode = mode
    self.token = token
    self.configFile = configFile
    self.hostname = hostname
    self.transportProtocol = transportProtocol
    self.edgeIPVersion = edgeIPVersion
    self.region = region
    self.verboseLogging = verboseLogging
    self.originUsesTLS = originUsesTLS
  }

  /// The hostname as a URL, or nil when there is none and the address must be scraped.
  ///
  /// Defaults to https for the same reason `DynamicDNSProxy` does: a tunnel terminates TLS
  /// at Cloudflare's edge, so a hostname routed through one is reachable over https whether
  /// or not the user typed the scheme.
  ///
  /// Only a quick tunnel has none. The other two modes route a hostname the user owns, and
  /// cloudflared never prints it — it is in their dashboard or their configuration file, and
  /// it has no reason to be repeated back.
  public var publishedAddress: String? {
    guard mode != .quick else { return nil }
    let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
  }

  /// The environment cloudflared is launched with.
  ///
  /// **The token goes here rather than on the command line, and that is the point.** A
  /// process's arguments are world-readable on macOS — any local user can run `ps` and read
  /// them — so `--token <secret>` would publish a credential that grants control of the
  /// user's tunnel to every account on the machine. A process's ENVIRONMENT is not: reading
  /// another user's requires root.
  ///
  /// `TUNNEL_TOKEN` is what cloudflared itself declares for this flag, so nothing here is
  /// improvised. It is also the portable choice — `--token-file` would work too but only
  /// from cloudflared 2025.4.0, and a user may have pointed us at an older binary of their
  /// own.
  public var environment: [String: String] {
    guard mode == .token, !token.isEmpty else { return [:] }
    return ["TUNNEL_TOKEN": token]
  }

  /// The full cloudflared command line, minus the executable.
  ///
  /// Split out from `Tunnels.cloudflare` so it can be checked without spawning anything.
  /// What goes on this line is the entire behaviour worth testing here — which flags appear,
  /// which are deliberately absent, and which side of the subcommand they fall on — and
  /// burying it inside a `BinaryTunnel`'s private configuration would leave the one
  /// interesting part of this file unreachable.
  public func arguments(forwardingTo port: Int) -> [String] {
    // The origin scheme FOLLOWS this server rather than being assumed.
    //
    // It was hardcoded to http, and "Serve over HTTPS" on the Connection page makes the
    // local server speak TLS — so turning that on silently broke Cloudflare, with
    // cloudflared retrying against a port that would not talk to it in plaintext.
    let scheme = originUsesTLS ? "https" : "http"

    var global = [
      "tunnel",
      // ALWAYS, and this is not a preference.
      //
      // Cloudflare documents quick tunnels as unsupported when cloudflared finds a
      // configuration file of its own, and it looks in `~/.cloudflared/config.yml` by
      // default. A user who runs their own cloudflared for something else therefore had
      // this server's default connection method fail for a reason nothing on screen
      // could explain. Pointing at a file we control means their file is never read
      // unless they asked us to read it. The TypeScript server did this deliberately;
      // the port dropped it.
      "--config", configFile,
      "--no-autoupdate",
      // Otherwise cloudflared writes its own update files next to the binary, which
      // lives inside the app bundle and is not writable.
      "--logfile", "/dev/stdout",
    ]

    // Passed only where the user chose something OTHER than cloudflared's own default,
    // and never at all in config-file mode.
    //
    // A flag beats a config file. In the other modes that is the order someone expects:
    // say nothing and their file stays in charge, change a control here and it wins. In
    // config-file mode the user has said the file IS the configuration, so this server
    // emits none of these — the UI greys them out to match, and the two have to agree or
    // the greying is a decoration over a flag still being passed.
    //
    // `--loglevel` is deliberately NOT in this block; see below.
    if mode != .configuration {
      if transportProtocol != Default.transportProtocol {
        global.append(contentsOf: ["--protocol", transportProtocol])
      }
      if edgeIPVersion != Default.edgeIPVersion {
        global.append(contentsOf: ["--edge-ip-version", edgeIPVersion])
      }
      if region != Default.region {
        // Only ever sent as `us`. Older cloudflared builds reject `--region global`
        // outright, and it is the default anyway, so the flag has nothing to add.
        global.append(contentsOf: ["--region", region])
      }
    }

    // Passed in EVERY mode, config file included. Verbose logging is not tunnel
    // configuration — it is how someone diagnoses a tunnel that will not start, which is
    // exactly the moment a config-file user needs it and the worst moment to make them
    // edit a YAML file and restart to get it.
    if verboseLogging {
      global.append(contentsOf: ["--loglevel", "debug"])
    }

    // Where to find this server. For the two named modes this is a FALLBACK rather than
    // the routing: cloudflared prefers ingress rules from the configuration file, then
    // from the dashboard, and reaches for `--url` only when neither says anything. Passing
    // it costs nothing when they do and saves a tunnel that connects to nowhere when they
    // do not.
    var origin = ["--url", "\(scheme)://localhost:\(port)"]
    if originUsesTLS {
      // The certificate on localhost is either the one imported on the Security page or
      // a self-signed stand-in, and neither chains to anything cloudflared trusts.
      // Verification here would be checking this Mac's identity against itself over the
      // loopback interface; the connection that matters is the TLS one cloudflared makes
      // outward to Cloudflare, which this does not touch.
      origin.append("--no-tls-verify")
    }

    // The subcommand split is not cosmetic: cloudflared declares these flags on
    // `tunnel run`, and a flag on the wrong side of the subcommand is a usage error rather
    // than something it quietly tolerates.
    return switch mode {
    case .quick:
      global + origin
    case .token:
      // No `--token` here. It arrives through `TUNNEL_TOKEN`; see `environment`.
      global + ["run"] + origin
    case .configuration:
      // The tunnel's name or UUID comes from the `tunnel:` key in the user's own file,
      // which is why this takes no argument.
      global + ["run"] + origin
    }
  }
}

// MARK: - ngrok

/// Everything about an ngrok tunnel that is not the port it forwards to.
///
/// The same shape as `CloudflareOptions`, for the same reason: ngrok's agent has far more to
/// say than "here is a token", and a factory function growing one argument per option is how
/// six bare strings end up passed in the wrong order.
///
/// **Only the ngrok v3 agent's flags are here.** The managed install tracks ngrok's stable
/// channel, which has been v3 since 2022; the v2 spellings (`--hostname`, `--subdomain`) are
/// deliberately absent rather than emitted as a fallback, because an agent that accepts one
/// set rejects the other outright.
public struct NgrokOptions: Sendable, Equatable {

  /// ngrok's OWN defaults, named so the argument builder can tell "the user left this alone"
  /// apart from "the user chose this". Same rule as Cloudflare: a flag restating a default
  /// is a flag that overrules the user's own `ngrok.yml`, so an untouched option is not
  /// passed at all.
  public enum Default {
    public static let region = "us"
  }

  // ONLY HTTP endpoints, and that is a decision rather than an omission.
  //
  // `ngrok_protocol` existed in the TypeScript server and offered TCP, and that server then
  // forced the value back to `http` on EVERY launch — see its `Server.setup`. A TCP endpoint
  // publishes a bare host and port rather than a URL, which no BlueBubbles client can use,
  // so the option was closed off deliberately rather than forgotten. Re-exposing it as a
  // setting would be reintroducing one whose only effect is a server nobody can reach.
  //
  // The legacy migration still carries `ngrok_protocol` forward into this service's
  // namespace, where nothing reads it. That is on purpose too: a value a user typed is not
  // thrown away just because it currently has no field.

  /// The agent authtoken.
  ///
  /// Passed through the environment rather than on the command line — see `environment` —
  /// and held here only for as long as it takes to build that environment. At rest it is in
  /// the Keychain.
  public var authToken: String
  public var region: String
  /// A domain reserved on the user's ngrok dashboard. Paid plans only; empty means ngrok
  /// invents one that changes on every restart.
  public var domain: String
  /// What ngrok puts in the `Host:` header it sends this server. `rewrite` makes it match
  /// the upstream, which is what a virtual host expects.
  public var hostHeader: String
  /// Turns off ngrok's request inspector.
  ///
  /// False here means "not specified", NOT "inspection is fine" — like every other field on
  /// this type, an unset value emits no flag at all, so whatever is in the user's own
  /// `ngrok.yml` stays in charge. The PRODUCT default lives in the ngrok manifest, which
  /// seeds `disable_inspection` on, and that is what a real install runs with.
  ///
  /// Keeping the two apart matters: this type's contract is "emit only what was chosen",
  /// and defaulting it true here would make the server pass `--inspect=false` even to
  /// somebody who had deliberately configured the inspector on in `ngrok.yml`, with no way
  /// to express "leave it alone".
  public var disableInspection: Bool
  /// A traffic policy file, ngrok's own configuration escape hatch. Empty means none.
  public var trafficPolicyFile: String
  public var verboseLogging: Bool
  /// Whether THIS server terminates TLS, from `use_custom_certificate`. Same fact
  /// `CloudflareOptions` carries and for the same reason: it is not an ngrok preference, it
  /// is something the agent has to be told about the origin it is forwarding to.
  public var originUsesTLS: Bool

  public init(
    authToken: String = "",
    region: String = Default.region,
    domain: String = "",
    hostHeader: String = "",
    disableInspection: Bool = false,
    trafficPolicyFile: String = "",
    verboseLogging: Bool = false,
    originUsesTLS: Bool = false
  ) {
    self.authToken = authToken
    self.region = region
    self.domain = domain
    self.hostHeader = hostHeader
    self.disableInspection = disableInspection
    self.trafficPolicyFile = trafficPolicyFile
    self.verboseLogging = verboseLogging
    self.originUsesTLS = originUsesTLS
  }

  /// The environment ngrok is launched with.
  ///
  /// **The authtoken goes here rather than on the command line.** It was an argument, and a
  /// process's arguments are world-readable on macOS — any local account could run `ps` and
  /// walk away with a credential that controls the user's ngrok tunnels. A process's
  /// environment is not: reading another user's requires root. `NGROK_AUTHTOKEN` is ngrok's
  /// own documented variable for exactly this, so nothing here is improvised.
  ///
  /// This is the same fix `CloudflareOptions.environment` describes; ngrok simply had it
  /// wrong for longer.
  public var environment: [String: String] {
    let trimmed = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    return ["NGROK_AUTHTOKEN": trimmed]
  }

  /// The full ngrok command line, minus the executable.
  ///
  /// Split out from `Tunnels.ngrok` so what goes on it can be checked without spawning
  /// anything — which flags appear, which are deliberately absent, and which are illegal for
  /// the chosen protocol.
  public func arguments(forwardingTo port: Int) -> [String] {
    var arguments = ["http", target(port: port)]

    // Always. The URL is scraped out of this, and `--log stdout` is what puts it on the
    // pipe `DaemonProcess` is reading instead of in a file nobody looks at.
    arguments.append(contentsOf: ["--log", "stdout", "--log-format", "logfmt"])
    if verboseLogging {
      arguments.append(contentsOf: ["--log-level", "debug"])
    }

    if !region.trimmed.isEmpty, region.trimmed != Default.region {
      arguments.append(contentsOf: ["--region", region.trimmed])
    }

    // `--domain` is v3's spelling; `--hostname` and `--subdomain` were v2's and are
    // rejected outright by the agent this server installs. A reserved domain on a free
    // account is refused with ERR_NGROK_313, which surfaces as the daemon's own output.
    if !domain.trimmed.isEmpty {
      arguments.append(contentsOf: ["--domain", domain.trimmed])
    }
    if !hostHeader.trimmed.isEmpty {
      arguments.append(contentsOf: ["--host-header", hostHeader.trimmed])
    }

    if disableInspection {
      // `--inspect=false` as one token: it is a boolean flag, and `--inspect false`
      // would be parsed as the flag followed by a positional argument.
      arguments.append("--inspect=false")
    }
    if !trafficPolicyFile.trimmed.isEmpty {
      arguments.append(contentsOf: ["--traffic-policy-file", trafficPolicyFile.trimmed])
    }

    return arguments
  }

  /// What ngrok forwards to.
  ///
  /// A URL rather than a bare port, so the scheme can FOLLOW this server rather than being
  /// assumed: "Serve over HTTPS" makes the local server speak TLS, and a bare port means
  /// plaintext — so turning that setting on left ngrok forwarding into a socket that would
  /// never answer it. Exactly the bug `CloudflareOptions.arguments` describes; ngrok had it
  /// too.
  private func target(port: Int) -> String {
    "\(originUsesTLS ? "https" : "http")://localhost:\(port)"
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - zrok

/// Everything about a zrok share that is not the port it forwards to.
///
/// zrok is the odd one of the three, and the reason is worth stating up front: cloudflared and
/// ngrok are given a token on every launch and get to work, while zrok has a SETUP that
/// happens outside the share command — an account token enables this Mac once, and a reserved
/// share is created by a separate command that hands back a token. `ZrokEnvironment` owns that
/// half; this struct is only the long-running `zrok share` that follows it.
public struct ZrokOptions: Sendable, Equatable {

  /// The token of a reserved share, or empty for a throwaway public share.
  ///
  /// Not a user credential in the ngrok sense — it names a share, and `ZrokEnvironment`
  /// writes it back into settings after reserving one. Kept secret anyway: it is a
  /// capability to serve on someone's zrok account.
  public var reservedToken: String
  /// zrok's backend mode. `proxy` is what a web server wants; the others serve files or wrap
  /// a raw socket and would not carry this server's API.
  public var backendMode: String
  public var verboseLogging: Bool
  /// Whether THIS server terminates TLS, from `use_custom_certificate`. Decides the scheme
  /// zrok proxies to, and whether it is told not to verify a certificate that is either
  /// self-signed or privately imported. Same fact `CloudflareOptions` carries.
  public var originUsesTLS: Bool
  /// A self-hosted zrok controller, for people not using zrok.io. Empty means zrok's own.
  public var apiEndpoint: String

  public init(
    reservedToken: String = "",
    backendMode: String = "proxy",
    verboseLogging: Bool = false,
    originUsesTLS: Bool = false,
    apiEndpoint: String = ""
  ) {
    self.reservedToken = reservedToken
    self.backendMode = backendMode
    self.verboseLogging = verboseLogging
    self.originUsesTLS = originUsesTLS
    self.apiEndpoint = apiEndpoint
  }

  public var isReserved: Bool {
    !reservedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// What zrok proxies to.
  ///
  /// The scheme follows this server rather than being assumed, for the third time in this
  /// file and for the same reason each time: "Serve over HTTPS" makes the local server speak
  /// TLS, and a share pointed at `http://` then forwards into a port that will not answer in
  /// plaintext.
  public func target(port: Int) -> String {
    "\(originUsesTLS ? "https" : "http")://localhost:\(port)"
  }

  /// The environment zrok is launched with.
  ///
  /// `ZROK_API_ENDPOINT` is zrok's own variable for pointing the agent at a controller other
  /// than zrok.io. Setting it here rather than writing zrok's configuration file means a
  /// self-hoster's own `~/.zrok` is left exactly as they left it.
  ///
  /// It is on the environment rather than the command line because every zrok invocation
  /// needs it — the share, the enable, the reserve, the release — and one environment shared
  /// by all of them cannot drift the way four flag lists can.
  public var environment: [String: String] {
    let trimmed = apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    return ["ZROK_API_ENDPOINT": trimmed]
  }

  /// The full `zrok share` command line, minus the executable.
  public func arguments(forwardingTo port: Int) -> [String] {
    let token = reservedToken.trimmingCharacters(in: .whitespacesAndNewlines)
    var arguments: [String]

    if token.isEmpty {
      // A throwaway share: zrok invents an address, and it is gone when the process is.
      arguments = [
        "share", "public", target(port: port),
        "--headless", "--backend-mode", backendMode,
      ]
    } else {
      // A reserved share already knows its backend mode from when it was reserved.
      // `--override-endpoint` is what lets the port change without re-reserving.
      arguments = [
        "share", "reserved", token,
        "--headless", "--override-endpoint", target(port: port),
      ]
    }

    if originUsesTLS {
      // The certificate on loopback is self-signed or privately imported, so it chains
      // to nothing zrok trusts. Verifying it would be checking this Mac against itself
      // over its own loopback interface; the connection that matters is the one zrok
      // makes outward.
      arguments.append("--insecure")
    }
    if verboseLogging {
      arguments.append("-v")
    }

    return arguments
  }
}

// MARK: - Concrete configurations

public enum Tunnels {

  /// ngrok. Its free tier expires sessions, hence the refresh timer.
  public static func ngrok(
    executablePath: String,
    port: Int,
    options: NgrokOptions = NgrokOptions(),
    logger: Logger = Logger(label: "bluebubbles.proxy.ngrok")
  ) -> BinaryTunnel {
    BinaryTunnel(
      identifier: ServiceIdentifier("app.bluebubbles.proxy.ngrok"),
      // The reason ProxyCoordinator has a refresh timer at all.
      requiresRefresh: true,
      configuration: DaemonConfiguration(
        name: "ngrok",
        executablePath: executablePath,
        arguments: options.arguments(forwardingTo: port),
        // The authtoken lives in here rather than on the command line; see
        // `NgrokOptions.environment` for why that matters.
        environment: options.environment
      ),
      readiness: ReadinessSignal { line in
        // logfmt: `... url=https://xxxx.ngrok-free.app ...`. Matched on the key
        // rather than by searching for "https", because the log also contains the
        // ngrok API's own URL and matching that yields a tunnel to nowhere.
        guard let range = line.range(of: "url=https://") else { return nil }
        let tail = line[range.lowerBound...].dropFirst("url=".count)
        return String(tail.prefix { !$0.isWhitespace })
      },
      logger: logger
    )
  }

  /// Cloudflare Tunnel.
  public static func cloudflare(
    executablePath: String,
    port: Int,
    options: CloudflareOptions,
    logger: Logger = Logger(label: "bluebubbles.proxy.cloudflare")
  ) -> BinaryTunnel {
    // Normalised once, out here, rather than inside the readiness closure: the closure runs
    // per line of output and this does not change between them.
    let announcedAddress = options.publishedAddress

    return BinaryTunnel(
      identifier: ServiceIdentifier("app.bluebubbles.proxy.cloudflare"),
      requiresRefresh: false,
      configuration: DaemonConfiguration(
        name: "cloudflared",
        executablePath: executablePath,
        arguments: options.arguments(forwardingTo: port),
        environment: options.environment
      ),
      readiness: ReadinessSignal { line in
        // A tunnel the user configured themselves NEVER prints its address — the
        // hostname lives in their config file or in the Cloudflare dashboard, and
        // cloudflared has no reason to repeat it back. So readiness there is the
        // connection registering, and the address is the one they told us about.
        if let announcedAddress {
          guard line.contains("Registered tunnel connection") else { return nil }
          return announcedAddress
        }
        guard let range = line.range(of: "https://"),
          line.contains("trycloudflare.com")
        else { return nil }
        return String(line[range.lowerBound...].prefix { !$0.isWhitespace })
          .trimmingCharacters(in: CharacterSet(charactersIn: "|\" "))
      },
      logger: logger
    )
  }

  /// zrok, which requires a reserved share and an enabled environment.
  ///
  /// The environment is enabled and the share reserved by `ZrokEnvironment` BEFORE this is
  /// called. That split is the whole of zrok's difference from the other two: they are handed
  /// a credential and start, while zrok has a setup that has already had to happen.
  public static func zrok(
    executablePath: String,
    port: Int,
    options: ZrokOptions = ZrokOptions(),
    logger: Logger = Logger(label: "bluebubbles.proxy.zrok")
  ) -> BinaryTunnel {
    BinaryTunnel(
      identifier: ServiceIdentifier("app.bluebubbles.proxy.zrok"),
      requiresRefresh: false,
      configuration: DaemonConfiguration(
        name: "zrok",
        executablePath: executablePath,
        arguments: options.arguments(forwardingTo: port),
        // Carries `ZROK_API_ENDPOINT` for a self-hosted controller, and nothing at all
        // for zrok.io. See `ZrokOptions.environment`.
        environment: options.environment
      ),
      readiness: ReadinessSignal { line in
        guard let range = line.range(of: "https://"),
          line.contains("zrok")
        else { return nil }
        return String(line[range.lowerBound...].prefix { !$0.isWhitespace })
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
      },
      logger: logger
    )
  }
}

// MARK: - Non-tunnelling providers

/// A user-supplied hostname pointing at this machine.
///
/// Not a tunnel: the user owns the DNS record and the port forwarding. It is a provider so
/// that "which address do clients use" has one answer everywhere rather than a branch.
public actor DynamicDNSProxy: ProxyProviding {

  public nonisolated let identifier = ServiceIdentifier("app.bluebubbles.proxy.dynamic-dns")
  private let configuredAddress: String
  private var address: String?

  public init(address: String) {
    self.configuredAddress = address
  }

  public var currentAddress: String? { address }

  public func connect() async throws -> String {
    let trimmed = configuredAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProxyError.notConfigured("no dynamic DNS address has been set")
    }
    // Normalised so a user who typed a bare hostname still gets a usable URL. Defaults to
    // https, since a server reachable from the internet without TLS is worse than one
    // that fails loudly here.
    let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    address = normalized
    return normalized
  }

  public func disconnect() async { address = nil }
}

/// The machine's own LAN address, for users who never expose the server publicly.
public actor LANProxy: ProxyProviding {

  public nonisolated let identifier = ServiceIdentifier("app.bluebubbles.proxy.lan-url")
  private let port: Int
  private let useTLS: Bool
  private let addressResolver: @Sendable () -> String?
  private var address: String?

  public init(
    port: Int,
    useTLS: Bool = false,
    addressResolver: @escaping @Sendable () -> String? = { SystemInfo.primaryIPv4() }
  ) {
    self.port = port
    self.useTLS = useTLS
    self.addressResolver = addressResolver
  }

  public var currentAddress: String? { address }

  public func connect() async throws -> String {
    guard let host = addressResolver() else { throw ProxyError.addressUnavailable }
    let scheme = useTLS ? "https" : "http"
    let resolved = "\(scheme)://\(host):\(port)"
    address = resolved
    return resolved
  }

  public func disconnect() async { address = nil }
}
