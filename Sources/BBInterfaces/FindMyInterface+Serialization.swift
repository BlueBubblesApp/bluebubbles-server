//  FindMyInterface+Serialization
//  The FindMy routes' wire shapes, and the device cache they read.
//
//  THE WIRE FORMAT OF `friends` IS FROZEN. `GET icloud/findmy/friends` and its refresh answer
//  with the previous server's `FindMyLocationItem` shape (`legacyPayload`); the additive
//  routes use the contract's own naming (`payload`), because nothing is bound to them yet.
//
//  Here rather than in the handlers so the app and the tests reach the projection the routes
//  send, and so a handler stays parse, call, serialize.

import BBCore
import BBPrivateAPIContract
import BBSettings
import BBSystem
import Foundation

extension FindMyInterface {

  // MARK: - Devices

  /// The device cache as both device routes answer it: parsed where it is readable, and
  /// `null` where it is encrypted, absent, unreadable or not JSON.
  ///
  /// Version-gated before the read, the way the reference is, because an encrypted cache
  /// is a binary plist and a parse of it fails with an `NSCocoaErrorDomain` string that a
  /// client reads as a broken server. The parameters exist for the tests.
  public static func cachedDevices(
    encrypted: Bool = FindMy.cacheIsEncrypted,
    read: () throws -> Data = { try FindMy.read(.devices) }
  ) -> JSONValue {
    guard !encrypted else { return .null }
    guard let data = try? read(), let parsed = try? JSONValue.parse(data) else { return .null }
    return parsed
  }

  /// When FindMy last wrote its device cache, or nil when it cannot be read.
  ///
  /// There is no way to make FindMy refresh that cache from outside the app, so the refresh
  /// route reports how old it is instead, and a client can tell a stale answer from a fresh
  /// one. `try?` because an unreadable cache is reported as no date, which is the answer.
  public static func devicesCachedAt() -> Date? {
    try? FileManager.default.attributesOfItem(
      atPath: FindMy.cacheDirectory.appendingPathComponent(FindMy.Cache.devices.rawValue).path
    )[.modificationDate] as? Date
  }

  // MARK: - Friends

  /// The previous server's `FindMyLocationItem`, field for field.
  ///
  /// Kept exactly, including the parts that look wrong: `coordinates` is a bare
  /// `[latitude, longitude]` array rather than a named pair, `is_locating_in_progress` is
  /// 0/1 rather than a boolean, and the keys are snake_case where the rest of this API is
  /// camelCase. Clients read these spellings, so they are the contract.
  ///
  /// A friend with no fix still appears, with `[0, 0]`. That is the previous server's
  /// behaviour and it is load-bearing in the other direction: dropping the entry would hide
  /// someone who IS sharing but has not been located yet.
  public static func legacyPayload(_ friend: FindMyFriend) -> JSONValue {
    let location = friend.location
    return .object([
      "handle": .string(friend.handle),
      "coordinates": .array([
        .double(location?.latitude ?? 0),
        .double(location?.longitude ?? 0),
      ]),
      "long_address": location?.longAddress.map(JSONValue.string) ?? .null,
      "short_address": location?.shortAddress.map(JSONValue.string) ?? .null,
      // `subtitle` and `title` came off `FMFLocation`, which the modern path does not
      // produce. The address label is the closest equivalent and is what a client
      // renders in the same place.
      "subtitle": location?.shortAddress.map(JSONValue.string) ?? .null,
      "title": location?.label.map(JSONValue.string) ?? .null,
      "last_updated": .int(
        location?.lastUpdated.map { Int($0.epochMilliseconds(rounded: .toNearestOrAwayFromZero)) }
          ?? 0
      ),
      "is_locating_in_progress": .int((location?.isLocatingInProgress ?? false) ? 1 : 0),
      "status": .string(legacyStatus(location?.status)),
    ])
  }

