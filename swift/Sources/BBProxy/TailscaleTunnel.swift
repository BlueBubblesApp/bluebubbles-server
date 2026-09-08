//  TailscaleTunnel
//  Tailscale, run as this server's own userspace node and published through Serve or Funnel.
//
//  The other binary tunnels are handed a credential and print a URL. Tailscale is neither of
//  those things. It is a daemon that has to be SIGNED IN — with an auth key, or by a person
//  opening a link in a browser — and once signed in it publishes nothing until told to
//  `serve`, and `serve` over HTTPS needs a certificate feature the tailnet's owner has to
//  switch on once, and Funnel needs a second one. Every one of those steps can be pending on
//  somebody who is not at this Mac, and the daemon has to stay up while they are, because
//  restarting it invalidates the very link they were sent.
//
//  So `connect()` does as little as it can inline: it starts the daemon, and if the node is
//  already signed in it applies the serve configuration and returns the address. Anything
//  slower — signing in, waiting on a person, a feature the tailnet has yet to grant — throws
//  `ProxyError.pending` and carries on in the background, reporting each step through
//  `ProxyObserver.attentionRequired` and the address through `addressChanged` when it has
//  one. `ProxyCoordinator` treats `pending` as "not yet" rather than "failed", which keeps
//  the registry from restarting the service into a fresh daemon with a fresh, different
//  sign-in link, and keeps a slow first start from holding every service behind it.
//
//  Two choices about HOW the daemon runs are the whole reason this works without root:
//    - `--tun=userspace-networking`. On macOS `tailscaled` refuses to start as a normal user
//      unless it is told not to touch the kernel; in userspace mode it needs no TUN device,
//      no system extension and no administrator. Serve and Funnel terminate inside the
//      daemon and forward to loopback, which is exactly a userspace node's job.
//    - Its own state directory and socket. A person who already runs the Tailscale app
//      keeps it: this is a second node on their tailnet, named for this server, and the
//      two never share a socket, a key or a preference.
//
//  See `.claude/docs/performance.md`.

import BBCore
import BBServiceKit
import Foundation
import Logging

// MARK: - Errors

public enum TailscaleError: BBError, Equatable {
  case executableMissing(path: String)
  case launchFailed(reason: String)
  /// The command ran and failed. `output` is Tailscale's own words.
  case commandFailed(command: String, output: String)
  case timedOut(command: String)
  /// The daemon started but its socket never answered.
  case daemonUnresponsive
  /// Tailscale rejected the auth key.
  case invalidAuthKey(output: String)
  /// The node is signed in but has no MagicDNS name, so there is no address to publish.
  case noMagicDNSName
  /// Funnel only serves a few ports, and this is not one of them.
  case funnelPortNotAllowed(port: Int)
  /// Serve or Funnel refused the configuration for a reason other than a missing feature.
  case serveRefused(output: String)

  public var message: String {
    switch self {
    case .executableMissing(let path):
      "the Tailscale program is missing at \(path)"
    case .launchFailed(let reason):
      reason
    case .commandFailed(_, let output):
      output.isEmpty ? "Tailscale failed without printing anything" : output
    case .timedOut(let command):
      "tailscale \(command) did not finish in time"
    case .daemonUnresponsive:
      "tailscaled started but never answered on its socket"
    case .invalidAuthKey(let output):
      output.isEmpty
        ? "Tailscale rejected the auth key"
        : "Tailscale rejected the auth key: \(output)"
    case .noMagicDNSName:
      "this Mac has no MagicDNS name on the tailnet, so there is no address to publish; "
        + "MagicDNS must be enabled in the tailnet's DNS settings"
    case .funnelPortNotAllowed(let port):
      "Funnel does not serve port \(port); it allows "
        + TailscaleOptions.funnelPorts.map(String.init).joined(separator: ", ")
    case .serveRefused(let output):
      output.isEmpty ? "Tailscale refused the serve configuration" : output
    }
  }
}

// MARK: - Options

/// Everything about the Tailscale node that is not the port it forwards to.
public struct TailscaleOptions: Sendable, Equatable {

  /// Who can reach the published address.
  public enum Exposure: String, Sendable, Equatable, CaseIterable {
    /// Devices signed in to the same tailnet — `tailscale serve`.
    case tailnet
    /// The internet, through Tailscale's relays — `tailscale funnel`.
    case funnel
  }

