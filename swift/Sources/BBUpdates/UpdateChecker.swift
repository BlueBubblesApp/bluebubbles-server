//  UpdateChecker
//  Backs `GET /api/v1/server/update/check`.
//
//  The response shape is FROZEN — `available`, `current`, and a `metadata` object that is
//  explicitly `null` when there is nothing to offer, not absent. Clients read all four
//  metadata fields. See `CONTRIBUTING.md`: Sparkle replaces the update mechanism, and
//  this endpoint keeps returning what it always returned.

import BBCore
import BBSerialization
import Foundation
import Logging

public struct UpdateCheckResult: Sendable, Equatable {
  public let isAvailable: Bool
  public let currentVersion: String
  public let item: AppcastItem?

  public init(isAvailable: Bool, currentVersion: String, item: AppcastItem?) {
    self.isAvailable = isAvailable
    self.currentVersion = currentVersion
    self.item = item
  }

  /// The wire shape, unchanged from the Electron server.
  public var json: JSONValue {
    var object = JSONObjectBuilder()
    object.set("available", .bool(isAvailable))
    object.set("current", .string(currentVersion))

    guard isAvailable, let item else {
      // Explicit null, not omitted. A strict client distinguishes the two, and the
      // current server emits null here.
      object.setOrNull("metadata", nil)
      return object.build()
    }

    var metadata = JSONObjectBuilder()
    metadata.set("version", .string(item.shortVersion))
    // ISO 8601 here specifically, matching electron-updater's `releaseDate`. Note this
    // is the ONE date on the wire that is not epoch milliseconds — the rest of the API
    // uses those, and changing this one to match would break the clients that parse it.
    metadata.set("release_date", .string(ISO8601DateFormatter().string(from: item.publishedAt)))
    metadata.set("release_name", .string(item.title))
    metadata.setOrNull("release_notes", item.releaseNotesHTML.map(JSONValue.string))
    object.set("metadata", metadata.build())

    return object.build()
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
  private let fetch: @Sendable (String) async throws -> Data
  private let logger: Logger

  public init(
    feedURL: String = UpdateChecker.defaultFeedURL,
    currentVersion: String,
    fetch: (@Sendable (String) async throws -> Data)? = nil,
    logger: Logger = Logger(label: "bluebubbles.updates")
  ) {
    self.feedURL = feedURL
    self.currentVersion = currentVersion
    self.fetch = fetch ?? Self.defaultFetch
    self.logger = logger
  }

  public func check() async throws -> UpdateCheckResult {
    let data = try await fetch(feedURL)
    let appcast = try AppcastParser.parse(data)

    guard let newest = appcast.newestItem else {
      return UpdateCheckResult(
        isAvailable: false, currentVersion: currentVersion, item: nil
      )
    }

    // Compared numerically. String comparison would report 1.9.0 as newer than 1.10.0
    // and leave a server unpatched with no symptom. See SemanticVersion.
    let available = SemanticVersion(newest.shortVersion) > SemanticVersion(currentVersion)
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
