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
//  So this provider has a state the others do not: WAITING. `connect()` brings the daemon up
//  and, if a person has to do something first, says what through `onAttention`, throws
//  `ProxyError.awaitingUser`, and keeps going in the background — polling the daemon until
//  the step is done, then finishing the setup and publishing the address through the
//  observer like a tunnel that came back. `ProxyCoordinator` treats that error as "not yet"
//  rather than "failed", which is what keeps the registry from restarting the service into a
//  fresh daemon with a fresh, different sign-in link every few minutes.
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
  case funnelPortNotAllowed(port: Int, output: String)
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
    case .funnelPortNotAllowed(let port, let output):
      output.isEmpty ? "Funnel does not allow port \(port)" : output
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
  /// The control socket both the daemon and the CLI use. Short on purpose: a Unix socket
  /// path is capped at 104 bytes on macOS, and a path under Application Support with a long
  /// user name would not fit.
  public var socketPath: String

  public static let defaultHostname = "bluebubbles"
  /// The ports Funnel will serve on. `ipn.CheckFunnelPort` in Tailscale refuses others.
  public static let funnelPorts = [443, 8443, 10000]

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
    let output = try await run(
      ["status", "--json"], describedAs: "status", tolerateFailure: true
    )
    guard let status = TailscaleStatus.parse(output) else {
      throw TailscaleError.commandFailed(command: "status", output: output)
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
  /// Without a key, `up` prints the sign-in link and waits for someone to use it; the
  /// timeout ends the wait, and the link stays valid in the daemon — `status` reports it —
  /// which is where the caller reads it from. With a key, `up` returns once the node is
  /// running or the key is refused.
  public func up(options: TailscaleOptions) async throws -> TailscaleStatus {
    let key = options.authKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeout: Duration = key.isEmpty ? .seconds(15) : .seconds(90)

    var keyFile: String?
    if !key.isEmpty {
      keyFile = try writeAuthKey(key, in: options.stateDirectory)
    }
    defer {
      if let keyFile { try? FileManager.default.removeItem(atPath: keyFile) }
    }

    do {
      _ = try await run(
        options.upArguments(authKeyFile: keyFile, timeout: timeout),
        describedAs: "up",
        // Its own `--timeout` ends it; this is the backstop for a CLI that ignores it.
        timeout: timeout + .seconds(15),
        tolerateFailure: true
      )
    } catch let error as TailscaleError {
      guard case .timedOut = error else { throw error }
      // Killed by the backstop. The daemon has still been asked to come up, so the state
      // read below is what matters.
    }

    let afterwards = try await status()
    if !key.isEmpty, !afterwards.isRunning, !afterwards.needsMachineAuth {
      // A key that was refused leaves the node exactly where it was, with no link to
      // offer instead. `up` said why on the way out.
      throw TailscaleError.invalidAuthKey(output: lastOutput)
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
  /// feature — which is why it runs under a timeout and why the node's capabilities are
  /// read back afterwards to decide.
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
      let output = try await run(
        arguments, describedAs: command, timeout: .seconds(10),
        tolerateFailure: true, tolerateTimeout: true
      )
      let after = try await status()
      if Self.missingFeature(for: options, in: after) {
        return .featureMissing(after, link: Self.firstLink(in: output))
      }
    }

    _ = try? await run(["serve", "reset"], describedAs: "serve reset", tolerateFailure: true)
    let output = try await run(
      arguments, describedAs: command, timeout: .seconds(30), tolerateFailure: true
    )
    if output.lowercased().contains("not allowed for funnel") {
      throw TailscaleError.funnelPortNotAllowed(port: options.httpsPort, output: output)
    }
    guard lastExitSucceeded else {
      throw TailscaleError.serveRefused(output: output)
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

  // MARK: Internals

  /// The exit status and output of the most recent command, for the callers that need to
  /// look at a failure after tolerating it. Boxed because this is a value type.
  private let lastRun = LastRun()

  private var lastOutput: String { lastRun.output }
  private var lastExitSucceeded: Bool { lastRun.succeeded }

  private final class LastRun: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutput = ""
    private var storedSuccess = true
    var output: String {
      lock.lock()
      defer { lock.unlock() }
      return storedOutput
    }
    var succeeded: Bool {
      lock.lock()
      defer { lock.unlock() }
      return storedSuccess
    }
    func record(output: String, succeeded: Bool) {
      lock.lock()
      storedOutput = output
      storedSuccess = succeeded
      lock.unlock()
    }
  }

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

  /// Runs one command against this daemon's socket and returns its merged output.
  private func run(
    _ arguments: [String],
    describedAs command: String,
    timeout: Duration = .seconds(30),
    tolerateFailure: Bool = false,
    tolerateTimeout: Bool = false
  ) async throws -> String {
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
          lastRun.record(output: "", succeeded: false)
          return ""
        }
        throw TailscaleError.timedOut(command: command)
      case .launchFailed(_, let reason):
        throw TailscaleError.launchFailed(reason: reason)
      }
    }
    let output = result.trimmedText
    lastRun.record(output: output, succeeded: result.succeeded)
    logger.trace(
      "tailscale command finished",
      metadata: [
        "command": .string(command),
        "status": .stringConvertible(result.status),
      ])
    guard result.succeeded || tolerateFailure else {
      throw TailscaleError.commandFailed(command: command, output: output)
    }
    return output
  }
}

