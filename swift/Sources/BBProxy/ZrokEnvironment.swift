//  ZrokEnvironment
//  The half of zrok that is not a long-running process.
//
//  cloudflared and ngrok are handed a credential and start. zrok is not: before anything can
//  be shared, this Mac has to be ENABLED against a zrok account, and a share that keeps its
//  address has to be RESERVED — two separate one-shot commands whose output has to be read
//  back, one of which hands over a token that must then be remembered. The TypeScript server
//  had all of this in `ZrokManager`; the Swift port had the long-running `zrok share` and
//  nothing else, so the Account Token field on the zrok page was collected, stored, and never
//  used by anything.
//
//  Everything here is a short command that runs, prints, and exits. `DaemonProcess` is the
//  wrong tool for that — it supervises, restarts, and waits for a readiness line — so this
//  owns a small runner of its own rather than bending one into the other.
//
//  See `.claude/docs/performance.md`.

import BBCore
import Darwin
import Foundation
import Logging

// MARK: - Errors

public enum ZrokError: BBError, Equatable {
  case executableMissing(path: String)
  case launchFailed(reason: String)
  /// The command ran and failed. `output` is zrok's own words, which are the only useful
  /// explanation — "exit status 1" names nothing a user could act on.
  case commandFailed(command: String, output: String)
  case timedOut(command: String)
  /// The account token was rejected. Separate from `commandFailed` because it is the one
  /// failure with an obvious remedy, and the caller can say so.
  case invalidAccountToken
  /// No account token has been entered, so this Mac cannot be enabled at all.
  case notEnabled
  /// `zrok reserve` succeeded but printed nothing recognisable as a share token.
  case reserveFailed(output: String)

  public var message: String {
    switch self {
    case .executableMissing(let path):
      "the zrok program is missing at \(path)"
    case .launchFailed(let reason):
      reason
    case .commandFailed(_, let output):
      output.isEmpty ? "zrok failed without printing anything" : output
    case .timedOut(let command):
      "zrok \(command) did not finish in time"
    case .invalidAccountToken:
      "zrok rejected the account token"
    case .notEnabled:
      "this Mac has not been enabled against a zrok account"
    case .reserveFailed(let output):
      output.isEmpty
        ? "zrok reserved a share but did not report its token"
        : "zrok reserved a share but did not report its token: \(output)"
    }
  }
}

// MARK: - Overview

/// One share belonging to this Mac's zrok environment, as `zrok overview` describes it.
///
/// A subset of what zrok prints, decoded by hand rather than with `Codable`: the overview is a
/// nested document whose shape is zrok's business and not ours, and modelling all of it would
/// mean a decode failure every time they add a key.
public struct ZrokShare: Sendable, Equatable {
  public let token: String
  public let shareMode: String
  public let backendMode: String
  /// Where the share forwards to, as zrok recorded it when the share was created. Compared
  /// against the endpoint this server would use now, which is how a share left over from a
  /// different port is spotted.
  public let backendProxyEndpoint: String
  public let isReserved: Bool
  public let frontendEndpoint: String?

  /// Whether this is a share this server could adopt.
  ///
  /// The same four conditions the TypeScript server checked, kept together so "is this ours"
  /// has one answer rather than one per call site.
  public func matches(endpoint: String, backendMode: String) -> Bool {
    isReserved
      && shareMode == "public"
      && self.backendMode == backendMode
      && backendProxyEndpoint == endpoint
  }
}

// MARK: - The environment

