//  UpdateChecker
//  Backs `GET /api/v1/server/update/check`.
//
//  The response shape is FROZEN: `available`, `current`, and a `metadata` object that is
//  explicitly `null` when there is nothing to offer, not absent. Clients read all four
//  metadata fields. See `CONTRIBUTING.md`: Sparkle replaces the update mechanism, and
//  this endpoint keeps returning what it always returned.

import BBCore
import BBSerialization
import Foundation
import Logging

/// What the hosting app is doing about an update it has already found.
///
/// Reported on `GET /server/update/check` as `install`, so a client that asked for the
/// install (or one that opens the app the morning after a scheduled one) sees "downloading"
/// or "scheduled for 3am" rather than the same "available" it saw before it asked.
public enum UpdateInstallState: Sendable, Equatable {
  case downloading(version: String)
  case scheduled(version: String, at: Date)
  case installing(version: String)

  public var version: String {
    switch self {
    case .downloading(let v), .scheduled(let v, _), .installing(let v): v
    }
  }

  public var json: JSONValue {
    var object = JSONObjectBuilder()
    object.set("version", .string(version))
    switch self {
    case .downloading:
      object.set("state", .string("downloading"))
    case .scheduled(_, let at):
      object.set("state", .string("scheduled"))
      // Epoch milliseconds, like every other date the API sends except `release_date`.
      object.set("scheduled_for", .int64(Int64((at.timeIntervalSince1970 * 1000).rounded())))
    case .installing:
      object.set("state", .string("installing"))
    }
    return object.build()
  }
}

public struct UpdateCheckResult: Sendable, Equatable {
  public let isAvailable: Bool
  public let currentVersion: String
  public let item: AppcastItem?
  /// Additive to the frozen v1 shape; see `json`.
  public var install: UpdateInstallState?

  public init(
    isAvailable: Bool, currentVersion: String, item: AppcastItem?,
    install: UpdateInstallState? = nil
  ) {
    self.isAvailable = isAvailable
    self.currentVersion = currentVersion
    self.item = item
    self.install = install
  }

  /// The wire shape, unchanged from the Electron server.
  public var json: JSONValue {
    var object = JSONObjectBuilder()
    object.set("available", .bool(isAvailable))
    object.set("current", .string(currentVersion))
    // ADDITIVE, and listed in `acceptedDifferences`: the reference had no notion of an
    // install in progress, so it had no field. Explicit null when nothing is pending, for
    // the same reason `metadata` is.
    object.setOrNull("install", install.map(\.json))

    guard isAvailable, let item else {
      // Explicit null, not omitted. A strict client distinguishes the two, and the
      // current server emits null here.
      object.setOrNull("metadata", nil)
      return object.build()
    }

    var metadata = JSONObjectBuilder()
    metadata.set("version", .string(item.shortVersion))
    // ISO 8601 here specifically, matching electron-updater's `releaseDate`. Note this
    // is the ONE date on the wire that is not epoch milliseconds; the rest of the API
    // uses those, and changing this one to match would break the clients that parse it.
    metadata.set("release_date", .string(ISO8601DateFormatter().string(from: item.publishedAt)))
    metadata.set("release_name", .string(item.title))
    metadata.setOrNull("release_notes", item.releaseNotesHTML.map(JSONValue.string))
    object.set("metadata", metadata.build())

    return object.build()
  }
}

/// The public pages a person is sent to read about a release.
public enum ReleasePages {
  public static let history = "https://github.com/BlueBubblesApp/bluebubbles-server/releases"
  /// The notes for one release, by the tag the workflow cuts: `v` plus the version.
  public static func notes(forVersion version: String) -> String {
    "\(history)/tag/v\(version)"
  }
}

/// Fetches and evaluates the appcast.
public struct UpdateChecker: Sendable {

  /// Where shipped installs look. Overridable so tests do not reach the network and a
  /// beta channel can point elsewhere.
  public static let defaultFeedURL =
    "https://raw.githubusercontent.com/BlueBubblesApp/bluebubbles-server/master/appcast.xml"

  private let feedURL: String
  private let currentVersion: String
  /// Named channels this install reads besides the default. `["beta"]` when the person
  /// opted in; the same set the app hands Sparkle, so the API and the installer agree.
  private let allowedChannels: Set<String>
  private let fetch: @Sendable (String) async throws -> Data
  private let logger: Logger

  public init(
    feedURL: String = UpdateChecker.defaultFeedURL,
    currentVersion: String,
    allowedChannels: Set<String> = [],
    fetch: (@Sendable (String) async throws -> Data)? = nil,
    logger: Logger = Logger(label: "bluebubbles.updates")
  ) {
    self.feedURL = feedURL
    self.currentVersion = currentVersion
    self.allowedChannels = allowedChannels
    self.fetch = fetch ?? Self.defaultFetch
    self.logger = logger
  }

  /// The channel Sparkle's beta items are published on, and the one the toggle allows.
  public static let betaChannel = "beta"

  public func check() async throws -> UpdateCheckResult {
    let appcast: Appcast
    do {
      appcast = try AppcastParser.parse(try await fetch(feedURL))
    } catch {
      logger.warning(
        "Update check failed",
        metadata: ["error": .string(String(describing: error))])
      throw error
    }

    guard let newest = appcast.newestItem(allowingChannels: allowedChannels) else {
      logger.debug("Checked for updates; the feed lists no release")
      return UpdateCheckResult(
        isAvailable: false, currentVersion: currentVersion, item: nil
      )
    }

    // Compared numerically. String comparison would report 1.9.0 as newer than 1.10.0
    // and leave a server unpatched with no symptom. See SemanticVersion.
    let available = SemanticVersion(newest.shortVersion) > SemanticVersion(currentVersion)
    logger.debug(
      "Checked for updates",
      metadata: [
        "current": .string(currentVersion),
        "latest": .string(newest.shortVersion),
        "available": .stringConvertible(available),
      ])
    return UpdateCheckResult(
      isAvailable: available,
      currentVersion: currentVersion,
      item: available ? newest : nil
    )
  }

  private static let defaultFetch: @Sendable (String) async throws -> Data = { urlString in
    guard let url = URL(string: urlString) else {
      throw AppcastParser.ParseError.malformedXML("bad feed URL: \(urlString)")
    }
    var request = URLRequest(url: url)
    // Short. This backs a synchronous-looking API call, and a client waiting on an
    // update check is a client whose UI is stuck.
    request.timeoutInterval = 15
    // Bypassed deliberately: an update check that returns a cached "no update" for hours
    // is worse than no check at all.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, _) = try await URLSession.shared.data(for: request)
    return data
  }
}
