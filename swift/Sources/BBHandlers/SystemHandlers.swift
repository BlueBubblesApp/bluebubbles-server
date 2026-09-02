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
    context: some LoggerProviding & PrivateAPIProviding & PrivateAPIRuntimeProviding,
    logSink: FileSink?
  ) {
    registerMac(into: &registry, context: context)
    registerAccount(into: &registry, context: context)
    registerLogs(into: &registry, context: context, logSink: logSink)
  }

  // MARK: - The machine

  private static func registerMac(
    into registry: inout HandlerRegistry,
    context: some LoggerProviding & PrivateAPIProviding & PrivateAPIRuntimeProviding
  ) {
    registry.register(.macLock) { _ in
      try await ScreenLock.lock()
      return .data(nil)
    }

    registry.register(.macRestartMessages) { _ in
      scheduleRestart(
        applicationName: "Messages",
        bundleIdentifier: HelperHost.messages,
        context: context
      )
      // The inherited route answers with no data — asserted by the parity harness.
      return .data(nil)
    }

    // FaceTime's counterpart. Same rule about injection — restarting FaceTime.app without
    // its helper leaves the FaceTime routes reporting no helper.
    registry.register(.facetimeRestart) { _ in
      scheduleRestart(
        applicationName: "FaceTime",
        bundleIdentifier: HelperHost.faceTime,
        context: context
      )
      return .data(.object(["restarting": .bool(true)]))
    }
  }

  /// Restarts a managed app, PRESERVING the Private API helper.
  ///
  /// A plain quit-and-relaunch silently disables the Private API: the app comes back
  /// looking perfectly healthy while dyld never inserted the helper, so every Private API
  /// route starts reporting the helper as unavailable and nothing says why. When the server manages injection, the restart goes THROUGH the
  /// injector, which relaunches with `DYLD_INSERT_LIBRARIES` and waits for the helper to
  /// register before reporting success.
  ///
  /// Falls back to a plain restart when injection is not managed here — the Private API is
  /// off, or the helper was installed by other means — because in that case relaunching
  /// normally is exactly right.
  /// Answers the request, THEN restarts — the same shape as `server.restartServices`.
  ///
  /// Restarting through the injector is slow and unbounded from a client's point of view:
  /// it quits the app (waiting up to ten seconds for it to exit), relaunches it, waits for
  /// the helper to register, and RETRIES several times before giving up. Awaiting that
  /// inside the handler left the request hanging for minutes, which reads as a broken
  /// server rather than a slow restart.
  ///
  /// The outcome therefore reaches the user through the log and the alert centre — the
  /// injector already raises an alert when injection fails — rather than through the
  /// response, which is gone by then.
  private static func scheduleRestart(
    applicationName: String,
    bundleIdentifier: String,
    context: some LoggerProviding & PrivateAPIProviding & PrivateAPIRuntimeProviding
  ) {
    Task.detached {
      // A beat, so the HTTP response is flushed before the app starts churning.
      try? await Task.sleep(for: .milliseconds(500))
      let logger = context.logger
      logger.info(
        "Restarting an application with its Private API helper",
        metadata: [
          "app": .string(applicationName)
        ])
      do {
        try await restart(
          applicationName: applicationName,
          bundleIdentifier: bundleIdentifier,
          context: context
        )
        logger.info(
          "Application restarted",
          metadata: [
            "app": .string(applicationName)
          ])
      } catch {
        logger.error(
          "Application restart failed",
          metadata: [
            "app": .string(applicationName),
            "error": .string(String(describing: error)),
          ])
      }
    }
  }

  private static func restart(
    applicationName: String,
    bundleIdentifier: String,
    context: some LoggerProviding & PrivateAPIProviding & PrivateAPIRuntimeProviding
  ) async throws {
    if let runtime = await context.privateAPIRuntime {
      do {
        if try await runtime.reinject(bundleIdentifier: bundleIdentifier) { return }
        // Not a managed app — fall through to the plain restart below.
      } catch {
        throw IMessageError(
          "\(applicationName) was restarted, but the Private API helper did not "
            + "come back: \(error.localizedDescription)"
        )
      }
    }

    // Quit politely first. `terminate()` sends a Quit Apple Event, which lets Messages
    // finish writing chat.db — force-killing it mid-write is how a database ends up
    // corrupt.
    _ = await ApplicationControl.quit(bundleIdentifier: bundleIdentifier)
    guard ApplicationControl.launch(bundleIdentifier: bundleIdentifier) else {
      throw IMessageError("\(applicationName) could not be restarted")
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
    context: some LoggerProviding & PrivateAPIProviding & PrivateAPIRuntimeProviding
  ) {
    registry.register(.icloudAccountInfo) { _ in
      let api = try await requirePrivateAPI(context, for: "reading account information")
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
      let api = try await requirePrivateAPI(context, for: "reading a contact card")
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
      let api = try await requirePrivateAPI(context, for: "reading a contact card")
      let address = request.queryParameters["address"].flatMap { $0.isEmpty ? nil : $0 }
      let card = try await api.nicknameInfo(for: address)
      return .data(.object(contactCardPayload(card, includingExtendedKeys: true)))
    }

    registry.register(.icloudChangeAlias) { request in
      let api = try await requirePrivateAPI(context, for: "changing the active alias")
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
    context: some LoggerProviding & PrivateAPIProviding & PrivateAPIRuntimeProviding,
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

  private static func requirePrivateAPI(
    _ context: some LoggerProviding & PrivateAPIProviding & PrivateAPIRuntimeProviding,
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