// MARK: - What a person has to do

/// A step only the tailnet's owner can take, and what this server knows about it.
public enum TailscaleAttention: Sendable, Equatable {
  /// Open this link and sign in; the daemon is waiting on it.
  case signInRequired(URL)
  /// The tailnet approves new devices by hand, and this one is queued.
  case deviceApprovalRequired
  /// HTTPS certificates are switched off for the tailnet. The link is the page that
  /// switches them on, when Tailscale printed one.
  case httpsNotEnabled(link: URL?)
  /// Funnel is not granted to this node. Same shape.
  case funnelNotEnabled(link: URL?)

  /// One line for a health report.
  public var summary: String {
    switch self {
    case .signInRequired: "waiting for you to sign in to Tailscale"
    case .deviceApprovalRequired: "waiting for this Mac to be approved on your tailnet"
    case .httpsNotEnabled: "waiting for HTTPS certificates to be enabled on your tailnet"
    case .funnelNotEnabled: "waiting for Funnel to be enabled for this Mac"
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
  private let onAttention: @Sendable (TailscaleAttention) async -> Void
  private let logger: Logger
  private let restartDelay: Duration

  private var address: String?
  private var observer: ProxyObserver?
  /// The background work: waiting on a person, or watching a running node. One at a time.
  private var background: Task<Void, Never>?
  /// What the person was last told, so they are told once rather than every poll.
  private var lastAttention: TailscaleAttention?
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
    onAttention: @escaping @Sendable (TailscaleAttention) async -> Void,
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
    self.onAttention = onAttention
    self.logger = logger
    self.restartDelay = configuration.restartDelay
  }

  public var currentAddress: String? { address }

  public func observe(_ observer: ProxyObserver) async {
    self.observer = observer
  }

  public func connect() async throws -> String {
    isDisconnecting = false
    lastAttention = nil
    await daemon.onTermination { [weak self] code in
      await self?.handleUnexpectedExit(code: code)
    }

    do {
      try await daemon.start()
    } catch let error as DaemonError {
      throw ProxyError.tunnelFailed(reason: BinaryTunnel.describe(error))
    }

    do {
      try await cli.waitUntilResponsive(timeout: .seconds(30))
      switch try await establish() {
      case .ready(let url):
        address = url
        startMonitoring()
        return url
      case .waiting(let attention):
        // The daemon stays up: the link a person was just sent belongs to THIS daemon.
        startWaiting(restartingDaemon: false)
        throw ProxyError.awaitingUser(reason: attention.summary)
      }
    } catch let error as TailscaleError {
      // A real failure. The daemon is stopped here rather than left for the next attempt
      // to find holding the socket.
      await daemon.stop()
      throw ProxyError.tunnelFailed(reason: error.message)
    }
  }

  public func disconnect() async {
    isDisconnecting = true
    background?.cancel()
    background = nil
    await daemon.stop()
    address = nil
    lastAttention = nil
  }

  // MARK: - Bringing the node up

  private enum Outcome {
    case ready(String)
    case waiting(TailscaleAttention)
  }

  /// One pass at getting from "daemon running" to "address published", stopping at the
  /// first step that needs a person.
  private func establish() async throws -> Outcome {
    var status = try await cli.status()

    if !status.isRunning {
      if status.needsMachineAuth {
        return .waiting(await report(.deviceApprovalRequired))
      }
      status = try await cli.up(options: options)
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
      logger.info("Signed in to Tailscale")
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
      logger.info(
        "Tailscale needs something from you",
        metadata: ["step": .string(attention.summary)])
      await onAttention(attention)
    }
    return attention
  }

  // MARK: - Background work

  /// Polls until the pending step is taken and the address can be published.
  ///
  /// - Parameter restartingDaemon: whether the daemon died and has to be brought back first.
  private func startWaiting(restartingDaemon: Bool) {
    guard background == nil else { return }
    background = Task { [weak self] in
      await self?.waitLoop(restartingDaemon: restartingDaemon)
    }
  }

  private func waitLoop(restartingDaemon: Bool) async {
    defer { background = nil }

    if restartingDaemon {
      // The same budget `BinaryTunnel` spends: a daemon that dies once a day is retried
      // forever, one that cannot start at all gives up after ten tries.
      while true {
        guard await daemon.shouldRestart() else {
          let reason =
            "The Tailscale daemon exited repeatedly and will not be restarted again. "
            + "Check the server log for what it printed on the way out."
          logger.error("Giving up on the tunnel", metadata: ["kind": .string("tailscale")])
          await observer?.failed(reason)
          return
        }
        try? await Task.sleep(for: restartDelay)
        if Task.isCancelled || isDisconnecting { return }
        do {
          try await daemon.start()
          try await cli.waitUntilResponsive(timeout: .seconds(30))
          break
        } catch {
          // A daemon that launched and then died reaches `handleUnexpectedExit`, which
          // cancels this task and starts another; one that would not launch at all is
          // retried here, against the same budget.
          logger.warning(
            "The Tailscale daemon did not come back yet",
            metadata: ["reason": .string(String(describing: error))])
        }
      }
    }

    var consecutiveFailures = 0
    while !Task.isCancelled, !isDisconnecting {
      do {
        switch try await establish() {
        case .ready(let url):
          address = url
          logger.info("Tailscale is publishing this server")
          await observer?.addressChanged(url)
          startMonitoringLater()
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

  /// Hands over from the waiting loop to the monitor without the two overlapping: the loop
  /// clears `background` on exit, so the monitor is started from a fresh task.
  private func startMonitoringLater() {
    Task { [weak self] in await self?.startMonitoring() }
  }

  /// Watches a running node for the two things that silently take it down: a node key that
  /// expired (the state drops to `NeedsLogin`), and a rename on the tailnet.
  private func startMonitoring() {
    guard background == nil else { return }
    background = Task { [weak self] in
      await self?.monitorLoop()
    }
  }

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
        background = nil
        startWaiting(restartingDaemon: false)
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
    background?.cancel()
    background = nil
    startWaiting(restartingDaemon: true)
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

  /// The ones with an obvious remedy interrupt; the rest are reported through the proxy's
  /// own failure path and would be a second notice for one event.
  public var isUserFacing: Bool {
    switch self {
    case .invalidAuthKey, .noMagicDNSName, .funnelPortNotAllowed: true
    default: false
    }
  }

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
