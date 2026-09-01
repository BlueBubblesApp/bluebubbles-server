//  ServerInfoResponse
//  The `GET /api/v1/server/info` payload, as a value rather than a dictionary literal.
//
//  This is the first route every client calls and what it branches on to decide which
//  features to offer, so its field set IS an API. As an inline `[String: JSONValue]` inside a
//  handler it was neither reviewable nor testable: five of the eleven fields Node sends were
//  missing, two more were hardcoded `null`, and an invented `message_access` had been added —
//  none of which anything could have caught, because there was nothing to compare against.
//
//  Modelling it makes the contract a thing that exists. `ServerInfoParityTests` builds one of
//  these and asserts its keys equal an independent transcription of Node's
//  `ServerMetadataResponse`, which needs no server, no database and no network.
//
//  See `.claude/docs/decisions.md` and § 14.

import BBSerialization
import Foundation

public struct ServerInfoResponse: Sendable, Equatable {

  public var computerIdentifier: String
  public var osVersion: String
  public var serverVersion: String
  public var privateAPIEnabled: Bool
  public var proxyService: String
  public var helperConnected: Bool
  public var icloudAccount: String?
  public var iMessageAccount: String?
  public var timeSync: Double?
  public var localIPv4: [String]
  public var localIPv6: [String]

  public init(
    computerIdentifier: String,
    osVersion: String,
    serverVersion: String,
    privateAPIEnabled: Bool,
    proxyService: String,
    helperConnected: Bool,
    icloudAccount: String? = nil,
    iMessageAccount: String? = nil,
    timeSync: Double? = nil,
    localIPv4: [String] = [],
    localIPv6: [String] = []
  ) {
    self.computerIdentifier = computerIdentifier
    self.osVersion = osVersion
    self.serverVersion = serverVersion
    self.privateAPIEnabled = privateAPIEnabled
    self.proxyService = proxyService
    self.helperConnected = helperConnected
    self.icloudAccount = icloudAccount
    self.iMessageAccount = iMessageAccount
    self.timeSync = timeSync
    self.localIPv4 = localIPv4
    self.localIPv6 = localIPv6
  }

  /// The wire shape.
  ///
  /// Note what is NOT conditional: a field whose value is unknown is emitted as `null`, never
  /// omitted. To a client those are different answers — `undefined` reads as "this server is
  /// too old to tell me" and `null` as "there is no iCloud account" — and the fixture harness
  /// asserts key presence for exactly that reason.
  public func json() -> JSONValue { .object(fields()) }

  /// The fields, keyed. Exposed separately because the one thing allowed to extend this
  /// response — the codec advertisement, and only when a non-legacy codec is enabled —
  /// merges into it, and unwrapping a `.object` back out to do that would be silly.
  public func fields() -> [String: JSONValue] {
    [
      "computer_id": .string(computerIdentifier),
      "os_version": .string(osVersion),
      "server_version": .string(serverVersion),
      "private_api": .bool(privateAPIEnabled),
      "proxy_service": .string(proxyService),
      "helper_connected": .bool(helperConnected),
      "detected_icloud": icloudAccount.map(JSONValue.string) ?? .null,
      "detected_imessage": iMessageAccount.map(JSONValue.string) ?? .null,
      "macos_time_sync": timeSync.map(JSONValue.double) ?? .null,
      // Always arrays. A host with no routable IPv6 is ordinary, and returning null
      // there breaks every client that iterates the list without a guard.
      "local_ipv4s": .array(localIPv4.map(JSONValue.string)),
      "local_ipv6s": .array(localIPv6.map(JSONValue.string)),
    ]
  }
}
