//  TailscaleServeConfig
//  The parts of `tailscale serve status --json` this server reads: which HTTPS addresses a
//  node serves, and what each one forwards to.
//
//  Read for one question only: is a Tailscale that somebody else runs on this Mac already
//  publishing THIS server, and at which address? That is what lets the Tailscale page offer
//  to switch to Custom URL with the address filled in, rather than asking a person to copy
//  it out of a terminal.
//
//  The document is Tailscale's `ipn.ServeConfig`. The keys read here are `Web`, a map from
//  `host:port` to a server config; `Handlers` inside it, a map from a mount path to a
//  handler; and `Proxy` on a handler, the backend it forwards to; plus `AllowFunnel`, keyed
//  by the same `host:port`. Those are the type's field names in Tailscale's source, and
//  `serve status --json` is documented as printing that config. No document from a real
//  node was recorded for the tests, so they are written from the type: treat the shape as
//  stated rather than measured until one has been. Decoded by hand, like `TailscaleStatus`,
//  so a key Tailscale adds cannot fail the read.

import Foundation

/// What a Tailscale node publishes over HTTPS, as `serve status --json` reports it.
public struct TailscaleServeConfig: Sendable, Equatable {

  /// One mount on one HTTPS address.
  public struct Handler: Sendable, Equatable {
    /// The MagicDNS name, without a trailing dot.
    public let host: String
    /// The HTTPS port on the tailnet address.
    public let port: Int
    /// Where on that address it is mounted: `/` for the whole address.
    public let path: String
    /// The backend, as Tailscale stores it: `http://127.0.0.1:1234`, `https+insecure://…`.
    /// Nil for a handler that serves files or text rather than forwarding.
    public let proxy: String?
    /// Whether Funnel is on for this address, so the internet can reach it too.
    public let isFunnel: Bool

    public init(host: String, port: Int, path: String, proxy: String?, isFunnel: Bool) {
      self.host = host
      self.port = port
      self.path = path
      self.proxy = proxy
      self.isFunnel = isFunnel
    }

    /// The address a client would be given for this mount.
    public var publishedAddress: String {
      let base = port == 443 ? "https://\(host)" : "https://\(host):\(port)"
      return path == "/" ? base : base + path
    }

    /// Whether this mount forwards to `port` on this Mac's loopback, speaking the protocol
    /// the listener there speaks.
    ///
    /// Any of the three loopback spellings, because `tailscale serve` accepts `localhost`,
    /// `127.0.0.1` and a bare port (which it stores as `http://127.0.0.1:<port>`). The scheme
    /// has to AGREE with the listener: `http` for a plain one, `https` or `https+insecure`
    /// (Tailscale's spelling for "do not verify the certificate") for one with TLS. A mount
    /// that disagrees forwards to the right port and fails every request, so its address is
    /// not one to hand a client.
    public func forwardsToLoopback(port target: Int, originUsesTLS: Bool) -> Bool {
      guard let proxy, let components = URLComponents(string: proxy),
        let host = components.host, components.port == target,
        let scheme = components.scheme?.lowercased()
      else { return false }
      let schemeAgrees =
        originUsesTLS ? (scheme == "https" || scheme == "https+insecure") : scheme == "http"
      return schemeAgrees
        && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }
  }

  /// Every mount, sorted by address and path so two reads of one config compare equal.
  public let handlers: [Handler]

  public init(handlers: [Handler]) {
    self.handlers = handlers.sorted {
      ($0.host, $0.port, $0.path) < ($1.host, $1.port, $1.path)
    }
  }

  /// The mounts at the ROOT of an address that forward to this server.
  ///
  /// Root only. A client is handed an origin and builds `/api/v1/…` on it, so a mount at
  /// `/bluebubbles` would need a path in the address that no client was ever written to
  /// expect; offering it as the address would be offering one that does not work.
  public func rootHandlers(
    forwardingToLoopbackPort port: Int, originUsesTLS: Bool
  ) -> [Handler] {
    handlers.filter {
      $0.path == "/" && $0.forwardsToLoopback(port: port, originUsesTLS: originUsesTLS)
    }
  }

  /// Nil when the text is not a serve config at all. An empty object, or nothing, is a
  /// node that serves nothing, which is an answer rather than a failure.
  public static func parse(_ text: String) -> TailscaleServeConfig? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return TailscaleServeConfig(handlers: []) }
    // Found rather than assumed at byte zero, as `TailscaleStatus.parse` does, in case a
    // version prints a warning line first.
    guard let start = trimmed.firstIndex(of: "{"),
      let data = String(trimmed[start...]).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let funnels = object["AllowFunnel"] as? [String: Any] ?? [:]
    let web = object["Web"] as? [String: Any] ?? [:]
    var handlers: [Handler] = []
    for (hostPort, value) in web {
      guard let (host, port) = splitHostPort(hostPort),
        let server = value as? [String: Any],
        let mounts = server["Handlers"] as? [String: Any]
      else { continue }
      let isFunnel = (funnels[hostPort] as? Bool) == true
      for (path, handler) in mounts {
        let proxy = ((handler as? [String: Any])?["Proxy"] as? String)
          .flatMap { $0.isEmpty ? nil : $0 }
        handlers.append(
          Handler(host: host, port: port, path: path, proxy: proxy, isFunnel: isFunnel))
      }
    }
    return TailscaleServeConfig(handlers: handlers)
  }

  /// `node.tailnet.ts.net:443` into its two halves, dropping a trailing dot on the name.
  static func splitHostPort(_ value: String) -> (String, Int)? {
    guard let colon = value.lastIndex(of: ":"),
      let port = Int(value[value.index(after: colon)...])
    else { return nil }
    var host = String(value[..<colon])
    if host.hasSuffix(".") { host.removeLast() }
    return host.isEmpty ? nil : (host, port)
  }
}
