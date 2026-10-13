//  SystemHandlers
//  Controllers for the machine itself and the account.
//
//  FindMy is NOT here. It is a surface of its own (status, two refreshes, a share request,
//  sharing control) in `FindMyHandlers`.

import BBCore
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
    context: some ApplicationRestarting & AccountProviding,
    logSink: FileSink?
  ) {
    registerMac(into: &registry, context: context)
    registerAccount(into: &registry, context: context)
    registerLogs(into: &registry, context: context, logSink: logSink)
  }

  // MARK: - The machine

  private static func registerMac(
    into registry: inout HandlerRegistry,
    context: some ApplicationRestarting & AccountProviding
  ) {
    registry.register(.macLock) { _ in
      try await ScreenLock.lock()
      return .data(nil)
    }

    // Answered first, THEN restarted; see `ApplicationRestartCoordinator.scheduleRestart`.
    // The restart goes through the injector so the Private API helper comes back with the
    // app; a plain relaunch would silently drop it.
    registry.register(.macRestartMessages) { _ in
      await context.applicationRestart().scheduleRestart(.messages)
      // The inherited route answers with no data; asserted by the parity harness.
      return .data(nil)
    }

    // FaceTime's counterpart. Same rule about injection: restarting FaceTime.app without
    // its helper leaves the FaceTime routes reporting no helper.
    registry.register(.facetimeRestart) { _ in
      await context.applicationRestart().scheduleRestart(.faceTime)
      return .data(.object(["restarting": .bool(true)]))
    }
  }

  // MARK: - Account

  private static func registerAccount(
    into registry: inout HandlerRegistry,
    context: some ApplicationRestarting & AccountProviding
  ) {
    // THE RESPONSE SHAPE IS FIXED BY THE REFERENCE, and
    // `Fixtures/http/get_api_v1_icloud_account-5baa61-200.json` records all eight keys:
    //
    //     apple_id, account_name, active_alias, aliases, vetted_aliases,
    //     login_status_message, sms_forwarding_enabled, sms_forwarding_capable
    //
    // This used to send four, and two of those with the wrong type. The reference returns
    // the helper's payload verbatim (`iCloudInterface.getAccountInfo` is `return data.data`),
    // and the ObjC helper built the dictionary above field for field.
    //
    // `aliases` and `vetted_aliases` are arrays of OBJECTS. The app reads `e['Alias']` off
    // every element (`profile_panel.dart:401`), so the flat string array this sent was not a
    // thinner payload: it crashed the profile screen with `type 'String' is not a subtype of
    // type 'int' of 'index'`, because indexing a Dart string wants an integer. The other four
    // keys are all read by that same screen, and an absent one renders as "null".
    registry.register(.icloudAccountInfo) { _ in
      return .data(
        .object(AccountInterface.accountInfoPayload(try await context.accountInterface().info())))
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
    // helper reports them: a v1 response with extra keys is a parity failure exactly like
    // one with missing keys. They stay on the contract because the socket layer and future
    // v2 surface can use them.
    registry.register(.icloudContactCard) { request in
      // Absent means the local user's own card. The reference takes it from the query
      // string and passes undefined straight through, so an empty value is the default
      // rather than an error.
      let address = request.queryParameters["address"].flatMap {
        $0.isEmpty ? nil : $0
      }
      let card = try await context.accountInterface().contactCard(for: address)
      return .data(.object(AccountInterface.contactCardPayload(card, includingExtendedKeys: false)))
    }

    // The v2 shape: everything `NicknameInfo` carries.
    //
    // `hasSharedNickname` is the key v1 cannot express. A person who shared a card with no
    // name and no photo, and a person who shared nothing at all, both reduce to an empty
    // `data` object in v1; here they differ.
    registry.register(.icloudContactCardV2) { request in
      let address = request.queryParameters["address"].flatMap { $0.isEmpty ? nil : $0 }
      let card = try await context.accountInterface().contactCard(for: address)
      return .data(.object(AccountInterface.contactCardPayload(card, includingExtendedKeys: true)))
    }

    registry.register(.icloudChangeAlias) { request in
      let alias = try request.values().requireString("alias")
      // Checked against the account's aliases first; see `AccountInterface.setActiveAlias`.
      try await context.accountInterface().setActiveAlias(alias)
      return .data(nil)
    }
  }

  // MARK: - Logs

  private static func registerLogs(
    into registry: inout HandlerRegistry,
    context: some ApplicationRestarting & AccountProviding,
    logSink: FileSink?
  ) {
    registry.register(.serverLogs) { request in
      guard let logSink else {
        throw ServiceUnavailable("this server is not writing to a log file")
      }
      // Capped at BOTH ends. The ceiling is because the log rotates at 10 MB and a
      // client asking for "everything" would otherwise pull all of it through the JSON
      // encoder in one response.
      //
      // The floor is not tidiness. `FileSink.tail` passes this to `Array.suffix`, which
      // `_precondition`s on a non-negative length, so `?count=-1` from any authenticated
      // client trapped the process. `Int.init` accepts a leading minus, so nothing
      // upstream rejected it. Clamped rather than rejected: the reference has no
      // validator on this route, and a 400 where it returned 200 would be a wire change
      // for a value no real client sends.
      let count = min(max(request.integer("count") ?? 100, 1), 10_000)
      // ONE STRING, not an array of lines. The reference's `FileSystem.getLogs` returns
      // `Promise<string>` — the raw stdout of `tail -n <count> <file>` — and hands it
      // straight to `new Success(ctx, { data: logs })`, so `data` is text.
      //
      // The array this used to send is not a richer shape to the client that reads it. The
      // app writes the value with `File.writeAsString(response.data['data'])`, which takes a
      // String, and its `.catchError((_) { … })` swallows the type error: the request
      // succeeds, the log file is never written, and nothing is reported beyond "Failed to
      // fetch logs!". `get_api_v1_server_logs-9d34d7-200.json` records the string.
      //
      // Joining on "\n" reproduces `tail` byte for byte, trailing newline included:
      // `lastLines` keeps the empty element a split on "\n" produces for a file that ends
      // with one, so the join puts the terminator back.
      return .data(.string(logSink.tail(lines: count).joined(separator: "\n")))
    }
  }

}
