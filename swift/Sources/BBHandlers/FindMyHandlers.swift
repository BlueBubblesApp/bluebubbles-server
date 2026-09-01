//  FindMyHandlers
//  Controllers for FindMy — the four inherited routes and the additive ones.
//
//  Split out of `SystemHandlers` once FindMy stopped being "read a cache file" and became a
//  surface of its own: status, two kinds of refresh, a share request, and sharing control.
//
//  THREE THINGS SHAPE EVERY HANDLER HERE
//
//  1. THE WIRE FORMAT OF `friends` IS FROZEN. `GET icloud/findmy/friends` and its refresh
//     answer with the previous server's `FindMyLocationItem` shape — `coordinates` as a
//     two-element array, `last_updated` in milliseconds, `is_locating_in_progress` as 0/1,
//     `status` as one of three strings. It reads as inconsistent because it is; it is also
//     what shipped, and clients switch on those exact spellings. The ADDITIVE routes use the
//     contract's own naming, because nothing is bound to them yet.
//
//  2. RATE LIMITING IS GLOBAL. Every refresh reaches Apple, and Apple counts this server as
//     one FindMy client however many phones are talking to it. See `IntervalGate`.
//
//  3. A REFUSAL EXPLAINS ITSELF. When a feature flag is off, the answer says which flag and
//     why — the flag's own `rationale`, so the settings screen and the error cannot drift
//     apart.

import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSettings
import BBSystem
import Foundation