  /// The machine name on the tailnet, which is the first label of the published address.
  public var hostname: String
  public var exposure: Exposure
  /// The HTTPS port on the tailnet address. Funnel permits only `funnelPorts`.
  public var httpsPort: Int
  /// A pre-authentication key, or empty to sign in through a browser link.
  public var authKey: String
  /// A control server other than Tailscale's, for Headscale users. Empty means Tailscale's.
  public var controlURL: String
  /// Whether `tailscaled` may upload its logs to Tailscale. Off passes
  /// `--no-logs-no-support`, which is the privacy-preserving default for a node whose only
  /// job is to carry someone's messages.
  public var sendLogs: Bool
  public var verboseLogging: Bool
  /// Whether THIS server terminates TLS, from `use_custom_certificate`. Decides the scheme
  /// serve proxies to, and whether it is told not to verify the certificate. Same fact
  /// `CloudflareOptions` carries.
  public var originUsesTLS: Bool
  /// Where `tailscaled` keeps its node key, preferences and certificates.
  public var stateDirectory: String
  /// The control socket both the daemon and the CLI use. See `socketPath(preferring:)`.
  public var socketPath: String

  public static let defaultHostname = "bluebubbles"
  /// The ports Funnel will serve on. `ipn.CheckFunnelPort` in Tailscale refuses others.
  public static let funnelPorts = [443, 8443, 10000]
  /// `sun_path` on macOS: 104 bytes including the terminator.
  public static let maximumSocketPathLength = 103

  public init(
    hostname: String = TailscaleOptions.defaultHostname,
    exposure: Exposure = .tailnet,
    httpsPort: Int = 443,
    authKey: String = "",
    controlURL: String = "",
    sendLogs: Bool = false,
    verboseLogging: Bool = false,
    originUsesTLS: Bool = false,
    stateDirectory: String,
    socketPath: String
  ) {
    self.hostname = hostname
    self.exposure = exposure
    self.httpsPort = httpsPort
    self.authKey = authKey
    self.controlURL = controlURL
    self.sendLogs = sendLogs
    self.verboseLogging = verboseLogging
    self.originUsesTLS = originUsesTLS
    self.stateDirectory = stateDirectory
    self.socketPath = socketPath
  }

  /// Whether Funnel would refuse this port. Checked before anything is spawned, because
  /// the select on the settings page is not the only way a value gets into a setting.
  public var isFunnelPortAllowed: Bool {
    exposure != .funnel || Self.funnelPorts.contains(httpsPort)
  }

  /// Where the daemon's socket goes: beside its state when the path fits, and in the
  /// per-user temporary directory when it does not.
  ///
  /// A Unix socket path is capped at 104 bytes on macOS, and Application Support plus a
  /// long user name can exceed it. The temporary directory is the fallback rather than
  /// the rule because macOS purges what sits unused there for a few days — harmless for a
  /// socket the daemon recreates on every start, but not somewhere to keep anything on
  /// purpose. Two instances sharing one path is not a concern either way: they would also
  /// share the state directory, and the single-instance lock keeps a second server from
  /// starting at all.
  public static func socketPath(preferring directory: String, fallback: String) -> String {
    let preferred = directory + "/tailscaled.sock"
    if preferred.utf8.count <= maximumSocketPathLength { return preferred }
    return fallback + (fallback.hasSuffix("/") ? "" : "/") + "bluebubbles-tailscaled.sock"
  }

