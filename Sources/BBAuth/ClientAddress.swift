//  ClientAddress
//  Whose request this is: the address rules access control counts and blocks against.
//
//  Deciding WHOSE failure a request is matters more than the counting. Nearly every install
//  sits behind Cloudflare, ngrok or zrok, so the socket peer is the tunnel's egress, identical
//  for every client, and counting against it would lock out the whole user base at the first
//  brute-force attempt. So `X-Forwarded-For` is believed only from a configured trusted proxy,
//  and the entry taken is the rightmost untrusted one, because the leftmost is whatever the
//  client sent. `CIDR` is just enough address parsing to match an allowlist or a proxy range,
//  and deliberately not a general address library.
//
//  See `docs/AUTH.md`.

import BBCore
import Foundation

// MARK: - Client identity

public enum ClientIdentity: Sendable, Hashable {
  /// A real client address we are willing to act on.
  case address(String)
  /// No usable per-client address. Blocking is off the table for this request.
  case unresolved
}

public struct ProxyTrustPolicy: Sendable {
  /// Peer addresses whose forwarding headers we believe. Literal addresses or CIDR blocks.
  /// Loopback by default: the bundled tunnels all run on this machine and connect over it.
  public var trustedProxies: Set<String>
  /// Addresses that can never be blocked regardless of failure count. The active tunnel
  /// egress is added here at connect time.
  public var permanentAllowlist: Set<String>
  public var honorForwardedFor: Bool

  public init(
    trustedProxies: Set<String> = ["127.0.0.1", "::1", "localhost"],
    permanentAllowlist: Set<String> = ["127.0.0.1", "::1"],
    honorForwardedFor: Bool = true
  ) {
    self.trustedProxies = trustedProxies
    self.permanentAllowlist = permanentAllowlist
    self.honorForwardedFor = honorForwardedFor
  }

  /// Resolves the address to hold responsible for a request.
  ///
  /// `forwardedFor` is the raw header, `client, proxy1, proxy2` in append order. The
  /// leftmost entry is whatever the client sent and is trivially spoofed, so we walk from
  /// the RIGHT and take the first entry that is not itself a trusted proxy. That is the
  /// nearest address we have any reason to believe.
  public func resolve(peerAddress: String?, forwardedFor: String?) -> ClientIdentity {
    guard let peerAddress, !peerAddress.isEmpty else { return .unresolved }

    let peer = Self.normalize(peerAddress)

    guard honorForwardedFor, isTrustedProxy(peer) else {
      // Direct connection, or a proxy we do not trust. Either way the peer is the
      // client as far as we are concerned.
      return .address(peer)
    }

    guard let forwardedFor, !forwardedFor.isEmpty else {
      // A trusted proxy that forwarded no header. We cannot attribute this to anyone,
      // and blaming the proxy is exactly the outage described above.
      return .unresolved
    }

    let hops =
      forwardedFor
      .split(separator: ",")
      .map { Self.normalize(String($0).trimmingCharacters(in: .whitespaces)) }
      .filter { !$0.isEmpty }

    for hop in hops.reversed() where !isTrustedProxy(hop) {
      return .address(hop)
    }

    // Every hop was a trusted proxy. No client to attribute to.
    return .unresolved
  }

  /// Whether an address is one of the configured proxies.
  ///
  /// Matched through CIDR rather than by set membership, so `10.0.0.0/8` covers a whole
  /// internal network. A reverse proxy behind a load balancer does not have one stable
  /// address, and requiring every possible one to be enumerated is how this setting gets
  /// misconfigured into uselessness.
  public func isTrustedProxy(_ address: String) -> Bool {
    let normalized = Self.normalize(address)
    if trustedProxies.contains(normalized) { return true }
    return trustedProxies.contains {
      $0.contains("/") && CIDR.matches(address: normalized, pattern: $0)
    }
  }

  /// Strips an IPv6 zone, unwraps brackets, and drops an IPv4-mapped IPv6 prefix, so
  /// `::ffff:1.2.3.4` and `1.2.3.4` are the same client rather than two.
  static func normalize(_ address: String) -> String {
    var value = address
    if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
      value = String(value[value.index(after: value.startIndex)..<close])
    }
    if let percent = value.firstIndex(of: "%") {
      value = String(value[value.startIndex..<percent])
    }
    if value.lowercased().hasPrefix("::ffff:") {
      let tail = String(value.dropFirst(7))
      if tail.contains(".") { value = tail }
    }
    return value.lowercased()
  }
}