public enum FindMyHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding & PrivateAPIProviding & SettingsProviding
  ) {
    registerDevices(into: &registry, context: context)
    registerFriends(into: &registry, context: context)
    registerStatus(into: &registry, context: context)
    registerSharing(into: &registry, context: context)
  }

  // MARK: - Devices (no helper needed)

  private static func registerDevices(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding & PrivateAPIProviding & SettingsProviding
  ) {
    registry.register("findmy.devices") { _ in
      // `null`, not an error, when the cache cannot be read as JSON.
      //
      // Apple ENCRYPTED this cache in Sequoia: `Devices.data` is now a binary plist
      // holding `signature` and `encryptedData`, so parsing it as JSON fails on every
      // modern macOS. The reference does not even try — it returns null outright above
      // Sequoia — and this route was answering 500 with a raw `NSCocoaErrorDomain`
      // string, which reads to a client as a broken server rather than an unavailable
      // feature. Measured on macOS 26.5.2 against a live Electron server, which
      // answers 200 with `data: null`.
      //
      // Version-gated the way the reference is, with a parse fallback behind it: a
      // restored Mac can carry an old plaintext cache, and the format is Apple's to
      // change back.
      //
      // Returned unparsed on purpose where it IS readable. The shape is Apple's, it
      // changes between releases, and clients already read it — modelling it here would
      // mean a server release every time Apple adds a field.
      guard !FindMy.cacheIsEncrypted else { return .data(.null) }
      guard let data = try? FindMy.read(.devices),
        let parsed = try? JSONValue.parse(data)
      else {
        return .data(.null)
      }
      return .data(parsed)
    }
  }

  // MARK: - Friends

  private static func registerFriends(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding & PrivateAPIProviding & SettingsProviding
  ) {

    registry.register("findmy.friends") { _ in
      // Served from the cache rather than from disk: there IS no friends file. See
      // `FindMyFriendsCache` for the mistake this replaced.
      .data(.array(await context.findMyFriends.all.map(legacyPayload)))
    }

    registry.register("findmy.refreshFriends") { _ in
      let api = try await requirePrivateAPI(context, for: "refreshing FindMy friends")

      // Gated GLOBALLY, not per client.
      //
      // This is the route that reaches Apple: the helper asks IMCore, which asks
      // Apple's FindMy service, and as far as Apple is concerned this server is an
      // ordinary FindMy client. Several clients are connected at once by design — a
      // phone and two desktops is the normal install — so a per-client limit would
      // multiply the request rate by the client count, which is exactly the pressure
      // that gets a client throttled at the far end.
      //
      // Refused politely: the cached positions come back with `refreshed: false` and
      // how long until the next refresh is allowed. An error would make clients retry,
      // which is the opposite of what a rate limit wants.
      switch await context.findMyRefreshGate.attempt() {
      case .allowed:
        let friends = try await api.refreshFindMyFriends()
        await context.findMyFriends.merge(friends)
        return .data(
          .array(await context.findMyFriends.all.map(legacyPayload)),
          metadata: .object(["refreshed": .bool(true)])
        )

      case .tooSoon(let retryAfter):
        return .data(
          .array(await context.findMyFriends.all.map(legacyPayload)),
          metadata: .object([
            "refreshed": .bool(false),
            "retry_after_seconds": .int(Int(retryAfter.seconds.rounded(.up))),
          ])
        )
      }
    }

    // MARK: Additive

    registry.register("findmy.refreshFriend") { request in
      let api = try await requirePrivateAPI(context, for: "refreshing a FindMy location")
      let address = try address(in: request)

      switch await context.findMyHandleRefreshGate.attempt() {
      case .allowed:
        let friend = try await api.refreshFindMyLocation(handle: address)
        await context.findMyFriends.merge(friend)
        return .data(payload(friend), metadata: .object(["refreshed": .bool(true)]))

      case .tooSoon(let retryAfter):
        // The cached entry, not an error — same reasoning as the bulk refresh. A
        // client that just asked gets the position it already had rather than a
        // failure it will retry into the limiter.
        guard let cached = await context.findMyFriends.friend(handle: address) else {
          throw NotFound("No FindMy location is known for \(address) yet")
        }
        return .data(
          payload(cached),
          metadata: .object([
            "refreshed": .bool(false),
            "retry_after_seconds": .int(Int(retryAfter.seconds.rounded(.up))),
          ]))
      }
    }

    registry.register("findmy.requestShare") { request in
      let api = try await requirePrivateAPI(context, for: "requesting a location share")
      let address = try address(in: request)
      try await api.requestFindMyLocationShare(handle: address)
      // No location comes back, and none should: the invite has been sent, and whether
      // it is accepted happens on someone else's device, minutes or days later. Saying
      // "shared" here would be a claim this server cannot make.
      return .data(
        .object([
          "requested": .bool(true),
          "address": .string(address),
        ]))
    }
  }

  // MARK: - Status

  private static func registerStatus(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding & PrivateAPIProviding & SettingsProviding
  ) {
    registry.register("findmy.status") { _ in
      let features = await context.settings.featureStates()

      // The helper is asked for FindMy's own state, but its absence is reported rather
      // than raised. This is the call a client makes to decide whether to show FindMy
      // at all, so it has to answer when the helper is disconnected — that is one of
      // the answers.
      let status: FindMyStatus
      if let api = await context.privateAPIClient() {
        status = (try? await api.findMyStatus()) ?? .unavailable
      } else {
        status = .unavailable
      }

      return .data(
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
          // previous server's response in both directions — an added key fails that
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
        ]))
    }
  }

  // MARK: - Sharing

  private static func registerSharing(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding & PrivateAPIProviding & SettingsProviding
  ) {

    registry.register("findmy.startSharing") { request in
      // Checked in the handler as well as at registration. The route only mounts when
      // the flag is on, so this is belt and braces — but a handler that assumes its
      // route's gate is the only gate is one refactor away from being reachable, and
      // this particular one transmits someone's home address.
      try await requireFeature(Features.findMyLocationSharing, context)
      let api = try await requirePrivateAPI(context, for: "sharing a FindMy location")

      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")
      let rawDuration = values["duration"]?.stringValue ?? FindMyShareDuration.oneHour.rawValue
      guard let duration = FindMyShareDuration(rawValue: rawDuration) else {
        throw BadRequest(
          "`duration` must be one of "
            + FindMyShareDuration.allCases.map(\.rawValue).joined(separator: ", ")
        )
      }

      try await api.startSharingFindMyLocation(
        FindMyShareRequest(
          chat: ChatGUID(chatGUID),
          address: values["address"]?.stringValue,
          duration: duration
        )
      )
      return .data(
        .object([
          "sharing": .bool(true),
          "duration": .string(duration.rawValue),
        ]))
    }

    registry.register("findmy.stopSharing") { request in
      try await requireFeature(Features.findMyLocationSharing, context)
      let api = try await requirePrivateAPI(context, for: "stopping a FindMy share")

      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")
      try await api.stopSharingFindMyLocation(
        chat: ChatGUID(chatGUID), address: values["address"]?.stringValue
      )
      return .data(.object(["sharing": .bool(false)]))
    }
  }

  // MARK: - Payloads

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
  private static func legacyPayload(_ friend: FindMyFriend) -> JSONValue {
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
        location?.lastUpdated.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
      ),
      "is_locating_in_progress": .int((location?.isLocatingInProgress ?? false) ? 1 : 0),
      "status": .string(legacyStatus(location?.status)),
    ])
  }

  /// `unknown` has no legacy spelling. Reported as `shallow`, which is what the previous
  /// server calls "we have a position and cannot vouch for how it was obtained" — the
  /// closest true statement, and the one that does not make a client treat a real fix as a
  /// precise one.
  private static func legacyStatus(_ status: FindMyLocationStatus?) -> String {
    switch status {
    case .legacy: "legacy"
    case .live: "live"
    default: "shallow"
    }
  }

  /// The additive routes' shape: the contract's own field names, nothing inherited.
  private static func payload(_ friend: FindMyFriend) -> JSONValue {
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
      place["last_updated"] = .int(Int((updated.timeIntervalSince1970 * 1000).rounded()))
    }

    fields["location"] = .object(place)
    return .object(fields)
  }

  // MARK: - Shared

  private static func address(in request: APIRequestContext) throws -> String {
    let values = try request.values()
    let address = try values.requireString("address")
    return address
  }

  /// Refuses with the flag's own reason.
  ///
  /// 403 rather than 404: the route exists and the caller is not allowed to use it yet,
  /// which is a different thing from a path that is not there. A client can tell the user
  /// what to turn on, and the text it shows is the same text the settings screen shows.
  private static func requireFeature(
    _ flag: FeatureFlag, _ context: some FindMyProviding & PrivateAPIProviding & SettingsProviding
  ) async throws {
    guard await context.settings.isEnabled(flag) else {
      throw Forbidden(
        "\(flag.summary) is disabled on this server. \(flag.rationale) "
          + "Enable `\(flag.key)` in the server settings to use it."
      )
    }
  }

  private static func requirePrivateAPI(
    _ context: some FindMyProviding & PrivateAPIProviding & SettingsProviding,
    for feature: String
  ) async throws -> any PrivateAPI {
    guard let api = await context.privateAPIClient() else {
      throw IMessageError(
        IMessageError.helperUnavailable().errorMessage,
        data: .object(["feature": .string(feature)])
      )
    }
    return api
  }
}
