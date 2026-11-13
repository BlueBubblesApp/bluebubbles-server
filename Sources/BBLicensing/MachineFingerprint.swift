//  MachineFingerprint
//  What the token's `machine` claim is compared against.
//
//  A HASH of the machine's identifier, not the identifier. The issuing service has no business
//  holding a registry of real hardware UUIDs for every customer, and a hash answers the only
//  question anybody asks of it — "is this the same Mac as last time" — without one existing.
//
//  Takes the seed as an argument rather than reading `MachineIdentity` itself, so this module
//  stays free of IOKit and so a test can pin the hash without owning a Mac. The composition
//  root supplies `MachineIdentity.stableSeed`.

import BBCore
import Crypto
import Foundation

public enum MachineFingerprint {

  /// Lowercase hex SHA-256. Stable for the life of the machine.
  public static func of(seed: String) -> String {
    SHA256.hash(data: Data(seed.utf8)).hexString()
  }
}
