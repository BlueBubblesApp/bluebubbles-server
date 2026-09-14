//  AccessControlMemoryBoundTests
//  Every map keyed by a client address has a ceiling, not only the one that had one.
//
//  `addressMemoryLimit`'s own comment states the rule: an attacker supplies the keys, and an
//  IPv6 attacker has an effectively unlimited supply of them, so a TTL is not a bound. It was
//  applied to `offenceHistory` alone. `failureTimes` was pruned only by age and `blocked`
//  only by expiry, so a rotating attacker grew both without limit inside a single window —
//  and `AccessControlStore.saveBlocked` rewrites the whole table on every block, justifying
//  that on the blocked set being "small (bounded by `addressMemoryLimit`)", which it was not.
//
//  Evicting a block is a real loss, so what is asserted here is not only the ceiling but the
//  ORDER: temporary before permanent, and a permanent block never. A manual ban must not be
//  something an attacker can flush out by making noise from ten thousand addresses.
//
//  NO REAL ADDRESSES; the documentation ranges (RFC 3849, RFC 5737) are used throughout.

import Foundation
import Logging
import Testing

@testable import BBAuth

@Suite("Access control memory bounds")
struct AccessControlMemoryBoundTests {

  /// A small ceiling, so the limit is reachable without driving ten thousand addresses
  /// through an actor whose prune is linear. The production default is 10,000; what is
  /// under test is the rule, not the number.
  private static let limit = 50

  /// More addresses than the limit, from the IPv6 documentation range.
  private static func addresses(_ count: Int) -> [ClientIdentity] {
    (0..<count).map { .address("2001:db8::\(String($0, radix: 16))") }
  }

  private static func service() -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(
        perClientThreshold: 1, window: .seconds(3600), addressMemoryLimit: limit)
    )
  }

  @Test("A rotating attacker cannot grow the blocked set without limit")
  func blockedIsBounded() async {
    let service = Self.service()
    for identity in Self.addresses(Self.limit + 25) {
      _ = await service.recordFailure(identity, path: "/api/v1/ping", reason: "wrong password")
    }
    let count = await service.blockedClients().count
    #expect(
      count <= Self.limit,
      """
      the blocked set reached \(count) against a limit of \
      \(Self.limit), and every block rewrites the whole table.
      """)
  }

  @Test("A permanent block survives what an attacker can flush")
  func permanentBlocksAreNotEvictable() async {
    let service = Self.service()
    let banned = "203.0.113.7"
    await service.blockPermanently(address: banned, reason: "banned by hand")

    for identity in Self.addresses(Self.limit + 25) {
      _ = await service.recordFailure(identity, path: "/api/v1/ping", reason: "wrong password")
    }
    #expect(
      await service.blockedClients().contains { $0.address == banned },
      "an attacker flushed a manual ban out of the blocked set by making noise")
  }
}