  /// A machine name Tailscale will accept: lowercase letters, digits and hyphens, at most
  /// 63 characters, and never empty.
  ///
  /// Sanitised rather than refused because the field is free text and "BlueBubbles Server"
  /// is a perfectly reasonable thing to have typed.
  public static func sanitisedHostname(_ raw: String) -> String {
    var name = ""
    for character in raw.lowercased() {
      if character.isASCII, character.isLetter || character.isNumber {
        name.append(character)
      } else if !name.isEmpty, name.last != "-" {
        name.append("-")
      }
    }
    name = String(name.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return name.isEmpty ? defaultHostname : name
  }

  /// What serve proxies to.
  ///
  /// `https+insecure` is Tailscale's own spelling for an origin whose certificate it should
  /// not verify — the same reason zrok gets `--insecure`: the certificate on loopback is
  /// self-signed or privately imported and chains to nothing.
  public func target(port: Int) -> String {
    "\(originUsesTLS ? "https+insecure" : "http")://127.0.0.1:\(port)"
  }

  /// The `tailscaled` command line, minus the executable.
  public var daemonArguments: [String] {
    var arguments = [
      "--tun=userspace-networking",
      "--socket=\(socketPath)",
      "--statedir=\(stateDirectory)",
      // A random UDP port: a second Tailscale on this Mac already holds the default one.
      "--port=0",
    ]
    if !sendLogs { arguments.append("--no-logs-no-support") }
    if verboseLogging { arguments.append("--verbose=1") }
    return arguments
  }

  /// The `tailscale up` command line, minus the executable and the socket.
  ///
  /// `--reset` makes these flags the whole of the node's preferences on every start, so a
  /// change here applies rather than being refused as "you did not mention the flags you
  /// set last time". `--accept-dns=false` keeps a userspace node from trying to rewrite
  /// this Mac's resolvers, and `--accept-routes=false` from routing anything at all: this
  /// node exists to be reached, not to reach.
  ///
  /// - Parameter authKeyFile: a file holding the key, passed as `file:` so the key itself
  ///   never appears in the process list.
  public func upArguments(authKeyFile: String?, timeout: Duration) -> [String] {
    var arguments = [
      "up", "--reset", "--json",
      "--hostname=\(hostname)",
      "--accept-dns=false",
      "--accept-routes=false",
      "--timeout=\(Int(timeout.components.seconds))s",
    ]
    let control = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !control.isEmpty { arguments.append("--login-server=\(control)") }
    if let authKeyFile { arguments.append("--auth-key=file:\(authKeyFile)") }
    return arguments
  }

  /// The `tailscale serve` or `tailscale funnel` command line, minus the executable and the
  /// socket. `--bg` persists the configuration in the daemon rather than holding a
  /// foreground process, which is the shape everything else here assumes.
  public func serveArguments(forwardingTo port: Int) -> [String] {
    [
      exposure == .funnel ? "funnel" : "serve",
      "--bg", "--https=\(httpsPort)", target(port: port),
    ]
  }

  /// The address clients are handed for a node with this MagicDNS name.
  public func publishedAddress(dnsName: String) -> String {
    let host = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
    return httpsPort == 443 ? "https://\(host)" : "https://\(host):\(httpsPort)"
  }
}

// MARK: - What the daemon says about itself

/// The parts of `tailscale status --json` this server reads.
///
/// Decoded by hand from a document whose shape Tailscale marks "subject to change", for the
/// same reason `ZrokEnvironment` decodes zrok's overview by hand: a `Codable` model of the
/// whole thing would fail on every key they add, and five values are all that matter here.
public struct TailscaleStatus: Sendable, Equatable {
  /// `NeedsLogin`, `NeedsMachineAuth`, `Stopped`, `Starting`, `Running`, or `NoState`.
  public let backendState: String
  /// The browser link that signs this node in, while `NeedsLogin`.
  public let authURL: URL?
  /// This node's MagicDNS name, without the trailing dot Tailscale reports it with.
  public let dnsName: String?
  /// The node capabilities the tailnet grants — `https` and `funnel` are the two consulted.
  public let capabilities: Set<String>

  public init(
    backendState: String, authURL: URL? = nil, dnsName: String? = nil,
    capabilities: Set<String> = []
  ) {
    self.backendState = backendState
    self.authURL = authURL
    self.dnsName = dnsName
    self.capabilities = capabilities
  }

  public var isRunning: Bool { backendState == "Running" }
  public var needsLogin: Bool { backendState == "NeedsLogin" }
  public var needsMachineAuth: Bool { backendState == "NeedsMachineAuth" }
  /// Tailscale's `nodecap.HTTPS` and `nodecap.Funnel`, as they appear in `Self.CapMap`.
  public var hasHTTPS: Bool { capabilities.contains("https") }
  public var hasFunnel: Bool { capabilities.contains("funnel") }

