//  ServerInfoParityTests
//  `GET /api/v1/server/info` reports exactly what the Node server reports.
//
//  This route is the first thing every client calls and the basis for what UI it offers, so a
//  missing field is felt immediately. Five of the eleven were absent and two more were
//  hardcoded `null`, while an invented `message_access` had been added — and nothing caught
//  any of it, because the response was a dictionary literal inside a handler with nothing to
//  compare it against.
//
//  The comparison set below is transcribed INDEPENDENTLY from Node's `ServerMetadataResponse`
//  rather than derived from our own code, which is what stops this from being a tautology:
//  drift on either side fails it.
//
//  The contract is strict in BOTH directions, so this is set equality. An added key fails
//  exactly as a missing one does — an extra field is a client parsing something no Node server
//  sends, which is how a "compatible" server drifts into needing its own client.
//
//  See `.claude/docs/decisions.md` and § 14.

import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("server/info parity")
struct ServerInfoParityTests {

  /// From `ServerMetadataResponse` in `packages/server/src/server/types.ts`, filled in by
  /// `GeneralInterface.getServerMetadata`. Frozen: changing this set is a client-visible API
  /// change, not a refactor.
  static let nodeFields: Set<String> = [
    "computer_id",
    "os_version",
    "server_version",
    "private_api",
    "proxy_service",
    "helper_connected",
    "detected_icloud",
    "detected_imessage",
    "macos_time_sync",
    "local_ipv4s",
    "local_ipv6s",
  ]

  /// Everything unknown, which is the shape a freshly-installed server actually reports.
  private func unknownEverything() -> ServerInfoResponse {
    ServerInfoResponse(
      computerIdentifier: "user@host",
      osVersion: "Version 14.0",
      serverVersion: "0.0.0-test",
      privateAPIEnabled: false,
      proxyService: "dynamic-dns",
      helperConnected: false
    )
  }

  @Test("The field set is exactly Node's")
  func fieldSetMatchesNode() {
    let ours = Set(unknownEverything().fields().keys)
    #expect(
      ours == Self.nodeFields,
      """
      server/info drifted from the Node contract.
        missing: \(Self.nodeFields.subtracting(ours).sorted())
        added:   \(ours.subtracting(Self.nodeFields).sorted())
      """
    )
  }

  @Test("Unknown values are null, never absent")
  func unknownFieldsAreNull() {
    // Absent and null are different answers to a client: `undefined` reads as "this
    // server is too old to tell me", `null` as "there is no iCloud account". The fixture
    // harness asserts key presence for exactly this reason.
    let fields = unknownEverything().fields()
    for key in ["detected_icloud", "detected_imessage", "macos_time_sync"] {
      #expect(fields[key] == .null, "\(key) should be null when unknown")
    }
  }

  @Test("Address lists are arrays even when empty")
  func addressListsAreAlwaysArrays() {
    // A host with no routable IPv6 is ordinary. Null there breaks every client that
    // iterates the list without a guard.
    let fields = unknownEverything().fields()
    #expect(fields["local_ipv4s"]?.arrayValue == [])
    #expect(fields["local_ipv6s"]?.arrayValue == [])
  }

  @Test("Populated values are carried through with their wire types")
  func populatedValues() {
    let response = ServerInfoResponse(
      computerIdentifier: "zach@mac",
      osVersion: "Version 26.5.2",
      serverVersion: "1.2.3",
      privateAPIEnabled: true,
      proxyService: "cloudflare",
      helperConnected: true,
      icloudAccount: "someone@example.com",
      iMessageAccount: "someone@example.com",
      timeSync: 0.007475,
      localIPv4: ["192.168.1.2"],
      localIPv6: ["2001:db8::1"]
    )
    let fields = response.fields()

    #expect(fields["computer_id"]?.stringValue == "zach@mac")
    #expect(fields["private_api"]?.boolValue == true)
    #expect(fields["helper_connected"]?.boolValue == true)
    #expect(fields["detected_icloud"]?.stringValue == "someone@example.com")
    #expect(fields["local_ipv4s"]?.arrayValue?.count == 1)
    // A number, not a string. Clients compare it against a threshold to warn about clock
    // drift, and a string would make every comparison a silent no-op.
    #expect(fields["macos_time_sync"] == .double(0.007475))
  }
}
