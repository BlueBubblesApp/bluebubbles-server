//  TailscaleOptions
//  Everything about the Tailscale node that is not the port it forwards to, and how each
//  option becomes an argument to `tailscale up` and `tailscale serve`.
//
//  Part of the Tailscale connection method; see `TailscaleTunnel.swift` for the design.

import BBCore
import BBServiceKit
import Foundation
import Logging

/// Everything about the Tailscale node that is not the port it forwards to.
public struct TailscaleOptions: Sendable, Equatable {

  /// Who can reach the published address.
  public enum Exposure: String, Sendable, Equatable, CaseIterable {
    /// Devices signed in to the same tailnet: `tailscale serve`.
    case tailnet
    /// The internet, through Tailscale's relays: `tailscale funnel`.
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
  /// the rule because macOS purges what sits unused there for a few days, harmless for a
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
  /// not verify; the same reason zrok gets `--insecure`: the certificate on loopback is
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
