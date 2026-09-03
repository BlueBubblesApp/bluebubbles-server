//  MachineIdentity
//  A stable identifier for this Mac, derived rather than stored.

import Foundation
import IOKit

public enum MachineIdentity {

  /// The Mac's `IOPlatformUUID`: the same value for the life of the machine, and different
  /// on every machine.
  ///
  /// Read straight from the IO registry — no entitlement, no privacy prompt, and no file to
  /// keep. It is the identifier Apple's own software uses when it needs to mean "this Mac",
  /// which is exactly the question being asked of it here.
  ///
  /// Nil if the registry entry cannot be read, which should not happen on a real Mac but is
  /// not worth crashing over. Callers fall back rather than assume.
  public static var platformUUID: String? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard
      let value = IORegistryEntryCreateCFProperty(
        service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
      )?.takeRetainedValue() as? String, !value.isEmpty
    else { return nil }
    return value
  }

  /// Something stable to identify this machine by, whatever is available.
  ///
  /// The host name is a poor second — a user can change it — but it is stable in practice
  /// and better than having no answer at all for a caller that needs a consistent one.
  public static var stableSeed: String {
    platformUUID ?? ProcessInfo.processInfo.hostName
  }
}
