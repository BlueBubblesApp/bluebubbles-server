//  SystemHandlers
//  Controllers for the machine itself and the account.
//
//  FindMy is NOT here. It is a surface of its own — status, two refreshes, a share request,
//  sharing control — in `FindMyHandlers`.

import BBDiagnostics
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

public enum SystemHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some ApplicationRestarting & PrivateAPIProviding,
    logSink: FileSink?
  ) {
    registerMac(into: &registry, context: context)
    registerAccount(into: &registry, context: context)
    registerLogs(into: &registry, context: context, logSink: logSink)
  }

  // MARK: - The machine

  private static func registerMac(
    into registry: inout HandlerRegistry,
    context: some ApplicationRestarting & PrivateAPIProviding
  ) {
    registry.register(.macLock) { _ in
      try await ScreenLock.lock()
      return .data(nil)
    }

    // Answered first, THEN restarted — see `ApplicationRestartCoordinator.scheduleRestart`.
    // The restart goes through the injector so the Private API helper comes back with the
    // app; a plain relaunch would silently drop it.
    registry.register(.macRestartMessages) { _ in
      await context.applicationRestart().scheduleRestart(.messages)
      // The inherited route answers with no data — asserted by the parity harness.
      return .data(nil)
    }

    // FaceTime's counterpart. Same rule about injection — restarting FaceTime.app without
    // its helper leaves the FaceTime routes reporting no helper.
    registry.register(.facetimeRestart) { _ in
      await context.applicationRestart().scheduleRestart(.faceTime)
      return .data(.object(["restarting": .bool(true)]))
    }
  }

  // MARK: - Account

  /// The contact card on the wire, for both versions.
  ///
  /// Shared so the avatar is read one way. The **v1 shape is frozen** at the reference's two
  /// keys — see `ContactCardWireShapeTests` and
  /// `Fixtures/http/get_api_v1_icloud_contact-5baa61-200.json` — and the differences are not
  /// cosmetic:
  ///
  /// - v1 OMITS a key it has no value for; v2 emits `null`. The reference builds its object
  ///   by assignment and deletes `avatar_path`, so a card with no photo simply has no
  ///   `avatar` key, and a client checking `"avatar" in data` would break if one appeared.
  /// - v1 cannot say whether a card was shared at all. A person who shared nothing and a
  ///   person who shared an empty card both reduce to `{}`. That is what `v2` adds.
  ///
  /// The avatar is read HERE rather than in the helper, matching the reference: the helper
  /// reports a path, the server reads the bytes. An unreadable path omits the key rather
  /// than failing the request — the name is still worth returning, and a photo can be
  /// referenced before it has been downloaded.
  static func contactCardPayload(
    _ card: NicknameInfo, includingExtendedKeys extended: Bool
  ) -> [String: JSONValue] {
    var avatar: JSONValue?
    if let path = card.avatarPath, let bytes = FileManager.default.contents(atPath: path) {
      avatar = .string(bytes.base64EncodedString())
    }

    guard extended else {
      var data: [String: JSONValue] = [:]
      if let name = card.name { data["name"] = .string(name) }
      if let avatar { data["avatar"] = avatar }
      return data
    }

    return [
      "handle": card.handle.map(JSONValue.string) ?? .null,
      "name": card.name.map(JSONValue.string) ?? .null,
      "has_shared_nickname": .bool(card.hasSharedNickname),
      "avatar": avatar ?? .null,
    ]
  }

  private static func registerAccount(
    into registry: inout HandlerRegistry,
    context: some ApplicationRestarting & PrivateAPIProviding
  ) {
    registry.register(.icloudAccountInfo) { _ in
      let api = try await context.requirePrivateAPI(for: "reading account information")
      let info = try await api.accountInfo()
      return .data(
        .object([
          "apple_id": info.appleId.map(JSONValue.string) ?? .null,
          "active_alias": info.activeAlias.map(JSONValue.string) ?? .null,
          "aliases": .array(info.aliases.map(JSONValue.string)),
          "vetted_aliases": .array(info.vettedAliases.map(JSONValue.string)),
        ]))
    }

    // The local user's own shared contact card, or another handle's when `address` is given.
    //
    // THE RESPONSE SHAPE IS FIXED BY THE REFERENCE SERVER, and it is narrower than
    // `NicknameInfo`. `Fixtures/http/get_api_v1_icloud_contact-5baa61-200.json` records
    // exactly two keys:
    //
    //     "data": { "name": "…", "avatar": "…" }
    //
    // So `handle` and `hasSharedNickname` are deliberately NOT emitted, even though the
    // helper reports them — a v1 response with extra keys is a parity failure exactly like
    // one with missing keys. They stay on the contract because the socket layer and future
    // v2 surface can use them.
    registry.register(.icloudContactCard) { request in
      let api = try await context.requirePrivateAPI(for: "reading a contact card")
      // Absent means the local user's own card. The reference takes it from the query
      // string and passes undefined straight through, so an empty value is the default
      // rather than an error.
      let address = request.queryParameters["address"].flatMap {
        $0.isEmpty ? nil : $0
      }
      let card = try await api.nicknameInfo(for: address)
      return .data(.object(contactCardPayload(card, includingExtendedKeys: false)))
    }

    // The v2 shape: everything `NicknameInfo` carries.
    //
    // `hasSharedNickname` is the key v1 cannot express. A person who shared a card with no
    // name and no photo, and a person who shared nothing at all, both reduce to an empty
    // `data` object in v1; here they differ.
    registry.register(.icloudContactCardV2) { request in
      let api = try await context.requirePrivateAPI(for: "reading a contact card")
      let address = request.queryParameters["address"].flatMap { $0.isEmpty ? nil : $0 }
      let card = try await api.nicknameInfo(for: address)
      return .data(.object(contactCardPayload(card, includingExtendedKeys: true)))
    }

    registry.register(.icloudChangeAlias) { request in
      let api = try await context.requirePrivateAPI(for: "changing the active alias")
      let values = try request.values()
      let alias = try values.requireString("alias")
      // Checked against the vetted list first. IMCore accepts an unvetted alias and
      // then silently keeps sending from the old one, which looks like the server
      // ignored the request.
      let info = try await api.accountInfo()
      guard info.aliases.contains(alias) || info.vettedAliases.contains(alias) else {
        throw BadRequest(
          "`\(alias)` is not one of this account's aliases"
        )
      }
      try await api.modifyActiveAlias(alias)
      return .data(nil)
    }
  }

  // MARK: - Logs

  private static func registerLogs(
    into registry: inout HandlerRegistry,
    context: some ApplicationRestarting & PrivateAPIProviding,
    logSink: FileSink?
  ) {
    registry.register(.serverLogs) { request in
      guard let logSink else {
        throw ServiceUnavailable("this server is not writing to a log file")
      }
      // Capped. The log rotates at 10 MB and a client asking for "everything" would
      // otherwise pull all of it through the JSON encoder in one response.
      let count = min(request.integer("count") ?? 100, 10_000)
      return .data(.array(logSink.tail(lines: count).map(JSONValue.string)))
    }
  }

}