/// zrok's setup commands, for one installed agent.
///
/// An actor because `enable` and `reserve` both mutate state that lives outside this process —
/// zrok's own `~/.zrok` and the user's account — and two of them running at once produces
/// exactly the duplicate shares this is meant to avoid.
public actor ZrokEnvironment {

  private let executablePath: String
  /// Carried onto every invocation, so a self-hosted controller is reached by the setup
  /// commands and the share alike. See `ZrokOptions.environment`.
  private let environment: [String: String]
  private let logger: Logger

  public init(
    executablePath: String,
    environment: [String: String] = [:],
    logger: Logger = Logger(label: "bluebubbles.proxy.zrok")
  ) {
    self.executablePath = executablePath
    self.environment = environment
    self.logger = logger
  }

  // MARK: Enabling this Mac

  /// Whether this Mac already has a usable zrok environment.
  ///
  /// Asked by running `overview`, which is the cheapest command that needs an environment to
  /// exist. There is no "am I enabled" subcommand, and inspecting `~/.zrok` by hand would be
  /// reimplementing zrok's own idea of where its state lives.
  public func isEnabled() async -> Bool {
    (try? await overview()) != nil
  }

  /// Enables this Mac against a zrok account, unless it already is.
  ///
  /// Idempotent on purpose: this runs on the path to starting the tunnel, not from a setup
  /// button, so it has to be safe to reach on every launch. zrok's own "you already have an
  /// enabled environment" is treated as success for the same reason the TypeScript server
  /// treated it that way — it describes the state we wanted.
  ///
  /// - Returns: whether anything actually changed, so the caller can log a first enable
  ///   without logging a no-op every time the server starts.
  @discardableResult
  public func enableIfNeeded(accountToken: String) async throws -> Bool {
    let token = accountToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw ZrokError.notEnabled }
    if await isEnabled() { return false }

    logger.info("Enabling this Mac against a zrok account")
    do {
      // The token IS on the command line here, and that is not the choice it is for
      // cloudflared and ngrok — zrok's `enable` takes it as a positional argument and
      // offers no environment variable or file to read it from. What limits the exposure
      // is that this command runs for about a second, once, rather than for the life of
      // the server. It is still worth knowing about: see `NgrokOptions.environment` for
      // why an argument is the wrong place for a secret that has any alternative.
      _ = try await run(["enable", token], describedAs: "enable")
      return true
    } catch let error as ZrokError {
      guard case .commandFailed(_, let output) = error else { throw error }
      let lowered = output.lowercased()
      if lowered.contains("already have an enabled environment") { return false }
      if lowered.contains("enableunauthorized") { throw ZrokError.invalidAccountToken }
      throw error
    }
  }

  /// Unlinks this Mac from the zrok account, releasing every share it owns with it.
  public func disable() async throws {
    _ = try await run(["disable"], describedAs: "disable")
  }

  // MARK: Shares

  /// Every share belonging to THIS Mac's environment.
  ///
  /// Filtered by the environment description, which zrok sets to `user@hostname` when the
  /// environment is enabled — the same string `SystemInfo.computerIdentifier()` produces, and
  /// the same match the TypeScript server made. Without the filter, a zrok account shared
  /// between two Macs would have each of them adopting the other's shares.
  public func shares(ownedBy identifier: String) async throws -> [ZrokShare] {
    let document = try await overview()
    guard let environments = document["environments"] as? [[String: Any]] else { return [] }

    let mine = environments.first { environment in
      let details = environment["environment"] as? [String: Any]
      return details?["description"] as? String == identifier
    }
    guard let mine, let shares = mine["shares"] as? [[String: Any]] else { return [] }

    return shares.compactMap { share in
      guard let token = share["shareToken"] as? String else { return nil }
      return ZrokShare(
        token: token,
        shareMode: share["shareMode"] as? String ?? "",
        backendMode: share["backendMode"] as? String ?? "",
        backendProxyEndpoint: share["backendProxyEndpoint"] as? String ?? "",
        // Absent means not reserved. zrok omits the key on an ephemeral share rather
        // than writing `false`, so a missing key has to mean the same thing.
        isReserved: share["reserved"] as? Bool ?? false,
        frontendEndpoint: share["frontendEndpoint"] as? String
      )
    }
  }

  /// Reserves a share that keeps its address, and returns its token.
  ///
  /// - Parameters:
  ///   - endpoint: what the share forwards to, e.g. `http://localhost:1234`.
  ///   - name: a unique name to ask zrok for, or empty to let it generate one. A name that
  ///     someone else has already taken is refused by zrok, which is reported rather than
  ///     worked around — silently getting a different name is how a user ends up publishing
  ///     an address they never chose.
  public func reserve(
    endpoint: String,
    name: String,
    backendMode: String
  ) async throws -> String {
    var arguments = ["reserve", "public", endpoint, "--backend-mode", backendMode]
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedName.isEmpty {
      arguments.append(contentsOf: ["--unique-name", trimmedName])
    }

    logger.info(
      "Reserving a zrok share",
      metadata: [
        "endpoint": .string(endpoint),
        "name": .string(trimmedName.isEmpty ? "(generated)" : trimmedName),
      ])

    let output: String
    do {
      output = try await run(arguments, describedAs: "reserve")
    } catch let error as ZrokError {
      guard case .commandFailed(_, let text) = error else { throw error }
      // zrok reports a name collision as an opaque internal server error, so the useful
      // sentence has to be supplied here.
      if text.lowercased().contains("shareinternalservererror") {
        throw ZrokError.commandFailed(
          command: "reserve",
          output: "zrok refused to reserve this share. The name may already be in "
            + "use on your account or on someone else's."
        )
      }
      throw error
    }

    guard let token = Self.reservedToken(in: output) else {
      throw ZrokError.reserveFailed(output: output)
    }
    return token
  }

  /// Releases a reserved share, tolerating one that is already gone.
  ///
  /// Never throws: releasing is cleanup, and the callers are a service stopping and a user
  /// switching a toggle off. Failing either of those because a share had already been
  /// deleted from the zrok dashboard would be reporting our bookkeeping as their problem.
  ///
  /// - Returns: whether the share is now gone, so a caller can decide whether to forget its
  ///   token.
  @discardableResult
  public func release(token: String) async -> Bool {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }

    do {
      _ = try await run(["release", trimmed], describedAs: "release")
      logger.info("Released a zrok share")
      return true
    } catch let error as ZrokError {
      // Already gone is the outcome we wanted.
      if case .commandFailed(_, let output) = error,
        output.lowercased().contains("unsharenotfound")
      {
        return true
      }
      logger.warning(
        "Could not release a zrok share",
        metadata: [
          "reason": .string(error.message)
        ])
      return false
    } catch {
      return false
    }
  }

  // MARK: - Internals

  /// `zrok overview`, decoded.
  private func overview() async throws -> [String: Any] {
    let output = try await run(["overview"], describedAs: "overview")
    // zrok prints its own log lines before the document on some versions, so the JSON is
    // found rather than assumed to start at byte zero.
    guard let start = output.firstIndex(of: "{"),
      let data = String(output[start...]).data(using: .utf8),
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ZrokError.commandFailed(command: "overview", output: output)
    }
    return document
  }

  /// The share token out of `zrok reserve`'s output.
  ///
  /// zrok prints `... reserved share token is 'abcd1234'`. Matched on that sentence rather
  /// than on the first token-shaped word, because the same output also carries the share's
  /// URL, which contains one.
  static func reservedToken(in output: String) -> String? {
    let marker = "reserved share token is '"
    guard let start = output.range(of: marker) else { return nil }
    let tail = output[start.upperBound...]
    guard let end = tail.firstIndex(of: "'") else { return nil }
    let token = String(tail[..<end])
    return token.isEmpty ? nil : token
  }

  /// Runs one zrok command to completion and returns its merged output.
  private func run(
    _ arguments: [String],
    describedAs command: String,
    timeout: Duration = .seconds(60)
  ) async throws -> String {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw ZrokError.executableMissing(path: executablePath)
    }
    return try await ShortCommand.run(
      executablePath: executablePath,
      arguments: arguments,
      environment: environment,
      command: command,
      timeout: timeout
    )
  }
}