  public static func parse(_ text: String) -> TailscaleStatus? {
    // Found rather than assumed to start at byte zero, in case a version prints a warning
    // line first.
    guard let start = text.firstIndex(of: "{"),
      let data = String(text[start...]).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let state = object["BackendState"] as? String
    else { return nil }

    let selfNode = object["Self"] as? [String: Any] ?? [:]
    let dnsName = (selfNode["DNSName"] as? String).flatMap { name -> String? in
      let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
      return trimmed.isEmpty ? nil : trimmed
    }
    let capabilities = Set((selfNode["CapMap"] as? [String: Any])?.keys.map { $0 } ?? [])
    let authURL = (object["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }

    return TailscaleStatus(
      backendState: state, authURL: authURL, dnsName: dnsName, capabilities: capabilities
    )
  }
}

// MARK: - The command line

/// The `tailscale` CLI, pointed at this server's own daemon.
public struct TailscaleCLI: Sendable {

  /// What one command said and whether it succeeded, for the callers that tolerate a
  /// failure and then need to look at it.
  public struct CommandResult: Sendable, Equatable {
    public let output: String
    public let succeeded: Bool
    /// Killed by the backstop timeout, with its output lost.
    public let timedOut: Bool
  }

  /// The `tailscale` executable — the CLI, not the daemon.
  public let executablePath: String
  public let socketPath: String
  private let logger: Logger

  public init(executablePath: String, socketPath: String, logger: Logger) {
    self.executablePath = executablePath
    self.socketPath = socketPath
    self.logger = logger
  }

  /// `tailscale status --json`, decoded.
  public func status() async throws -> TailscaleStatus {
    // `status` exits non-zero while the node is not running, and that is the answer being
    // asked for — so its exit code is ignored and only its document is read.
    let result = try await run(["status", "--json"], describedAs: "status", tolerateFailure: true)
    guard let status = TailscaleStatus.parse(result.output) else {
      throw TailscaleError.commandFailed(command: "status", output: result.output)
    }
    return status
  }

  /// Waits for a freshly started daemon to answer on its socket.
  public func waitUntilResponsive(timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if (try? await status()) != nil { return }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw TailscaleError.daemonUnresponsive
  }

  /// `tailscale up`, and the node's state afterwards.
  ///
  /// Idempotent on a signed-in node, where it only applies the preferences. Without a key
  /// on a signed-out one, it prints the sign-in link and waits for someone to use it; the
  /// timeout ends the wait, and the link stays valid in the daemon — `status` reports it —
  /// which is where the caller reads it from. With a key, it returns once the node is
  /// running or the key is refused.
  ///
  /// - Parameter authKey: used only when the node is not already signed in.
  public func up(options: TailscaleOptions, authKey: String?) async throws -> TailscaleStatus {
    let key = authKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let timeout: Duration = key.isEmpty ? .seconds(15) : .seconds(90)

    var keyFile: String?
    if !key.isEmpty {
      keyFile = try writeAuthKey(key, in: options.stateDirectory)
    }
    defer {
      if let keyFile { try? FileManager.default.removeItem(atPath: keyFile) }
    }

    let result = try await run(
      options.upArguments(authKeyFile: keyFile, timeout: timeout),
      describedAs: "up",
      // Its own `--timeout` ends it; this is the backstop for a CLI that ignores it.
      timeout: timeout + .seconds(15),
      tolerateFailure: true,
      tolerateTimeout: true
    )

    let afterwards = try await status()
    if !key.isEmpty, !afterwards.isRunning, !afterwards.needsMachineAuth {
      // A key that was refused leaves the node exactly where it was, with no link to
      // offer instead. `up` said why on the way out — THIS command's output, not the
      // status document read a moment later.
      throw TailscaleError.invalidAuthKey(output: Self.lastLine(of: result.output))
    }
    return afterwards
  }

  /// What applying the serve configuration produced.
  public enum ServeOutcome: Sendable, Equatable {
    case applied
    /// A tailnet feature is not switched on. The link, if Tailscale printed one, leads to
    /// the page that switches it on.
    case featureMissing(TailscaleStatus, link: URL?)
  }

  /// Replaces the node's serve configuration with this server's.
  ///
  /// `reset` first, so switching between tailnet-only and Funnel, or changing the port,
  /// leaves nothing of the previous configuration behind. This daemon is this server's
  /// alone, so there is nothing of anyone else's to preserve.
  ///
  /// The serve command is not trusted to say whether it applied anything. When HTTPS
  /// certificates or Funnel are not enabled for the tailnet it prints the enabling link and
  /// then either exits SUCCESSFULLY without applying, or blocks until somebody enables the
  /// feature — which is why the capabilities are read first and the command runs under a
  /// timeout.
  public func configureServe(
    options: TailscaleOptions, forwardingTo port: Int
  ) async throws -> ServeOutcome {
    let command = options.exposure == .funnel ? "funnel" : "serve"
    let arguments = options.serveArguments(forwardingTo: port)

    // The capabilities first, because the command cannot be relied on to say. With one
    // missing it still runs — briefly, tolerating being killed — since in its non-blocking
    // form it prints the node-specific enabling link, and that link is worth more to the
    // person than the generic page used when it says nothing.
    let before = try await status()
    if Self.missingFeature(for: options, in: before) {
      let attempt = try await run(
        arguments, describedAs: command, timeout: .seconds(10),
        tolerateFailure: true, tolerateTimeout: true
      )
      let after = try await status()
      if Self.missingFeature(for: options, in: after) {
        return .featureMissing(after, link: Self.firstLink(in: attempt.output))
      }
    }

    _ = try? await run(["serve", "reset"], describedAs: "serve reset", tolerateFailure: true)
    let result = try await run(
      arguments, describedAs: command, timeout: .seconds(30), tolerateFailure: true
    )
    guard result.succeeded else {
      throw TailscaleError.serveRefused(output: result.output)
    }
    return .applied
  }

  /// Whether the tailnet has yet to grant something this configuration needs.
  static func missingFeature(for options: TailscaleOptions, in status: TailscaleStatus) -> Bool {
    !status.hasHTTPS || (options.exposure == .funnel && !status.hasFunnel)
  }

  /// The first `https://` link in a command's output — the enabling page Tailscale prints.
  public static func firstLink(in output: String) -> URL? {
    for word in output.split(whereSeparator: \.isWhitespace) {
      guard word.hasPrefix("https://") else { continue }
      let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;\"'()"))
      if let url = URL(string: trimmed) { return url }
    }
    return nil
  }

