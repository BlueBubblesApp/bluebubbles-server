//  DeviceRowSummary
//  What the Devices page says about when a device was last heard from.
//
//  "Never connected" rather than a formatted epoch zero. A device that registered and never
//  came back is the interesting case, and 1 January 1970 obscures it — which is exactly what
//  a nil-coalescing default would have produced.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBAuth
import Foundation

enum DeviceRowSummary {

  static func lastSeen(_ device: EnrolledDevice) -> String {
    guard let lastSeenAt = device.lastSeenAt else { return "Never connected" }
    return "Last seen \(lastSeenAt.formatted(.relative(presentation: .named)))"
  }

  /// Whether the row will say "never", which is the branch worth asserting without pinning
  /// the locale's wording of the other one.
  static func hasNeverConnected(_ device: EnrolledDevice) -> Bool {
    device.lastSeenAt == nil
  }
}
