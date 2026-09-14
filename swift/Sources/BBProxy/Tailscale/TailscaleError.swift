//  TailscaleError
//  What can go wrong bringing a Tailscale node up, in the words a person reads.
//
//  Part of the Tailscale connection method; see `TailscaleTunnel.swift` for the design.

import BBCore
import BBServiceKit
import Foundation
import Logging

public enum TailscaleError: BBError, Equatable {
  /// One tailscale command could not be run or failed; see `ToolCommandError`.
  case command(ToolCommandError)
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

  /// A failed command, in the shape `run` throws, for the places that construct one with
  /// a better sentence than Tailscale printed.
  static func commandFailed(command: String, output: String) -> TailscaleError {
    .command(.commandFailed(tool: "Tailscale", command: command, output: output))
  }

  static func launchFailed(reason: String) -> TailscaleError {
    .command(.launchFailed(tool: "Tailscale", reason: reason))
  }

  public var message: String {
    switch self {
    case .command(let failure):
      failure.message
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

extension TailscaleError {
  public var code: String {
    switch self {
    case .command(let failure): failure.code
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
