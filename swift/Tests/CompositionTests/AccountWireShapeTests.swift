//  AccountWireShapeTests
//  `GET /api/v1/icloud/account` against the response the reference actually sent.
//
//  THE BUG THIS EXISTS TO PREVENT
//  This route answered with four keys where the reference sends eight, and two of the four
//  carried the wrong type. `aliases` and `vetted_aliases` went out as arrays of STRINGS; the
//  reference sends arrays of OBJECTS, because the ObjC helper enriched each alias through
//  `[account _aliasInfoForAlias:]` before sending it and `iCloudInterface.getAccountInfo` is
//  `return data.data` — the payload verbatim.
//
//  The app reads `e['Alias']` off every element (`profile_panel.dart:401`), and indexing a
//  Dart string wants an integer, so the profile screen died with
//  `type 'String' is not a subtype of type 'int' of 'index'`. The four missing keys are read
//  by that same screen.
//
//  WHY THE REPLAY DID NOT CATCH IT
//  `get_api_v1_icloud_account-5baa61-200.json` is in `replay-baseline.json` as
//  "HARNESS: needs the Private API helper". The route cannot be replayed in-process, so the
//  fixture sat there recording the right answer while the server sent a different one. This
//  suite reads that same fixture directly and diffs the SHAPE against what the handler builds,
//  which needs no helper and no listener.

import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Account wire shape")
struct AccountWireShapeTests {

  /// The `data` object out of the recorded reference response.
  private static func recorded() throws -> [String: JSONValue] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CompositionTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Fixtures/http/get_api_v1_icloud_account-5baa61-200.json")
    let fixture = try JSONValue.parse(Data(contentsOf: url))
    let body = try #require(fixture["response"]?["body"]?["value"])
    guard case .object(let data)? = body["data"] else {
      throw FixtureError.missingData
    }
    return data
  }

  /// A populated account, in the shape the helper reports one.
  private static let sample = AccountInfo(
    appleId: "someone@example.com",
    accountName: "Someone Example",
    activeAlias: "someone@example.com",
    aliases: [
      AccountAlias(alias: "someone@example.com", status: 3, isUserVisible: true),
      AccountAlias(alias: "+12025550143", status: 3, isUserVisible: true),
    ],
    vettedAliases: [
      AccountAlias(alias: "someone@example.com", status: 3, isUserVisible: true)
    ],
    loginStatusMessage: "Connected",
    smsForwardingEnabled: false,
    smsForwardingCapable: false
  )

  @Test("Every key the reference sends is present")
  func keysMatchTheReference() throws {
    let expected = Set(try Self.recorded().keys)
    let actual = Set(SystemHandlers.accountInfoPayload(Self.sample).keys)

    #expect(
      expected.subtracting(actual).isEmpty,
      """
      Keys the reference sends and this server does not. A MISSING key is the break:

      \(expected.subtracting(actual).sorted().joined(separator: ", "))
      """
    )
    // Reported rather than failed: an extra key is tolerable by the project's own rule,
    // and this route has none today.
    #expect(
      actual.subtracting(expected).isEmpty,
      "keys we add: \(actual.subtracting(expected).sorted().joined(separator: ", "))")
  }

  @Test("Each key carries the same TYPE the reference used")
  func typesMatchTheReference() throws {
    let expected = try Self.recorded()
    let actual = SystemHandlers.accountInfoPayload(Self.sample)
    var wrong: [String] = []

    for (key, reference) in expected {
      guard let ours = actual[key] else { continue }
      if Self.kind(of: ours) != Self.kind(of: reference) {
        wrong.append("\(key): reference \(Self.kind(of: reference)), ours \(Self.kind(of: ours))")
      }
    }

    #expect(wrong.isEmpty, "\(wrong.sorted().joined(separator: "\n"))")
  }

  @Test("Aliases are objects carrying `Alias`, which is what the app indexes")
  func aliasesAreObjects() throws {
    let payload = SystemHandlers.accountInfoPayload(Self.sample)

    for key in ["aliases", "vetted_aliases"] {
      let entries = try #require(payload[key]?.arrayValue, "\(key) must be an array")
      #expect(!entries.isEmpty, "\(key) should carry the sample's aliases")
      for entry in entries {
        // The whole bug in one assertion: a string here is a client crash.
        #expect(entry.stringValue == nil, "\(key) elements must be objects, not strings")
        let alias = try #require(entry["Alias"]?.stringValue, "\(key) element needs `Alias`")
        #expect(!alias.isEmpty)
        #expect(entry["Status"]?.intValue == 3)
        #expect(entry["IsUserVisible"]?.boolValue == true)
      }
    }
  }

  @Test("An alias IMCore would not describe still reaches the client under `Alias`")
  func undescribedAliasKeepsItsKey() throws {
    // The helper's own fallback: `_aliasInfoForAlias:` answered nil, so it sent
    // `{"Alias": <string>}` and nothing else. The key the app reads has to survive that.
    let sparse = AccountInfo(
      appleId: nil, accountName: nil, activeAlias: nil,
      aliases: [AccountAlias(alias: "someone@example.com")],
      vettedAliases: [], loginStatusMessage: nil
    )
    let entry = try #require(
      SystemHandlers.accountInfoPayload(sparse)["aliases"]?.arrayValue?.first)
    #expect(entry["Alias"]?.stringValue == "someone@example.com")
    // Omitted, not nulled: the reference's dictionary simply has no such key here.
    #expect(entry["Status"] == nil)
    #expect(entry["IsUserVisible"] == nil)
  }

  @Test("A signed-out account still answers with every key")
  func emptyAccountKeepsTheShape() throws {
    // `null` for the strings and `false` for the flags, which is what the ObjC helper's
    // `?: [NSNull null]` and `?: FALSE` produced. The app renders the nulls; an absent key
    // is what it cannot survive.
    let empty = AccountInfo(
      appleId: nil, accountName: nil, activeAlias: nil,
      aliases: [], vettedAliases: [], loginStatusMessage: nil
    )
    let payload = SystemHandlers.accountInfoPayload(empty)

    #expect(Set(payload.keys) == Set(try Self.recorded().keys))
    #expect(payload["apple_id"] == .null)
    #expect(payload["account_name"] == .null)
    #expect(payload["login_status_message"] == .null)
    #expect(payload["sms_forwarding_enabled"] == .bool(false))
    #expect(payload["sms_forwarding_capable"] == .bool(false))
    #expect(payload["aliases"] == .array([]))
  }

  // MARK: - Helpers

  private enum FixtureError: Error { case missingData }

  private static func kind(of value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool: "bool"
    case .int, .int64, .double: "number"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    }
  }
}
