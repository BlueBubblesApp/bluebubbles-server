//  FindMyHandlers
//  Controllers for FindMy: the four inherited routes and the additive ones.
//
//  Split out of `SystemHandlers` once FindMy stopped being "read a cache file" and became a
//  surface of its own: status, two kinds of refresh, a share request, and sharing control.
//
//  THREE THINGS SHAPE EVERY HANDLER HERE
//
//  1. THE WIRE FORMAT OF `friends` IS FROZEN. `GET icloud/findmy/friends` and its refresh
//     answer with the previous server's `FindMyLocationItem` shape: `coordinates` as a
//     two-element array, `last_updated` in milliseconds, `is_locating_in_progress` as 0/1,
//     `status` as one of three strings. It reads as inconsistent because it is; it is also
//     what shipped, and clients switch on those exact spellings. The ADDITIVE routes use the
//     contract's own naming, because nothing is bound to them yet. Both projections are
//     `FindMyInterface+Serialization`.
//
//  2. RATE LIMITING IS GLOBAL. Every refresh reaches Apple, and Apple counts this server as
//     one FindMy client however many phones are talking to it. See `IntervalGate`.
//
//  3. A REFUSAL EXPLAINS ITSELF. When a feature flag is off, the answer says which flag and
//     why: the flag's own `rationale`, so the settings screen and the error cannot drift
//     apart.

import BBCore
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
    context: some FindMyProviding & SettingsProviding
  ) {
    registerDevices(into: &registry, context: context)
    registerFriends(into: &registry, context: context)
    registerStatus(into: &registry, context: context)
    registerSharing(into: &registry, context: context)
  }

  // MARK: - Devices (no helper needed)

  private static func registerDevices(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding & SettingsProviding
  ) {
    registry.register(.findmyDevices) { _ in
      // `null`, not an error, when the cache cannot be read as JSON.
      //
      // Apple ENCRYPTED this cache in Sequoia: `Devices.data` is now a binary plist
      // holding `signature` and `encryptedData`, so parsing it as JSON fails on every
      // modern macOS. The reference does not even try: it returns null outright above
      // Sequoia, and this route was answering 500 with a raw `NSCocoaErrorDomain`
      // string, which reads to a client as a broken server rather than an unavailable
      // feature. Measured on macOS 26.5.2 against a live Electron server, which
      // answers 200 with `data: null`.
      //
      // Version-gated the way the reference is, with a parse fallback behind it: a
      // restored Mac can carry an old plaintext cache, and the format is Apple's to
      // change back.
      //
      // Returned unparsed on purpose where it IS readable. The shape is Apple's, it
      // changes between releases, and clients already read it: modelling it here would
      // mean a server release every time Apple adds a field.
      .data(FindMyInterface.cachedDevices())
    }

    /// There is no way to make FindMy refresh its device cache from outside the app: the
    /// cache is written by FindMy itself, on its own schedule. Rather than pretend, this
    /// re-reads what is on disk and reports how old it is, so a client can tell a stale
    /// answer from a fresh one instead of trusting a refresh that did nothing.
    ///
    /// The same `null` as the read above where there is nothing readable: the reference's
    /// `refreshDevices` ends in the same `getDevices`, which answers null above Sequoia.
    registry.register(.findmyRefreshDevices) { _ in
      .data(
        FindMyInterface.cachedDevices(),
        metadata: .object([
          "cachedAt": FindMyInterface.devicesCachedAt().map { .int64($0.epochMilliseconds) }
            ?? .null,
          // Stated plainly: the server cannot make FindMy fetch.
          "refreshed": .bool(false),
        ])
      )
    }
  }

  // MARK: - Friends

  private static func registerFriends(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding & SettingsProviding
  ) {

    registry.register(.findmyFriends) { _ in
      .data(.array(await context.findMyInterface().friends().map(FindMyInterface.legacyPayload)))
    }

    // Gated GLOBALLY by the interface, not per client, and refused politely: the cached
    // positions come back with `refreshed: false` and how long until the next refresh is
    // allowed. An error would make clients retry, which is the opposite of what a rate
    // limit wants. See `FindMyInterface`.
    registry.register(.findmyRefreshFriends) { _ in
      switch try await context.findMyInterface().refreshFriends() {
      case .refreshed(let friends):
        return .data(
          .array(friends.map(FindMyInterface.legacyPayload)),
          metadata: FindMyInterface.refreshMetadata(retryAfter: nil)
        )
      case .tooSoon(let friends, let retryAfter):
        return .data(
          .array(friends.map(FindMyInterface.legacyPayload)),
          metadata: FindMyInterface.refreshMetadata(retryAfter: retryAfter)
        )
      }
    }

    // MARK: Additive

    registry.register(.findmyRefreshFriend) { request in
      switch try await context.findMyInterface().refreshLocation(handle: try address(in: request)) {
      case .refreshed(let friend):
        return .data(
          FindMyInterface.payload(friend),
          metadata: FindMyInterface.refreshMetadata(retryAfter: nil))
      case .tooSoon(let cached, let retryAfter):
        return .data(
          FindMyInterface.payload(cached),
          metadata: FindMyInterface.refreshMetadata(retryAfter: retryAfter))
      }
    }

    registry.register(.findmyRequestShare) { request in
      let address = try address(in: request)
      try await context.findMyInterface().requestShare(handle: address)
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
    context: some FindMyProviding & SettingsProviding
  ) {
    registry.register(.findmyStatus) { _ in
      let features = await context.settings.featureStates()
      // The helper's absence is REPORTED, not raised; see `FindMyInterface.status`.
      let status = await context.findMyInterface().status()

      return .data(FindMyInterface.statusPayload(status, features: features))
    }
  }

  // MARK: - Sharing

  private static func registerSharing(
    into registry: inout HandlerRegistry,
    context: some FindMyProviding
  ) {

    // Both routes declare `.findMyLocationSharing` in the table, which is checked on every
    // request as well as at mounting; see `AdditiveRoutes.findMySharingRoutes`.
    registry.register(.findmyStartSharing) { request in
      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")
      let rawDuration = values["duration"]?.stringValue ?? FindMyShareDuration.oneHour.rawValue
      guard let duration = FindMyShareDuration(rawValue: rawDuration) else {
        throw BadRequest(
          "`duration` must be one of "
            + FindMyShareDuration.allCases.map(\.rawValue).joined(separator: ", ")
        )
      }

      try await context.findMyInterface().startSharing(
        FindMyShareRequest(
          chat: ChatIdentifier(chatGUID),
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

    registry.register(.findmyStopSharing) { request in
      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")
      try await context.findMyInterface().stopSharing(
        chat: ChatIdentifier(chatGUID), address: values["address"]?.stringValue
      )
      return .data(.object(["sharing": .bool(false)]))
    }
  }

  // MARK: - Shared

  private static func address(in request: APIRequestContext) throws -> String {
    let values = try request.values()
    let address = try values.requireString("address")
    return address
  }
}