// MARK: - CIDR

/// Just enough CIDR to evaluate the allowlist. Deliberately not a general address library:
/// it parses IPv4 and IPv6 into their bit patterns and compares a prefix.
public enum CIDR {

  /// Whether this is a pattern `matches` could ever match.
  ///
  /// The Security page took whatever was typed, appended it to the allowlist and discarded
  /// the result, so a mistyped entry (`192.168.1.o/24`) appeared in the list looking active
  /// and protected nobody: `matches` simply never matched it, and the field was cleared as
  /// though it had worked. An allowlist entry that silently does nothing is worse than a
  /// refused one, because the person believes they are covered.
  ///
  /// Deliberately the SAME parse `matches` uses, so the two cannot disagree: anything this
  /// accepts, that will evaluate.
  public static func isValidPattern(_ pattern: String) -> Bool {
    let trimmed = pattern.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    guard trimmed.contains("/") else {
      return bits(of: ProxyTrustPolicy.normalize(trimmed)) != nil
    }
    let parts = trimmed.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let prefixLength = Int(parts[1]),
      let networkBits = bits(of: ProxyTrustPolicy.normalize(String(parts[0]))),
      prefixLength >= 0, prefixLength <= networkBits.count * 8
    else { return false }
    return true
  }

  static func matches(address: String, pattern: String) -> Bool {
    let address = ProxyTrustPolicy.normalize(address)
    guard pattern.contains("/") else {
      return ProxyTrustPolicy.normalize(pattern) == address
    }

    let parts = pattern.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let prefixLength = Int(parts[1]) else { return false }
    let network = ProxyTrustPolicy.normalize(String(parts[0]))

    guard let addressBits = bits(of: address),
      let networkBits = bits(of: network),
      addressBits.count == networkBits.count,
      prefixLength >= 0, prefixLength <= addressBits.count * 8
    else { return false }

    var remaining = prefixLength
    for index in 0..<addressBits.count {
      if remaining >= 8 {
        if addressBits[index] != networkBits[index] { return false }
        remaining -= 8
      } else if remaining > 0 {
        let mask = UInt8(0xFF) << UInt8(8 - remaining)
        if (addressBits[index] & mask) != (networkBits[index] & mask) { return false }
        remaining = 0
      } else {
        break
      }
    }
    return true
  }

  static func bits(of address: String) -> [UInt8]? {
    if address.contains(".") && !address.contains(":") {
      // The COUNT is checked before the parse, and the parse fails the whole address rather
      // than dropping what it cannot read.
      //
      // `split(…).compactMap { UInt8($0) }` discarded an unparseable octet and then counted
      // what survived, so `10.0.0.x.0` came out as the four valid pieces — a well-formed
      // `10.0.0.0`, a DIFFERENT network from anything the operator typed. `isValidPattern`
      // shares this parse, which is what made it worse than a near miss: the Security page
      // accepted the typo and reported it valid, for a range nobody asked for.
      // And no piece may be EMPTY: `10.0..0.1` split with the default dropped the empty
      // one and parsed as `10.0.0.1`. See `IPv4`.
      return IPv4.octets(address)
    }
    guard address.contains(":") else { return nil }

    // Expand the `::` run, then parse 8 groups of 16 bits.
    let hasElision = address.contains("::")
    let sides = address.components(separatedBy: "::")
    guard sides.count <= 2 else { return nil }

    func groups(_ text: String) -> [UInt16]? {
      guard !text.isEmpty else { return [] }
      var result: [UInt16] = []
      for piece in text.split(separator: ":") {
        guard let value = UInt16(piece, radix: 16) else { return nil }
        result.append(value)
      }
      return result
    }

    guard let head = groups(sides[0]) else { return nil }
    let tail = sides.count == 2 ? groups(sides[1]) : []
    guard let tail else { return nil }

    var all: [UInt16]
    if hasElision {
      let fill = 8 - head.count - tail.count
      guard fill >= 0 else { return nil }
      all = head + Array(repeating: 0, count: fill) + tail
    } else {
      all = head
    }
    guard all.count == 8 else { return nil }

    return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
  }
}
