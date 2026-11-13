//  ExistingTailscale
//  Whether a Tailscale that somebody else runs is up on this Mac, which node it is, and what
//  it already publishes.
//
//  A person who installed Tailscale from MacPorts or Homebrew and ran it as a system daemon
//  has a node that is already signed in. The Tailscale connection method does not use it:
//  it runs a node of its own, with its own state and socket (see `TailscaleTunnel`), so they
//  sign in a second time and get a second machine on their tailnet. Someone who would rather
//  run `tailscale serve` themselves is better served by Custom URL, and this is what lets the
//  page offer that switch with the address already filled in.
//
//  **It only ever reads.** Status and the serve config, both of which a daemon running as
//  root answers to any local user. Nothing here starts, stops or reconfigures the daemon:
//  it is the person's own VPN, and possibly the connection they are using to reach this Mac.
//
//  Only the default socket is asked, `/var/run/tailscaled.socket`, which is the CLI's own
//  default (`tailscale --help`) and where a system daemon listens unless it was told
//  otherwise. A daemon started with another `--socket` is not found, and the page simply
//  says nothing. The standalone and App Store Tailscale apps do not listen there at all and
//  are not detected yet.

import BBCore
import Foundation
import Logging

/// What answered on the system Tailscale socket.
public enum ExistingTailscale: Sendable, Equatable {
  /// No socket, or nothing answering on it.
  case none
  /// A daemon answered, and is not running a signed-in node: `NeedsLogin`, `Stopped` and
  /// the like. Carries Tailscale's own state name.
  case notRunning(backendState: String)
  /// A signed-in node.
  case running(Node)

  public struct Node: Sendable, Equatable {
    /// The MagicDNS name, without the trailing dot.
    public let dnsName: String?
    public let hostName: String?
    /// The tailnet has granted HTTPS certificates to this node: `tailscale serve` over
    /// HTTPS can work.
    public let hasHTTPS: Bool
    public let hasFunnel: Bool
    /// What it publishes, or nil when the serve config could not be read. Kept apart from
    /// an empty config, which is a node that publishes nothing.
    public let serve: TailscaleServeConfig?

    public init(
      dnsName: String?, hostName: String?, hasHTTPS: Bool, hasFunnel: Bool,
      serve: TailscaleServeConfig?
    ) {
      self.dnsName = dnsName
      self.hostName = hostName
      self.hasHTTPS = hasHTTPS
      self.hasFunnel = hasFunnel
      self.serve = serve
    }
  }

  /// Where a system daemon listens by default.
  public static let systemSocketPath = "/var/run/tailscaled.socket"

  /// Asks the daemon on `socketPath`, using the `tailscale` CLI at `cliPath`.
  ///
  /// Throws only `CancellationError`. Every other failure is an answer: no socket and a
  /// daemon that would not answer are both `.none`, logged, because there is nothing a
  /// person could do with the difference on a page that offers a shortcut.
  public static func inspect(
    cliPath: String,
    socketPath: String = systemSocketPath,
    logger: Logger = Logger(label: "bluebubbles.proxy.tailscale.existing")
  ) async throws(CancellationError) -> ExistingTailscale {
    // Checked before spawning, because a Mac with no system daemon is the common case and
    // costs a `stat` this way rather than a 50 MB process.
    guard FileManager.default.fileExists(atPath: socketPath) else { return .none }
    let cli = TailscaleCLI(executablePath: cliPath, socketPath: socketPath, logger: logger)

    let status: TailscaleStatus
    do {
      status = try await cli.status()
    } catch let cancelled as CancellationError {
      throw cancelled
    } catch {
      logger.debug(
        "The Tailscale daemon on this Mac did not answer",
        metadata: ["error": .string(String(describing: error))])
      return .none
    }
    guard status.isRunning else { return .notRunning(backendState: status.backendState) }

    var serve: TailscaleServeConfig?
    do {
      serve = try await cli.serveStatus()
    } catch let cancelled as CancellationError {
      throw cancelled
    } catch {
      // Recorded as unknown, not as empty: "it publishes nothing" would be a claim.
      logger.debug(
        "Could not read what the Tailscale daemon on this Mac publishes",
        metadata: ["error": .string(String(describing: error))])
    }
    return .running(
      Node(
        dnsName: status.dnsName, hostName: status.hostName, hasHTTPS: status.hasHTTPS,
        hasFunnel: status.hasFunnel, serve: serve))
  }
}
