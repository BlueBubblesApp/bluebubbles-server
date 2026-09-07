//  CoreHandlers
//  The read path, wired end to end.
//
//  These are the controllers that prove the pipeline is real: a request arrives, the
//  middleware authenticates it, the route table dispatches it, a repository reads chat.db,
//  the serializer produces the frozen wire format, and the envelope goes back out. Everything
//  under them is tested in isolation; this is the code that runs the whole length of it.
//
//  **They are a small fraction of the surface.** The route table names 107 handlers and this
//  file implements the core read set; the rest are mounted by `PlaceholderHandlers` and say
//  so. See `.claude/docs/api.md` — the interfaces layer is the remaining work.

import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBSerialization
import BBSettings
import Foundation

public enum CoreHandlers {

  /// The macOS marketing version, `major.minor.patch`.
  ///
  /// Built from `operatingSystemVersion`, which is the structured form, rather than parsed
  /// out of the display string — the display string is localised and its shape is not
  /// contractual.
  static var osVersion: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  public static func register(
    into registry: inout HandlerRegistry,
    context: some ServerStatusProviding & SettingsProviding
  ) {
    registry.register(.generalPing) { _ in .data(.string("pong")) }
    registry.register(.serverInfo) { _ in try await serverInfo(context: context) }
  }

  /// `GET /api/v1/server/info`.
  ///
  /// The capability report clients use to decide what to offer. Note what is NOT here under
  /// a default configuration: the codec advertisement is omitted entirely when only
  /// legacy-v1 is enabled, because the parity harness diffs this response strictly in both
  /// directions and an added key fails it just as a missing one does.
  private static func serverInfo(
    context: some ServerStatusProviding & SettingsProviding
  ) async throws -> RouteResult {
    let system = await context.systemInfo.snapshot()

    let response = ServerInfoResponse(
      computerIdentifier: system.computerIdentifier,
      // "26.5.2" — the version and nothing else.
      //
      // `operatingSystemVersionString` is a HUMAN-READABLE string:
      // "Version 26.5.2 (Build 25F84)". Apple's own documentation says it is not
      // appropriate for parsing, and the reference sends a bare version from
      // `macos-version`. A client comparing this against a minimum, or splitting it on
      // ".", gets nonsense from the long form.
      //
      // Found by RUNNING the server and reading the response, not by the parity harness:
      // `os_version` is in its volatile-field allowlist, which type-checks a value
      // without comparing it. Two strings both being strings is all that was asserted.
      osVersion: Self.osVersion,
      serverVersion: ServerVersion.current,
      // Reported, not hardcoded. These were both fixed `false`, so a server with a
      // working injected helper told every client the Private API was unavailable —
      // and clients hide reactions, edit and unsend on the strength of this field.
      privateAPIEnabled: await context.settings.get(Settings.enablePrivateAPI),
      proxyService: await context.connectionMethodName(),
      helperConnected: await context.isHelperConnected,
      icloudAccount: system.icloudAccount,
      iMessageAccount: system.iMessageAccount,
      timeSync: system.timeSync,
      localIPv4: system.localIPv4,
      localIPv6: system.localIPv6
    )

    // The codec advertisement is the ONE thing added to this response, and only when a
    // non-legacy codec is enabled — a default server advertises nothing, which is what
    // keeps the field set identical to Node's.
    var fields = response.fields()
    for (key, value) in context.codecs.advertisement.fields() {
      fields[key] = value
    }
    return .data(.object(fields))
  }
}

enum ServerVersion {
  /// Read from the bundle when packaged; a development marker otherwise, so a build that
  /// escaped the packaging step is identifiable rather than claiming a version it does not
  /// have.
  static var current: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
  }
}

// MARK: - Placeholders

/// Mounts every route the interfaces layer has not reached yet.
///
/// Why mount them at all: `buildRouter` refuses to start with an unregistered handler, and
/// that check is deliberate — a route in the table with no controller should be a startup
/// failure rather than a 404 that looks like a client bug. But refusing to start would also
/// mean the server cannot run until all 107 controllers exist, which helps nobody.
///
/// So they are mounted and answer **501 Not Implemented**, which is the truthful status: the
/// route exists, the server recognises it, and the behaviour is missing. A 404 would say the
/// route does not exist, and a 500 would suggest something broke. The count is logged at
/// startup so the gap is measured rather than assumed.
public enum PlaceholderHandlers {

  /// Registers a placeholder for every handler the table needs and nothing has supplied.
  /// - Returns: The handler IDs that got a placeholder.
  @discardableResult
  public static func fill(
    into registry: inout HandlerRegistry,
    groups: [RouteGroup]
  ) -> [HandlerID] {
    let missing = registry.missing(for: groups)
    for id in missing {
      registry.register(id) { _ in
        throw NotImplemented(handler: id.rawValue)
      }
    }
    return missing
  }
}

/// 501, for a route that exists but has no controller yet.
struct NotImplemented: HTTPError {
  let status = 501
  let errorType = ErrorType.serverError
  let responseMessage = ServerError().responseMessage
  let errorMessage: String

  init(handler: String) {
    self.errorMessage =
      "This endpoint is not implemented in the Swift server yet (\(handler))."
  }
}