// MARK: - Running a command that exits

/// A subprocess that is expected to finish, as opposed to one that is expected to stay up.
///
/// Deliberately NOT `DaemonProcess`: that supervises a long-running tunnel, waits for a
/// readiness line, and restarts what dies. None of that applies to `zrok overview`, and every
/// one of those behaviours would be actively wrong for it.
enum ShortCommand {

  /// Everything a finished command printed, or the error that stopped it.
  ///
  /// Output is drained CONCURRENTLY rather than read after the process exits. A pipe holds
  /// about 64KB, and `zrok overview` on an account with a few shares prints more than that —
  /// so waiting for the exit first would deadlock: zrok blocks writing into a full pipe
  /// nobody is reading, and we block waiting for a process that can never finish.
  static func run(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    command: String,
    timeout: Duration
  ) async throws -> String {
    // Was ~70 lines of hand-rolled process handling: a task group racing `waitUntilExit`
    // on a detached thread against a sleeping timeout, an `OutputBuffer` fed by a
    // readability handler, and a `readToEnd()` to catch the tail. All of that now lives in
    // `Subprocess`, including one bug this had and nothing had hit yet — that closing
    // `readToEnd()` blocks until every write end of the pipe is closed, and this process
    // still held one, so a command whose output landed entirely at the end could hang here
    // forever.
    let result: Subprocess.Result
    do {
      result = try await Subprocess.run(
        executablePath, arguments,
        environment: environment,
        // Merged: zrok puts its errors on one stream and its answers on the other, and
        // which is which has moved between versions.
        output: .merged,
        timeout: timeout
      )
    } catch let failure as Subprocess.Failure {
      switch failure {
      case .timedOut:
        throw ZrokError.timedOut(command: command)
      case .launchFailed(_, let reason):
        throw ZrokError.launchFailed(reason: reason)
      }
    }

    let output = result.trimmedText
    guard result.succeeded else {
      throw ZrokError.commandFailed(command: command, output: output)
    }
    return output
  }
}

extension ZrokError {
  public var code: String {
    switch self {
    case .executableMissing: "zrok.executable_missing"
    case .launchFailed: "zrok.launch_failed"
    case .commandFailed: "zrok.command_failed"
    case .timedOut: "zrok.timed_out"
    case .invalidAccountToken: "zrok.invalid_account_token"
    case .notEnabled: "zrok.not_enabled"
    case .reserveFailed: "zrok.reserve_failed"
    }
  }

  public var domain: String { "Proxy" }

  /// The two with an obvious remedy interrupt; the rest are reported through the proxy's
  /// own failure path and would be a second notice for one event.
  public var isUserFacing: Bool {
    switch self {
    case .invalidAccountToken, .notEnabled: true
    default: false
    }
  }

  public var title: String {
    switch self {
    case .invalidAccountToken: "zrok rejected the account token"
    case .notEnabled: "This Mac is not enabled for zrok"
    default: "zrok reported a problem"
    }
  }

  /// `message` already carries zrok's own words, which are the only useful explanation.
  public var body: String { message }
}
