//  DeviceRowSummaryTests
//  What the Devices page says about when a device was last heard from.
//
//  "Never connected" rather than a formatted epoch zero. A device that registered and never
//  came back is the interesting case on this page, and 1 January 1970 obscures it — which is
//  exactly what a nil-coalescing default would have produced.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAuth
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Device row summary")
struct DeviceRowSummaryTests {

  /// Decoded rather than initialised: `EnrolledDevice`'s memberwise init is internal to
  /// BBAuth, and widening a library's public surface for a test is the wrong trade.
  private func device(lastSeenAt: Date?) throws -> EnrolledDevice {
    let enrolled = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate
    let seen = lastSeenAt.map { "\"lastSeenAt\": \($0.timeIntervalSinceReferenceDate)," } ?? ""
    let json = """
      {
        "id": {"rawValue": "device-1"},
        "clientId": "client-1",
        "secret": {"salt": "", "hash": ""},
        "name": "A phone",
        "platform": "ios",
        "scopes": [],
        "supportedCodecs": [],
        "isRevoked": false,
        \(seen)
        "enrolledAt": \(enrolled)
      }
      """
    return try JSONDecoder().decode(EnrolledDevice.self, from: Data(json.utf8))
  }

  @Test("A device that has never connected says so, rather than showing the epoch")
  func neverConnected() throws {
    let fresh = try device(lastSeenAt: nil)
    #expect(DeviceRowSummary.hasNeverConnected(fresh))
    #expect(DeviceRowSummary.lastSeen(fresh) == "Never connected")
    // The failure this guards: a `?? Date(timeIntervalSince1970: 0)` default.
    #expect(!DeviceRowSummary.lastSeen(fresh).contains("1970"))
  }

  @Test("A device that has connected is described relative to now")
  func hasConnected() throws {
    let seen = try device(lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(!DeviceRowSummary.hasNeverConnected(seen))
    #expect(DeviceRowSummary.lastSeen(seen).hasPrefix("Last seen "))
  }
}
