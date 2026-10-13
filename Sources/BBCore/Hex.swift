//  Hex
//  Bytes as hexadecimal, in one place.

import Foundation

extension Sequence where Element == UInt8 {
  /// Two hexadecimal digits per byte, lowercase unless asked otherwise. What a digest, a
  /// fingerprint or a random token is written as; five sites each formatted it by hand.
  public func hexString(uppercase: Bool = false) -> String {
    let digits = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
    var result = ""
    result.reserveCapacity(underestimatedCount * 2)
    for byte in self {
      result.append(digits[Int(byte >> 4)])
      result.append(digits[Int(byte & 0x0F)])
    }
    return result
  }
}
