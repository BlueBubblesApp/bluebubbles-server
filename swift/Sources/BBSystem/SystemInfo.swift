//  SystemInfo
//  The facts `GET /api/v1/server/info` reports, without shelling out for any of them.
//
//  Each of these is a subprocess in the current server — `PlistBuddy` for the iCloud account,
//  `os.networkInterfaces()` for the addresses, `sntp` for the clock offset. Three of the four
//  have a framework equivalent, and the fourth genuinely does not; see `timeSync`.
//
//  See `.claude/docs/performance.md`.

import BBCore
import Foundation

public enum SystemInfo {

  // MARK: - Identity

  /// `user@hostname`, matching `os.userInfo().username` + `os.hostname()` exactly.
  ///
  /// Clients key local state on this string, so the format is frozen. `Host.current()` is
  /// deliberately not used: it returns the *localized* computer name ("Zach's MacBook Pro"),
  /// while `os.hostname()` returns the network hostname, and swapping one for the other
  /// would silently give every existing client a new identity for the same machine.
  public static func computerIdentifier() -> String {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let hostname =
      gethostname(&buffer, buffer.count) == 0
      ? Self.decode(buffer)
      : ProcessInfo.processInfo.hostName
    return "\(NSUserName())@\(hostname)"
  }

  // MARK: - iCloud account

  /// The signed-in iCloud account, or nil.
  ///
  /// `PlistBuddy -c "print :Accounts:0:AccountID"` becomes reading the plist, which is what
  /// PlistBuddy does anyway. Index 0 is preserved rather than searched: the current server
  /// takes the first account and clients have been shown that value for years, so picking a
  /// "better" one would change what an existing install reports about itself.
  public static func icloudAccount() -> String? {
    let path = (NSHomeDirectory() as NSString)
      .appendingPathComponent("Library/Preferences/MobileMeAccounts.plist")
    guard let data = FileManager.default.contents(atPath: path) else { return nil }

    struct Accounts: Decodable {
      struct Account: Decodable {
        let accountID: String?
        enum CodingKeys: String, CodingKey { case accountID = "AccountID" }
      }
      let accounts: [Account]?
      enum CodingKeys: String, CodingKey { case accounts = "Accounts" }
    }

    guard let decoded = try? PropertyListDecoder().decode(Accounts.self, from: data),
      let account = decoded.accounts?.first?.accountID,
      // The current server requires an "@" before believing it. Kept: the key holds a
      // DSID rather than an address on some accounts, and reporting a bare number as
      // the user's Apple ID is worse than reporting nothing.
      account.contains("@")
    else { return nil }
    return account
  }

  // MARK: - Network addresses

  public enum AddressFamily: Sendable { case ipv4, ipv6 }

  /// Every non-loopback address of the requested family, with the interface it belongs to.
  ///
  /// The interface name matters for choosing among several: a Mac with a VPN, a Docker
  /// bridge or a virtualisation network has multiple IPv4 addresses and only some are
  /// reachable from the LAN.
  public static func interfaces(_ family: AddressFamily) -> [(name: String, address: String)] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    let wanted: Int32 = family == .ipv4 ? Int32(AF_INET) : Int32(AF_INET6)
    var results: [(name: String, address: String)] = []

    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = pointer.pointee
      let flags = Int32(interface.ifa_flags)
      guard let sockaddr = interface.ifa_addr,
        sockaddr.pointee.sa_family == UInt8(wanted),
        flags & IFF_UP != 0,
        flags & IFF_LOOPBACK == 0
      else { continue }

      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          sockaddr, socklen_t(sockaddr.pointee.sa_len),
          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
        ) == 0
      else { continue }

      var address = Self.decode(host)
      if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
      guard !address.isEmpty, !address.hasPrefix("fe80"), !address.hasPrefix("169.254")
      else { continue }

      results.append((name: String(cString: interface.ifa_name), address: address))
    }
    return results
  }

  /// The address a LAN client is most likely to be able to reach.
  ///
  /// `en0`/`en1` first, because those are the physical interfaces — a VPN or a
  /// virtualisation bridge frequently sorts ahead of them in `getifaddrs` order and is
  /// reachable from nothing a user cares about.
  public static func primaryIPv4() -> String? {
    let candidates = interfaces(.ipv4)
    if let physical = candidates.first(where: { $0.name == "en0" || $0.name == "en1" }) {
      return physical.address
    }
    return candidates.first?.address
  }

  /// Non-loopback addresses for this machine.
  ///
  /// `getifaddrs`, matching the filtering the current server does with `os.networkInterfaces`:
  /// the requested family only, and nothing internal. Link-local IPv6 is dropped as well —
  /// Node's `internal` flag does not catch `fe80::`, so the current server publishes
  /// addresses no client can route to, and they are noise in every response.
  public static func localAddresses(_ family: AddressFamily) -> [String] {
    interfaces(family).map(\.address)
  }

  // MARK: - Clock offset

  /// Seconds this Mac's clock differs from Apple's time server, or nil.
  ///
  /// **The one thing in § 14's table that stays a subprocess.** There is no NTP client in
  /// any Apple framework — `SNTP` is not public API and `systemsetup -getnetworktimeserver`
  /// reports configuration rather than drift — so this parses `sntp`, as the current server
  /// does, using the same regular expression.
  ///
  /// It matters because a Mac whose clock is off writes message timestamps that clients sort
  /// wrongly, and that presents as "my messages are out of order" with no other symptom.
  /// - Parameter timeout: bounded because `sntp` blocks until it hears back, and on a
  ///   network that silently drops UDP that is forever. `server/info` is polled by every
  ///   client on connect, so one unreachable time server would stall all of them.
  ///
  /// Nil for every failure — unreachable, timed out, or unparseable. The field is
  /// informational and the rest of `server/info` is still correct without it.
  public static func timeSync(timeout: Duration = .seconds(5)) async -> Double? {
    guard
      let result = try? await Subprocess.run(
        "/usr/bin/sntp", ["time.apple.com"],
        output: .standardOutputOnly, timeout: timeout
      )
    else { return nil }
    // Parsed regardless of exit status: `sntp` reports the offset on stdout even when it
    // exits non-zero, which it does on a partial answer.
    return parseTimeSync(result.text)
  }

  /// Pulls the offset out of `sntp` output.
  ///
  /// The line looks like `+0.001234 +/- 0.012345 time.apple.com`, and the value wanted is
  /// the part before `+/-`. Transcribed from the current server's regular expression rather
  /// than reinvented, because the field this feeds is compared against Node's output.
  static func parseTimeSync(_ output: String) -> Double? {
    let pattern = #"[+-]?([0-9]*[.])?[0-9]+ \+/- [+-]?([0-9]*[.])?[0-9]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(output.startIndex..., in: output)
    guard let match = regex.firstMatch(in: output, range: range),
      let matched = Range(match.range, in: output)
    else { return nil }
    return Double(output[matched].components(separatedBy: " +/- ")[0])
  }

  /// A NUL-terminated C buffer as a String.
  ///
  /// `String(cString:)` on a `[CChar]` is deprecated because it reads past the array's
  /// own bounds looking for the terminator. Truncating at the NUL first and decoding the
  /// prefix is the documented replacement, and it cannot run off the end.
  static func decode(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