  /// The last non-empty line, which is where a CLI puts its reason for failing.
  static func lastLine(of output: String) -> String {
    output.split(separator: "\n").last.map {
      $0.trimmingCharacters(in: .whitespaces)
    } ?? ""
  }

  // MARK: Internals

  /// Writes the auth key where only this user can read it, for `--auth-key=file:`.
  private func writeAuthKey(_ key: String, in directory: String) throws -> String {
    let path = directory + "/authkey-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    guard
      FileManager.default.createFile(
        atPath: path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]
      )
    else {
      throw TailscaleError.launchFailed(reason: "the auth key could not be written to disk")
    }
    return path
  }

  /// Runs one command against this daemon's socket.
  private func run(
    _ arguments: [String],
    describedAs command: String,
    timeout: Duration = .seconds(30),
    tolerateFailure: Bool = false,
    tolerateTimeout: Bool = false
  ) async throws -> CommandResult {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw TailscaleError.executableMissing(path: executablePath)
    }
    let result: Subprocess.Result
    do {
      result = try await Subprocess.run(
        executablePath, ["--socket=\(socketPath)"] + arguments,
        output: .merged,
        timeout: timeout
      )
    } catch let failure as Subprocess.Failure {
      switch failure {
      case .timedOut:
        if tolerateTimeout {
          return CommandResult(output: "", succeeded: false, timedOut: true)
        }
        throw TailscaleError.timedOut(command: command)
      case .launchFailed(_, let reason):
        throw TailscaleError.launchFailed(reason: reason)
      }
    }
    let output = result.trimmedText
    logger.trace(
      "tailscale command finished",
      metadata: [
        "command": .string(command),
        "status": .stringConvertible(result.status),
      ])
    guard result.succeeded || tolerateFailure else {
      throw TailscaleError.commandFailed(command: command, output: output)
    }
    return CommandResult(output: output, succeeded: result.succeeded, timedOut: false)
  }
}

// MARK: - What a person has to do

/// A step only the tailnet's owner can take, and what this server knows about it.
public enum TailscaleAttention: Sendable, Equatable {
  /// Open this link and sign in; the daemon is waiting on it.
  case signInRequired(URL)
  /// The tailnet approves new devices by hand, and this one is queued.
  case deviceApprovalRequired
  /// The auth key on the settings page was refused, so the browser link is on offer.
  case authKeyRejected(detail: String)
  /// HTTPS certificates are switched off for the tailnet. The link is the page that
  /// switches them on, when Tailscale printed one.
  case httpsNotEnabled(link: URL?)
  /// Funnel is not granted to this node. Same shape.
  case funnelNotEnabled(link: URL?)

  /// The Tailscale admin pages, for the steps where Tailscale printed no link of its own —
  /// Tailscale's own short links, from the messages its CLI prints for the same conditions.
  private enum Pages {
    static let machines = URL(string: "https://login.tailscale.com/admin/machines")
    static let keys = URL(string: "https://login.tailscale.com/admin/settings/keys")
    static let https = URL(string: "https://tailscale.com/s/https")
    static let funnel = URL(string: "https://tailscale.com/s/no-funnel")
  }

  /// The notification asking for it.
  public var notice: ProxyAttention {
    switch self {
    case .signInRequired(let url):
      ProxyAttention(
        title: "Sign in to Tailscale to finish connecting",
        body: "Open the link and sign this Mac in to your Tailscale account. The connection "
          + "starts on its own once you have. To skip this step in future, paste an auth "
          + "key from the Tailscale admin console on the Tailscale page.",
        link: url,
        // A sign-in link belongs to one daemon; a daemon that came back after a crash has
        // a different one, and a person should see the current one.
        key: "sign-in.\(url.lastPathComponent)",
        summary: "waiting for you to sign in to Tailscale"
      )
    case .deviceApprovalRequired:
      ProxyAttention(
        title: "Approve this Mac in the Tailscale admin console",
        body: "Your tailnet approves new devices by hand, and this one is waiting. Approve "
          + "it under Machines in the admin console and the connection starts on its own.",
        link: Pages.machines,
        key: "device-approval",
        summary: "waiting for this Mac to be approved on your tailnet"
      )
    case .authKeyRejected(let detail):
      ProxyAttention(
        title: "Tailscale rejected the auth key",
        body: "The auth key on the Tailscale page was refused"
          + (detail.isEmpty ? ". " : ": \(detail). ")
          + "Generate a new one in the admin console and paste it on the Tailscale page, "
          + "or sign in through the link in the next notification instead.",
        link: Pages.keys,
        key: "auth-key-rejected",
        summary: "the Tailscale auth key was rejected"
      )
    case .httpsNotEnabled(let link):
      ProxyAttention(
        title: "Enable HTTPS certificates for your tailnet",
        body: "Tailscale serves this server over HTTPS, which needs certificates enabled "
          + "once for your whole tailnet. Open the link, turn on HTTPS Certificates, and "
          + "the connection starts on its own.",
        link: link ?? Pages.https,
        key: "https.\(link?.lastPathComponent ?? "")",
        summary: "waiting for HTTPS certificates to be enabled on your tailnet"
      )
    case .funnelNotEnabled(let link):
      ProxyAttention(
        title: "Enable Tailscale Funnel for this Mac",
        body: "Publishing to the internet needs Funnel enabled for this Mac in your "
          + "tailnet's access policy. Open the link and allow it, and the connection starts "
          + "on its own — or choose \"Only devices on my tailnet\" on the Tailscale page "
          + "instead.",
        link: link ?? Pages.funnel,
        key: "funnel.\(link?.lastPathComponent ?? "")",
        summary: "waiting for Funnel to be enabled for this Mac"
      )
    }
  }
}

