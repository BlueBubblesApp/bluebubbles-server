//  SystemInfoTests
//  The machine facts `server/info` reports.
//
//  These replaced four subprocesses — `PlistBuddy`, `sntp`, `os.networkInterfaces` and the
//  hostname lookup. The parsing is what is pinned here; the values themselves depend on the
//  host and cannot be asserted, so the tests check shape and the filtering rules rather than
//  specific addresses.
//
//  See `.claude/docs/imessage.md`.

import Foundation
import Testing

@testable import BBSystem

@Suite("System info")
struct SystemInfoTests {

  // MARK: - Clock offset

  @Test("The offset is taken from the value before +/-")
  func parsesTimeSync() {
    // Real `sntp` output. The number wanted is the offset, not the error margin that
    // follows it — reading the wrong half reports a plausible number that is not the
    // answer, which is the failure mode worth pinning.
    let output = """
      sntp 4.2.8p15@1.3728-o Wed Feb  1 20:07:53 UTC 2023 (1)
      +0.007475 +/- 0.021068 time.apple.com 17.253.6.253
      """
    #expect(SystemInfo.parseTimeSync(output) == 0.007475)
  }

  @Test("A negative offset keeps its sign")
  func parsesNegativeOffset() {
    // A Mac whose clock is AHEAD is the case that matters — it writes message timestamps
    // in the future, and clients sort them to the top of the list forever.
    let output = "-1.234567 +/- 0.010000 time.apple.com 17.253.6.253"
    #expect(SystemInfo.parseTimeSync(output) == -1.234567)
  }

  @Test("Output with no offset yields nil rather than zero")
  func rejectsUnparseableOutput() {
    // Zero would mean "this Mac's clock is perfect", which is the opposite of "we could
    // not reach a time server".
    #expect(SystemInfo.parseTimeSync("") == nil)
    #expect(SystemInfo.parseTimeSync("sntp: kod_init_kod_db(): Cannot open") == nil)
  }

  // MARK: - Identity

  @Test("The computer identifier is user@hostname")
  func computerIdentifierShape() {
    // Frozen format: clients key local state on this string, so a change re-identifies
    // every existing install as a new machine.
    let identifier = SystemInfo.computerIdentifier()
    let parts = identifier.split(separator: "@")
    #expect(parts.count >= 2, "expected user@hostname, got \(identifier)")
    #expect(parts.first.map(String.init) == NSUserName())
    #expect(!(parts.last?.isEmpty ?? true))
  }

  // MARK: - Addresses

  @Test("Loopback and link-local addresses are excluded")
  func addressFiltering() {
    // Node's `internal` flag does not catch `fe80::`, so the current server publishes
    // link-local addresses that no client can route to. They are noise at best and a
    // failed connection attempt at worst.
    for address in SystemInfo.localAddresses(.ipv4) {
      #expect(address != "127.0.0.1")
      #expect(!address.hasPrefix("169.254"))
    }
    for address in SystemInfo.localAddresses(.ipv6) {
      #expect(address != "::1")
      #expect(!address.hasPrefix("fe80"))
      // The scope suffix is stripped; leaving it in produces `fe80::1%en0`, which is
      // not a valid address to hand a client.
      #expect(!address.contains("%"))
    }
  }

  @Test("The two families do not bleed into each other")
  func familiesAreSeparate() {
    // A v6 address in `local_ipv4s` would be handed to a client that concatenates it into
    // `http://<address>:1234`, which cannot work without brackets.
    #expect(SystemInfo.localAddresses(.ipv4).allSatisfy { !$0.contains(":") })
    #expect(SystemInfo.localAddresses(.ipv6).allSatisfy { $0.contains(":") })
  }

  // MARK: - iCloud

  @Test("The iCloud account is an address or nil, never a bare identifier")
  func icloudAccountShape() {
    // `AccountID` holds a numeric DSID on some accounts. Reporting that as the user's
    // Apple ID is worse than reporting nothing, which is why the "@" check is kept.
    if let account = SystemInfo.icloudAccount() {
      #expect(account.contains("@"))
    }
  }
}
