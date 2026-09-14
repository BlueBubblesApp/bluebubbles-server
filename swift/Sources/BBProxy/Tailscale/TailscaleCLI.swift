//  TailscaleCLI
//  The `tailscale` CLI, pointed at this server's own daemon: status, up, serve, and the
//  waits between them.
//
//  Part of the Tailscale connection method; see `TailscaleTunnel.swift` for the design.

import BBCore
import BBServiceKit
import Foundation
import Logging

/// The `tailscale` CLI, pointed at this server's own daemon.
public struct TailscaleCLI: Sendable {

  /// What one command said and whether it succeeded, for the callers that tolerate a
  /// failure and then need to look at it.
  public typealias CommandResult = ToolCommand.Result

  /// The `tailscale` executable: the CLI, not the daemon.
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
    // asked for, so its exit code is ignored and only its document is read.
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
  /// timeout ends the wait, and the link stays valid in the daemon (`status` reports it)
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
    if !afterwards.isRunning {
      // The one place the command's own words are kept when it did not get the node
      // running. Without this a "NoState and no link" report has nothing behind it.
      logger.debug(
        "tailscale up did not leave the node running",
        metadata: [
          "state": .string(afterwards.backendState),
          "output": .string(Self.lastLine(of: result.output)),
        ])
    }
    // A REFUSED key: the command failed with the key present and the node is still signed
    // out. Not a slow one: a control server that takes longer than the timeout leaves the
    // node `Starting` with the command killed, and that is a node to keep polling, not a
    // key to stop using. `up` said why on the way out: THIS command's output, not the
    // status document read a moment later.
    if !key.isEmpty, !result.succeeded, !result.timedOut, afterwards.needsLogin {
      throw TailscaleError.invalidAuthKey(output: Self.lastLine(of: result.output))
    }
    return afterwards
  }

  /// Waits for the tailnet to assign the DNS name that goes with a machine name, bounded.
  ///
  /// A rename is two steps apart in the daemon: `up --hostname=X` applies the preference
  /// at once, and the DNS name that clients are given changes only when the control plane
  /// sends the next network map: a second or two on a good day. Reading `status` in
  /// between hands the OLD name to every client.
  ///
  /// Bounded because the tailnet may legitimately assign something else: a name already
  /// taken comes back as `X-1`. That counts as a match. Anything else after the timeout is
  /// published as it is, and the monitor republishes if it changes later.
  public func waitForMachineName(
    _ hostname: String, timeout: Duration = .seconds(20)
  ) async throws -> TailscaleStatus {
    let deadline = ContinuousClock.now + timeout
    var latest = try await status()
    while ContinuousClock.now < deadline {
      if Self.machineName(latest.assignedMachineName, matches: hostname) { return latest }
      try await Task.sleep(for: .seconds(1))
      latest = try await status()
    }
    logger.info(
      "The tailnet has not applied the machine name yet; publishing what it reports",
      metadata: [
        "requested": .string(hostname),
        "assigned": .string(latest.assignedMachineName ?? "-"),
      ])
    return latest
  }

  /// Whether an assigned name is the requested one, or the requested one de-duplicated.
  static func machineName(_ assigned: String?, matches hostname: String) -> Bool {
    guard let assigned else { return false }
    return assigned == hostname || assigned.hasPrefix(hostname + "-")
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
  /// feature, which is why the capabilities are read first and the command runs under a
  /// timeout.
  public func configureServe(
    options: TailscaleOptions, forwardingTo port: Int
  ) async throws -> ServeOutcome {
    let command = options.exposure == .funnel ? "funnel" : "serve"
    let arguments = options.serveArguments(forwardingTo: port)

    // The capabilities first, because the command cannot be relied on to say. With one
    // missing it still runs (briefly, tolerating being killed) since in its non-blocking
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

  /// The first `https://` link in a command's output: the enabling page Tailscale prints.
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
    do {
      return try await ToolCommand.run(
        tool: "Tailscale",
        executablePath: executablePath,
        arguments: ["--socket=\(socketPath)"] + arguments,
        command: command,
        timeout: timeout,
        tolerateFailure: tolerateFailure,
        tolerateTimeout: tolerateTimeout,
        logger: logger
      )
    } catch let failure as ToolCommandError {
      throw TailscaleError.command(failure)
    }
  }
}
