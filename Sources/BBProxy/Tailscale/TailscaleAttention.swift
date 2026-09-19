//  TailscaleAttention
//  A step only the tailnet's owner can take, and what this server knows about it.
//
//  Part of the Tailscale connection method; see `TailscaleTunnel.swift` for the design.

import BBCore
import BBServiceKit
import Foundation
import Logging

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

  /// The Tailscale admin pages, for the steps where Tailscale printed no link of its own:
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
          + "on its own, or choose \"Only devices on my tailnet\" on the Tailscale page "
          + "instead.",
        link: link ?? Pages.funnel,
        key: "funnel.\(link?.lastPathComponent ?? "")",
        summary: "waiting for Funnel to be enabled for this Mac"
      )
    }
  }
}
