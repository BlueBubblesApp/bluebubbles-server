//  AdminHandlers
//  Controllers for server administration.
//
//  Alerts, statistics, webhooks, backups, and the restart routes. All `server:admin` scope
//  except the statistics and alert reads, which keep the v1 scoping: the brute-force
//  target is `statistics/totals`, and failure-only rate limiting is what covers it rather
//  than a scope change that would break clients. See `docs/AUTH.md` § "2. Access control".

import BBEvents
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum AdminHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & LoggerProviding & ServerControlling
      & AdminInterfaceProviding & SettingsProviding
  ) {
    registerAlerts(into: &registry, context: context)
    registerStatistics(into: &registry, context: context)
    registerWebhooks(into: &registry, context: context)
    registerBackups(into: &registry, context: context)
    registerLifecycle(into: &registry, context: context)
  }

  // MARK: - Alerts

  private static func registerAlerts(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & LoggerProviding & ServerControlling
      & AdminInterfaceProviding & SettingsProviding
  ) {
    registry.register(.serverAlerts) { request in
      let server = context.admin
      // Node ignores `limit` entirely and returns `AlertsInterface.find()`'s default of
      // 10. Honouring the parameter is additive and allowed; the DEFAULT has to match,
      // or a client that pages by counting rows sees a different world.
      return .data(
        .array(
          await server.alerts(limit: request.integer("limit") ?? 10).map(AdminInterface.alertJSON))
      )
    }

    // v2: everything an alert carries. A higher default limit than v1's ten, because this
    // is the shape something browsing a history would read rather than the one a client
    // polls for the newest few.
    registry.register(.serverAlertsV2) { request in
      let server = context.admin
      return .data(
        .array(
          await server.alerts(limit: request.integer("limit") ?? 100).map(
            AdminInterface.alertJSONV2)
        ))
    }

    registry.register(.serverMarkAlertRead) { request in
      let server = context.admin
      let values = try request.values()

      // Ids may arrive as NUMBERS or as strings, and reading only strings was actively
      // destructive rather than merely lossy. The reference's alert `id` is an
      // autoincrement integer, so a client holding one sends `{"ids": [6]}`; that
      // `compactMap(\.stringValue)` yielded nothing, nothing meant "all", and asking to
      // mark one alert read marked EVERY alert read. Verified against a live server.
      let ids = alertIdentifiers(in: values.raw)

      // Empty is a 400, matching the reference (`if (isEmpty(ids)) throw new
      // BadRequest`). Treating empty as "all" is a behaviour the reference does not have,
      // and it is what would turn the parse failure above into data loss. The app's "Mark
      // All Read" does not come through here: it calls `AlertCenter.markAllRead` in
      // process, so nothing depends on it.
      guard !ids.isEmpty else { throw BadRequest("No alert IDs provided!") }

      await server.markAlertsRead(ids: ids)
      return .data(nil)
    }

    // Same ids, same rules. Duplicated rather than shared so a v2 client never has to
    // drop back to a v1 path to finish a flow it started on v2.
    registry.register(.serverMarkAlertReadV2) { request in
      let server = context.admin
      let ids = alertIdentifiers(in: try request.jsonBody() ?? .object([:]))
      guard !ids.isEmpty else { throw BadRequest("No alert IDs provided!") }
      await server.markAlertsRead(ids: ids)
      return .data(nil)
    }
  }

  /// The ids in a mark-read request, accepting both `ids: [...]` and a single `id`.
  ///
  /// Static and internal so a test can reach it: the bug was entirely in this parse, and
  /// reaching it through the handler would mean standing up an `AppContext` to assert on a
  /// type coercion.
  static func alertIdentifiers(in body: JSONValue) -> [String] {
    func identifier(_ value: JSONValue) -> String? {
      value.stringValue ?? value.intValue.map(String.init)
    }
    var ids = body["ids"]?.arrayValue?.compactMap(identifier) ?? []
    if let single = body["id"].flatMap(identifier) { ids.append(single) }
    return ids
  }

  // MARK: - Statistics

  private static func registerStatistics(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & LoggerProviding & ServerControlling
      & AdminInterfaceProviding & SettingsProviding
  ) {
    // `only` here as well as on the two media-statistics routes, which had it and this did
    // not. Each of these totals is a full table scan, so a client asking for one was paying
    // for four; the parameter was accepted and dropped.
    registry.register(.serverStatTotals) { request in
      let server = context.admin
      let wanted = MediaHandlers.requestedCategories(request.queryParameters["only"])
      return .data(AdminInterface.serialize(try await server.counts(only: wanted)))
    }
  }

  // MARK: - Webhooks

  private static func registerWebhooks(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & LoggerProviding & ServerControlling
      & AdminInterfaceProviding & SettingsProviding
  ) {
    // `?id=` and `?url=` filter, as the reference's `getWebhooks({ url, id })` does. Both
    // were accepted and ignored, so a client asking about one webhook got all of them.
    registry.register(.webhookList) { request in
      let server = context.admin
      var webhooks = try await server.webhooks()
      if let id = request.integer("id").map(Int64.init) {
        webhooks = webhooks.filter { $0.id == id }
      }
      if let url = request.queryParameters["url"], !url.isEmpty {
        webhooks = webhooks.filter { $0.url == url }
      }
      return .data(.array(webhooks.map(\.json)))
    }

    registry.register(.webhookCreate) { request in
      let server = context.admin
      let values = try request.values()
      let url = try values.requireString("url")
      let events = try Self.validatedEvents(values["events"]) ?? ["*"]
      return .data(try await server.createWebhook(url: url, events: events).json)
    }

    registry.register(.webhookUpdate) { request in
      let server = context.admin
      let raw = try request.requirePathParameter("id")
      guard let id = Int64(raw) else { throw BadRequest("`id` must be a number") }
      let values = try request.values()
      // Absent means "leave it alone", which is not the same as an empty list: a body
      // carrying only `events` must not blank out the URL.
      let url = values["url"]?.stringValue
      let events = try Self.validatedEvents(values["events"])
      return .data(try await server.updateWebhook(id: id, url: url, events: events).json)
    }

    registry.register(.webhookDelete) { request in
      let server = context.admin
      let raw = try request.requirePathParameter("id")
      guard let id = Int64(raw) else { throw BadRequest("`id` must be a number") }
      try await server.deleteWebhook(id: id)
      return .data(nil)
    }
  }

  /// The event names a webhook may subscribe to, or nil when the client named none.
  ///
  /// **A typo used to create a webhook that never fired and said nothing.** `compactMap`
  /// dropped anything that was not a string and kept anything that was, so `new-mesage`
  /// was stored, matched no event, and delivered nothing for the life of the webhook. The
  /// reference refuses both shapes at create time (`webhookValidator.ts:36-49`) and this is
  /// its wording, because a client has been reading these sentences.
  ///
  /// The set is `EventName.webhookSubscribable` plus the `*` wildcard, which is the
  /// reference's `webhookEventOptions` value-for-value; `WebhookEventCatalogTests` is what
  /// keeps the two lists the same. A name this server emits but the reference never offered
  /// would be accepted here and refused there, which is the direction that cannot break a
  /// client.
  static func validatedEvents(_ raw: JSONValue?) throws -> [String]? {
    guard let raw, !raw.isNull else { return nil }
    guard let elements = raw.arrayValue else {
      throw BadRequest("Webhook events must be an array!")
    }
    let allowed = Set(["*"] + EventName.webhookSubscribable.map(\.rawValue))
    return try elements.map { element in
      guard let name = element.stringValue else {
        throw BadRequest("Webhook events must be strings!")
      }
      guard allowed.contains(name) else {
        throw BadRequest(
          "Invalid webhook event: \(name)! Webhook must be one of: "
            + allowed.sorted().joined(separator: ",")
        )
      }
      return name
    }
  }

  // MARK: - Backups

  private static func registerBackups(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & LoggerProviding & ServerControlling
      & AdminInterfaceProviding & SettingsProviding
  ) {
    for (kind, prefix): (AdminInterface.BackupKind, HandlerID) in [
      (.theme, .backupGetTheme),
      (.settings, .backupGetSettings),
    ] {
      // `?name=` returns THAT backup, as the reference does; without it, all of them.
      // Ignoring it meant a client asking for one theme received every theme it had ever
      // saved, which for a theme document is a large response to throw away.
      registry.register(prefix) { request in
        let server = context.admin
        let all = try await server.backups(kind: kind)
        guard let name = request.queryParameters["name"], !name.isEmpty else {
          return .data(server.serialize(all))
        }
        return .data(server.serialize(all.filter { $0.name == name }))
      }
    }

    for (kind, id): (AdminInterface.BackupKind, HandlerID) in [
      (.theme, .backupCreateTheme),
      (.settings, .backupCreateSettings),
    ] {
      registry.register(id) { request in
        let server = context.admin
        let values = try request.values()
        let name = try values.requireString("name")
        // The whole body is STORED, not just a `data` field: clients send the
        // document itself and read it back the same way.
        try await server.saveBackup(kind: kind, name: name, payload: values.raw)
        // Nothing is RETURNED, though. The reference answers a save with
        // `{status, message}` and no `data` key; see
        // Fixtures/http/post_api_v1_backup_theme-5baa61-200.json, and an added key
        // fails the compatibility diff exactly like a missing one.
        return .data(nil)
      }
    }

    for (kind, id): (AdminInterface.BackupKind, HandlerID) in [
      (.theme, .backupDeleteTheme),
      (.settings, .backupDeleteSettings),
    ] {
      registry.register(id) { request in
        let server = context.admin
        let values = try request.values()
        // REQUIRED, and this is a data-loss fix rather than tidiness. The name was
        // optional here and `BackupRepository.delete` skips its filter when the name is
        // nil, so `DELETE /backup/theme` with no name deleted EVERY theme the user had.
        // The reference cannot reach that: `name` is `required|string|min:3|max:50`
        // (`validators/themeValidator.ts:11-13`, `settingsValidator.ts:11-13`), so a
        // nameless delete is a 400 there and no client has ever had it work.
        //
        // The query string is still accepted as a fallback because a DELETE with a body
        // is awkward in several HTTP clients and this route has always read both.
        let name = values.string("name") ?? request.queryParameters["name"]
        guard let name, !name.isEmpty else {
          throw BadRequest(RequestValues.missing("name"))
        }
        try await server.deleteBackup(kind: kind, name: name)
        return .data(nil)
      }
    }
  }

  // MARK: - Lifecycle

  private static func registerLifecycle(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & LoggerProviding & ServerControlling
      & AdminInterfaceProviding & SettingsProviding
  ) {
    // Both restarts are GET, which is not what we would choose for a non-idempotent
    // action, but clients issue them that way and the route table is frozen.
    registry.register(.serverRestartServices) { _ in
      // Answered before restarting, not after. A restart tears down the HTTP listener
      // that owes this response, so replying afterwards is replying on a socket that
      // no longer exists: the client sees a dropped connection and reports a failure
      // for a restart that worked.
      Task { await context.requestRestart() }
      // No `data`. The reference sends the message and nothing else, and the two-way diff
      // counts an added field as a break in the same way as a dropped one.
      return .data(nil)
    }

    // The hard restart replaces the PROCESS rather than cycling the services. Same
    // answer-first ordering, and for the same reason.
    registry.register(.serverRestartAll) { _ in
      Task {
        // A beat, so this response is actually on the wire before the listener goes
        // away. Without it the client reliably sees a dropped connection and reports
        // a restart that in fact worked.
        try? await Task.sleep(for: .milliseconds(500))
        await context.requestFullRestart()
      }
      return .data(nil)
    }
  }
}