  /// `unknown` has no legacy spelling. Reported as `shallow`, which is what the previous
  /// server calls "we have a position and cannot vouch for how it was obtained": the
  /// closest true statement, and the one that does not make a client treat a real fix as a
  /// precise one.
  fileprivate static func legacyStatus(_ status: FindMyLocationStatus?) -> String {
    switch status {
    case .legacy: "legacy"
    case .live: "live"
    default: "shallow"
    }
  }

  /// The additive routes' shape: the contract's own field names, nothing inherited.
  public static func payload(_ friend: FindMyFriend) -> JSONValue {
    var fields: [String: JSONValue] = [
      "handle": .string(friend.handle),
      "is_sharing_with_me": .bool(friend.isSharingWithMe),
      "is_following_my_location": .bool(friend.isFollowingMyLocation),
    ]
    guard let location = friend.location else {
      fields["location"] = .null
      return .object(fields)
    }

    var place: [String: JSONValue] = [
      "is_locating_in_progress": .bool(location.isLocatingInProgress),
      "status": .string(location.status.rawValue),
    ]
    // Omitted rather than nulled when there is no fix. `(0, 0)` is IMCore's way of
    // saying "not located", and a client that reads it as a coordinate drops a pin in
    // the Gulf of Guinea.
    if location.hasCoordinates {
      place["latitude"] = location.latitude.map(JSONValue.double) ?? .null
      place["longitude"] = location.longitude.map(JSONValue.double) ?? .null
    }
    if let accuracy = location.horizontalAccuracy {
      place["horizontal_accuracy"] = .double(accuracy)
    }
    if let altitude = location.altitude { place["altitude"] = .double(altitude) }
    if let short = location.shortAddress { place["short_address"] = .string(short) }
    if let long = location.longAddress { place["long_address"] = .string(long) }
    if let label = location.label { place["label"] = .string(label) }
    if let updated = location.lastUpdated {
      place["last_updated"] = .int(
        Int(updated.epochMilliseconds(rounded: .toNearestOrAwayFromZero)))
    }

    fields["location"] = .object(place)
    return .object(fields)
  }

  /// The `metadata` a gated refresh answers with: `refreshed`, and when it was refused, how
  /// long until the next refresh is allowed. Refused politely rather than as an error, which
  /// would make a client retry straight into the limiter.
  public static func refreshMetadata(retryAfter: Duration?) -> JSONValue {
    guard let retryAfter else { return .object(["refreshed": .bool(true)]) }
    return .object([
      "refreshed": .bool(false),
      "retry_after_seconds": .int(Int(retryAfter.seconds.rounded(.up))),
    ])
  }

  // MARK: - Status

  /// What `findmy/status` answers with: FindMy's own state and every FindMy feature flag,
  /// with the reason each is off.
  public static func statusPayload(
    _ status: FindMyStatus, features: [FeatureFlag: Bool]
  ) -> JSONValue {
    .object([
      "available": .bool(status.isAvailable),
      "provisioned": .bool(status.isProvisioned),
      "restricted": .bool(status.isRestricted),
      "sharing_disabled": .bool(status.isSharingDisabled),
      "backend": .string(status.backend.rawValue),
      "active_device": status.activeDevice.map { device in
        JSONValue.object([
          "name": device.name.map(JSONValue.string) ?? .null,
          // Worth surfacing: when the account's active sharing device is a
          // phone rather than this Mac, a share started here still transmits
          // the phone's position, and a client showing "sharing your Mac's
          // location" would be wrong.
          "is_this_device": .bool(device.isThisDevice),
        ])
      } ?? .null,
      // Reported here rather than in `server/info`, which is diffed against the
      // previous server's response in both directions: an added key fails that
      // check exactly as a missing one does.
      "features": .object(
        Dictionary(
          uniqueKeysWithValues: features.map { flag, enabled in
            (
              flag.id,
              JSONValue.object([
                "enabled": .bool(enabled),
                "summary": .string(flag.summary),
                // The reason, verbatim from the flag. A client can show it as-is
                // when explaining why a control is missing.
                "reason": .string(flag.rationale),
              ])
            )
          })
      ),
    ])
  }
}
