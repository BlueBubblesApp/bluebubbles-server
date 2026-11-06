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
//  so. See `.claude/docs/api.md`; the interfaces layer is the remaining work.

import BBCore
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
  /// out of the display string: the display string is localised and its shape is not
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
  /// The capability report clients use to decide what to offer. `ServerInfoResponse` is
  /// Node's field set exactly; two things are merged on top, each declared to the parity
  /// diff, which reports an addition just as it reports a missing key. The server's own
  /// identification (`ServerVersion.identification`), always. The codec advertisement, only
  /// when a non-legacy codec is enabled.
  private static func serverInfo(
    context: some ServerStatusProviding & SettingsProviding
  ) async throws -> RouteResult {
    let system = await context.systemInfo.snapshot()

    let response = ServerInfoResponse(
      computerIdentifier: system.computerIdentifier,
      // "26.5.2": the version and nothing else.
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
      // The v1 feature level, NOT this build's version; see `ServerVersion.advertised`,
      // which carries the whole reason.
      serverVersion: ServerVersion.advertised,
      // Reported, not hardcoded: clients hide reactions, edit and unsend on the strength
      // of this field.
      privateAPIEnabled: await context.settings.get(Settings.enablePrivateAPI),
      proxyService: await context.connectionMethodName(),
      helperConnected: await context.isHelperConnected,
      icloudAccount: system.icloudAccount,
      iMessageAccount: system.iMessageAccount,
      timeSync: system.timeSync,
      localIPv4: system.localIPv4,
      localIPv6: system.localIPv6
    )

    // Node's fields, then this server's identification, then the codec advertisement,
    // which a default server leaves empty.
    var fields = response.fields()
    for (key, value) in ServerVersion.identification {
      fields[key] = value
    }
    for (key, value) in context.codecs.advertisement.fields() {
      fields[key] = value
    }
    return .data(.object(fields))
  }
}

public enum ServerVersion {
  /// THIS BUILD's version (`AppVersion.current`), and the update path's: `UpdateChecker`
  /// compares it against the appcast to decide whether a release is newer. It is
  /// deliberately NOT what `GET /server/info` reports; see `advertised`.
  public static var current: String { AppVersion.current }

  /// What `GET /server/info` reports, and the ONLY place it is used.
  ///
  /// **Clients treat `server_version` as a feature level, not an identity.** The app turns it
  /// into `serverVersionCode = major * 100 + minor * 21 + patch` and gates fourteen features
  /// on thresholds of that number: 148 for edit and unsend, 205 for
  /// scheduled messages, 226 for row-id incremental sync and group management, 268 for
  /// creating a group chat. Reporting this server's own `0.1.1` yields **22**, below every
  /// one of them, so a client talking to a server that implements all of it is told it can
  /// use none of it: no edit or unsend, no scheduled messages, no handle sync, no group
  /// management, and the slowest of the three incremental-sync algorithms. `2.0.0` is no
  /// cure: it scores **200**, because a minor weighs 21, and still loses everything from
  /// scheduled messages (205) up. This server's own version goes out as
  /// `server_build_version` instead; see `identification`.
  ///
  /// So this reports the v1 FEATURE LEVEL: the version of the Electron server whose
  /// behaviour this one implements, which is the question the field is actually asked.
  /// `1.9.9` is that server's current release and scores 298, clearing every gate.
  ///
  /// Two things this deliberately is not. It is not `current`, so the updater still compares
  /// real build versions against the appcast and a released 2.0.1 still supersedes 2.0.0.
  /// And it is not a lie a user sees: the app's own title bar and the About window read the
  /// bundle version, and this string only ever reaches a client deciding what to offer.
  ///
  /// Raising it is a deliberate act: it says this server implements everything the named
  /// Electron release does. `ServerVersionAdvertisementTests` holds it against the gate
  /// table so a future feature gate above 298 fails the build rather than shipping dark.
  static let advertised = "1.9.9"

  /// What this server adds to `GET /server/info` so a client can tell it apart from the
  /// Electron server without reading anything into `server_version`, which is a feature
  /// level and has to stay one (see `advertised`).
  ///
  /// - `api_versions`: the API versions this server serves, `[1, 2]` today, from
  ///   `RouteTable.latestVersion`. The question a client asks before calling a v2 route; the
  ///   Electron server sends no such key, so its absence answers "v1 only".
  /// - `server_build_version`: this build's own version (`current`), for a client to show
  ///   and a support thread to quote. Never a feature level: a client that gates on it
  ///   re-creates the problem `advertised` exists to solve.
  ///
  /// Added on every server, not behind a switch: a client needs it BEFORE it knows what to
  /// switch on, and an unknown key is ignored by every shipped client. Declared in
  /// `acceptedDifferences` (`BBParity`) by path, and a contract from the first client that
  /// reads it.
  static var identification: [String: JSONValue] {
    [
      "api_versions": .array((1...RouteTable.latestVersion).map { .int($0) }),
      "server_build_version": .string(current),
    ]
  }
}

// MARK: - Placeholders

/// Mounts every route the interfaces layer has not reached yet.
///
/// Why mount them at all: `buildRouter` refuses to start with an unregistered handler, and
/// that check is deliberate: a route in the table with no controller should be a startup
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
