//  IPv4
//  A dotted quad, parsed strictly, in one place.
//
//  Two copies of this parse split on "." with Swift's default, which DROPS empty pieces, so
//  `10.0..0.1` came out as the four pieces of `10.0.0.1`. One of them feeds access control:
//  a typo in a trusted-network rule was accepted as a different network from anything the
//  operator typed. `UInt8(_:)` also takes a leading `+`, which no address has.

import Foundation

public enum IPv4 {

  /// The four bytes of a dotted-quad address, or nil for anything that is not exactly one:
  /// four pieces, none empty, each one to three decimal digits no greater than 255.
  public static func octets(_ address: String) -> [UInt8]? {
    let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 4 else { return nil }
    var octets: [UInt8] = []
    for piece in pieces {
      guard (1...3).contains(piece.count), piece.allSatisfy(\.isASCII),
        piece.allSatisfy(\.isNumber), let octet = UInt8(piece)
      else { return nil }
      octets.append(octet)
    }
    return octets
  }
}