// MARK: - The provider

/// A Tailscale node, run and published by this server.
public actor TailscaleTunnel: ProxyProviding {

  public nonisolated let identifier = ServiceIdentifier("app.bluebubbles.proxy.tailscale")

  private let daemon: DaemonProcess
  private let cli: TailscaleCLI
  private let options: TailscaleOptions
  private let port: Int
  private let logger: Logger
  private let restartDelay: Duration

  private var address: String?
  private var observer: ProxyObserver?
  /// The background work: bringing the node up, waiting on a person, or watching a running
  /// node. One at a time, identified by generation — see `startBackground`.
  private var background: Task<Void, Never>?
  private var backgroundGeneration = 0
  /// What the person was last told, so they are told once rather than every poll.
  private var lastAttention: TailscaleAttention?
  /// Whether the preferences in `options` have been applied to a signed-in node. Once per
  /// provider: a settings change makes a new provider, so a change is applied exactly once
  /// rather than on every poll.
  private var hasAppliedPreferences = false
  /// Whether the configured auth key has been refused. Once it has, sign-in falls back to
  /// the browser link rather than presenting the same key every poll.
  private var authKeyWasRejected = false
  private var isDisconnecting = false

  /// How often to ask the daemon whether the pending step has been taken.
  static let waitingPollInterval: Duration = .seconds(5)
  /// How often to check that a running node is still signed in and still named the same.
  static let monitorInterval: Duration = .seconds(120)

  public init(
    daemonExecutablePath: String,
    cliExecutablePath: String,
    port: Int,
    options: TailscaleOptions,
    logger: Logger = Logger(label: "bluebubbles.proxy.tailscale")
  ) {
    let configuration = DaemonConfiguration(
      name: "tailscaled",
      executablePath: daemonExecutablePath,
      arguments: options.daemonArguments
    )
    self.daemon = DaemonProcess(configuration: configuration, logger: logger)
    self.cli = TailscaleCLI(
      executablePath: cliExecutablePath, socketPath: options.socketPath, logger: logger
    )
    self.options = options
    self.port = port
    self.logger = logger
    self.restartDelay = configuration.restartDelay
  }

  public var currentAddress: String? { address }

  public func observe(_ observer: ProxyObserver) async {
    self.observer = observer
  }

  public func connect() async throws -> String {
    guard options.isFunnelPortAllowed else {
      throw ProxyError.tunnelFailed(
        reason: TailscaleError.funnelPortNotAllowed(port: options.httpsPort).message)
    }

    isDisconnecting = false
    lastAttention = nil
    hasAppliedPreferences = false
    authKeyWasRejected = false
    await daemon.onTermination { [weak self] code in
      await self?.handleUnexpectedExit(code: code)
    }

    do {
      try await daemon.start()
      try await cli.waitUntilResponsive(timeout: .seconds(30))
    } catch let error as DaemonError {
      throw ProxyError.tunnelFailed(reason: BinaryTunnel.describe(error))
    } catch let error as TailscaleError {
      await daemon.stop()
      throw ProxyError.tunnelFailed(reason: error.message)
    }

    // Inline only what is quick: a node that is already signed in gets its serve
    // configuration applied and its address returned. Signing in, or anything a person
    // has to do, moves to the background — the registry starts services one after
    // another, and a first start that waits a minute for a browser holds every service
    // behind it.
    let status = try await quickStatus()
    if status.isRunning, !Self.needsPerson(status) {
      do {
        switch try await establish() {
        case .ready(let url):
          address = url
          startBackground { tunnel in await tunnel.monitorLoop() }
          return url
        case .waiting(let attention):
          startBackground { tunnel in await tunnel.waitLoop(restartingDaemon: false) }
          throw ProxyError.pending(reason: attention.summary)
        }
      } catch let error as TailscaleError {
        await daemon.stop()
        throw ProxyError.tunnelFailed(reason: error.message)
      }
    }

    startBackground { tunnel in await tunnel.waitLoop(restartingDaemon: false) }
    throw ProxyError.pending(
      reason: status.isRunning ? "applying the Tailscale configuration" : "signing in to Tailscale"
    )
  }

  public func disconnect() async {
    isDisconnecting = true
    cancelBackground()
    await daemon.stop()
    address = nil
    lastAttention = nil
  }

  // MARK: - Bringing the node up

  private enum Outcome {
    case ready(String)
    case waiting(TailscaleAttention)
  }

  /// The daemon's state, or a failure converted for `connect()`.
  private func quickStatus() async throws -> TailscaleStatus {
    do {
      return try await cli.status()
    } catch let error as TailscaleError {
      await daemon.stop()
      throw ProxyError.tunnelFailed(reason: error.message)
    }
  }

  /// Whether a status is one only a person can move on from.
  private static func needsPerson(_ status: TailscaleStatus) -> Bool {
    status.needsMachineAuth || (status.needsLogin && status.authURL != nil)
  }

  /// One pass at getting from "daemon running" to "address published", stopping at the
  /// first step that needs a person.
  private func establish() async throws -> Outcome {
    var status = try await cli.status()

    if status.needsMachineAuth {
      return .waiting(await report(.deviceApprovalRequired))
    }

    // `up` is run when the node is not signed in and has no link to offer yet, and once on
    // a signed-in node to apply the preferences — the machine name and control server —
    // so a change to them takes effect after the restart that follows a settings change.
    // NOT on every poll of a node that already has its link: that would present the same
    // link, or the same refused key, every five seconds.
    let signedOut = !status.isRunning
    let needsUp = signedOut ? status.authURL == nil : !hasAppliedPreferences
    if needsUp {
      let key: String? = signedOut && !authKeyWasRejected ? options.authKey : nil
      do {
        status = try await cli.up(options: options, authKey: key)
      } catch TailscaleError.invalidAuthKey(let output) {
        // Reported once, then the browser link is offered instead. The key stays as it
        // is on the settings page; a new provider is made when it changes.
        authKeyWasRejected = true
        _ = await report(.authKeyRejected(detail: output))
        status = try await cli.up(options: options, authKey: nil)
      }
      if status.isRunning { hasAppliedPreferences = true }
    }

    if status.needsMachineAuth {
      return .waiting(await report(.deviceApprovalRequired))
    }
    if !status.isRunning {
      guard let link = status.authURL else {
        throw TailscaleError.commandFailed(
          command: "up",
          output: "the node is \(status.backendState) and Tailscale offered no sign-in link"
        )
      }
      return .waiting(await report(.signInRequired(link)))
    }

    switch try await cli.configureServe(options: options, forwardingTo: port) {
    case .applied:
      break
    case .featureMissing(let after, let link):
      if !after.hasHTTPS {
        return .waiting(await report(.httpsNotEnabled(link: link)))
      }
      return .waiting(await report(.funnelNotEnabled(link: link)))
    }

    guard let dnsName = status.dnsName else { throw TailscaleError.noMagicDNSName }
    lastAttention = nil
    return .ready(options.publishedAddress(dnsName: dnsName))
  }

  /// Tells the person once per distinct step.
  private func report(_ attention: TailscaleAttention) async -> TailscaleAttention {
    if lastAttention != attention {
      lastAttention = attention
      await observer?.attentionRequired(attention.notice)
    }
    return attention
  }

  // MARK: - Background work

  /// Starts the one background task, replacing whatever was running.
  ///
  /// Generations rather than a bare handle, because a cancelled task's clean-up runs
  /// LATER, on its own schedule: a `defer { background = nil }` in a task that was just
  /// replaced would clear the replacement's handle, leaving it running untracked where
  /// `disconnect()` could not reach it and a second crash would start a third loop beside
  /// it. A task only clears the handle if the generation is still its own.
  private func startBackground(_ work: @escaping @Sendable (TailscaleTunnel) async -> Void) {
    cancelBackground()
    backgroundGeneration += 1
    let generation = backgroundGeneration
    background = Task { [weak self] in
      guard let self else { return }
      await work(self)
      await self.finishBackground(generation: generation)
    }
  }

  private func cancelBackground() {
    background?.cancel()
    background = nil
  }

  private func finishBackground(generation: Int) {
    if generation == backgroundGeneration { background = nil }
  }

  /// Brings the daemon back if it died, then polls until the address can be published.
  private func waitLoop(restartingDaemon: Bool) async {
    if restartingDaemon {
      guard await restartDaemon() else { return }
    }

    var consecutiveFailures = 0
    while !Task.isCancelled, !isDisconnecting {
      do {
        switch try await establish() {
        case .ready(let url):
          address = url
          logger.info("Tailscale is publishing this server")
          await observer?.addressChanged(url)
          if !Task.isCancelled { await monitorLoop() }
          return
        case .waiting:
          consecutiveFailures = 0
        }
      } catch {
        consecutiveFailures += 1
        logger.warning(
          "Tailscale setup did not complete yet",
          metadata: ["reason": .string(String(describing: error))])
      }
      // Slower after repeated errors, so a daemon that keeps refusing a command does not
      // fill the log twelve times a minute.
      let interval = consecutiveFailures > 3 ? Self.monitorInterval : Self.waitingPollInterval
      try? await Task.sleep(for: interval)
    }
  }

  /// Restarts a dead daemon within the budget. False when the budget is spent, or the
  /// task was cancelled meanwhile.
  ///
  /// The same budget `BinaryTunnel` spends: a daemon that dies once a day is retried
  /// forever, one that cannot start at all gives up after ten tries. A daemon that starts
  /// and never answers on its socket is STOPPED before the next try, so each slot spent is
  /// a real restart rather than `start()` returning early on a process that still exists.
  private func restartDaemon() async -> Bool {
    while !Task.isCancelled, !isDisconnecting {
      guard await daemon.shouldRestart() else {
        let reason =
          "The Tailscale daemon exited repeatedly, or kept starting without answering, and "
          + "will not be restarted again. Check the server log for what it printed."
        logger.error("Giving up on the tunnel", metadata: ["kind": .string("tailscale")])
        await observer?.failed(reason)
        return false
      }
      try? await Task.sleep(for: restartDelay)
      if Task.isCancelled || isDisconnecting { return false }
      do {
        try await daemon.start()
        try await cli.waitUntilResponsive(timeout: .seconds(30))
        return true
      } catch {
        // A daemon that launched and then died reaches `handleUnexpectedExit`, which
        // replaces this task; one that would not launch, or launched and never answered,
        // is retried here against the same budget.
        logger.warning(
          "The Tailscale daemon did not come back yet",
          metadata: ["reason": .string(String(describing: error))])
        await daemon.stop()
      }
    }
    return false
  }

  /// Watches a running node for the two things that silently take it down: a node key that
  /// expired (the state drops to `NeedsLogin`), and a rename on the tailnet.
  private func monitorLoop() async {
    while !Task.isCancelled, !isDisconnecting {
      try? await Task.sleep(for: Self.monitorInterval)
      if Task.isCancelled || isDisconnecting { return }
      guard let status = try? await cli.status() else { continue }

      if !status.isRunning {
        logger.warning(
          "The Tailscale node is no longer running",
          metadata: ["state": .string(status.backendState)])
        address = nil
        hasAppliedPreferences = false
        startBackground { tunnel in await tunnel.waitLoop(restartingDaemon: false) }
        return
      }
      if let dnsName = status.dnsName {
        let expected = options.publishedAddress(dnsName: dnsName)
        if expected != address {
          logger.info("This Mac's Tailscale name changed; republishing")
          address = expected
          await observer?.addressChanged(expected)
        }
      }
    }
  }

  /// The daemon died without being asked to.
  private func handleUnexpectedExit(code: Int32) async {
    guard !isDisconnecting else { return }
    logger.warning(
      "The Tailscale daemon exited on its own",
      metadata: ["code": .stringConvertible(code)])
    address = nil
    hasAppliedPreferences = false
    startBackground { tunnel in await tunnel.waitLoop(restartingDaemon: true) }
  }
}

extension TailscaleError {
  public var code: String {
    switch self {
    case .executableMissing: "tailscale.executable_missing"
    case .launchFailed: "tailscale.launch_failed"
    case .commandFailed: "tailscale.command_failed"
    case .timedOut: "tailscale.timed_out"
    case .daemonUnresponsive: "tailscale.daemon_unresponsive"
    case .invalidAuthKey: "tailscale.invalid_auth_key"
    case .noMagicDNSName: "tailscale.no_magicdns_name"
    case .funnelPortNotAllowed: "tailscale.funnel_port_not_allowed"
    case .serveRefused: "tailscale.serve_refused"
    }
  }

  public var domain: String { "Proxy" }

  /// Every case is folded into `ProxyError.tunnelFailed` by the provider, whose message
  /// is what a person reads; these are what a diagnostic report carries for one caught
  /// on its own.
  public var title: String {
    switch self {
    case .invalidAuthKey: "Tailscale rejected the auth key"
    case .noMagicDNSName: "This Mac has no MagicDNS name"
    case .funnelPortNotAllowed: "Funnel does not serve that port"
    default: "Tailscale reported a problem"
    }
  }

  /// `message` already carries Tailscale's own words, which are the only useful explanation.
  public var body: String { message }
}
