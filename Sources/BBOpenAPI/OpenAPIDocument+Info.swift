//  OpenAPIDocument+Info
//  The `info` object and the tag tree: what a reader sees before any operation.
//
//  Its own file so the reader-facing text of the document is edited apart from the machinery
//  that derives operations from the route table (`OpenAPIDocument.swift`).

import BBAuth
import BBHTTPAPI
import BBLicense
import BBSerialization
import Foundation

extension OpenAPIDocument {

  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func info(_ options: Options) -> OrderedJSON {
    .obj([
      ("title", .string("BlueBubbles Server API")),
      ("version", .string(options.version)),
      (
        "description",
        .string(
          """
          The BlueBubbles server HTTP API.

          ## Versions

          `/api/v1` is the surface inherited from the previous Node/Electron server. It \
          is frozen: a bug fix belongs in v1, new capability does not.

          `/api/v2` is everything this server does that the previous one did not. Its \
          routes are individually gated; see `x-availability` on each operation, so a \
          default-configured server serves none of them.

          ## Reading the payload schemas

          Handlers exchange untyped JSON rather than a declared type, so a schema here \
          describes the payloads this API is known to produce. Read one as a lower bound:

          - A field typed `null` may carry a value in cases this document does not cover.
          - An array with empty `items` has no described element type.
          - `required` under-claims rather than over-claims: a field it does not list \
          may still always be present.
          - Where a payload could not be described unambiguously, the schema is empty \
          rather than confidently wrong.

          Some routes describe only their surface: method, path, parameters and status \
          codes, with no payload schema.

          ## What is not described

          A few routes describe their failures but not their success payload: those whose \
          success needs a live call, an available update, or an attachment that has been \
          purged to iCloud.
          """)
      ),
    ])
  }

  // MARK: - Tags

  /// Group tags, nested under a parent tag per API version.
  ///
  /// `parent` and `summary` are 3.2 additions and are the reason this document targets 3.2
  /// rather than 3.1. Without them the version has to be smuggled into the display name:
  /// `"Chat (v1)"`, because tag names are the only identifier an operation can reference and
  /// they have to be unique. The name is a slug nobody reads (`chat-v1`), `summary`
  /// carries the display name, and `parent` puts it under the right version. A viewer renders
  /// two top-level sections instead of thirty flat ones whose version is buried in a suffix.
  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func tags(_ entries: [RouteCatalog.Entry]) -> OrderedJSON {
    var order: [String] = []
    var byTag: [String: (display: String, parent: String?, description: String)] = [:]
    var versions: [Int] = []

    for entry in entries {
      let name = tagName(for: entry)
      guard byTag[name] == nil else { continue }
      order.append(name)

      // The landing page is not under `/api/v<n>`, so it hangs at the top level rather than
      // claiming to be part of a version it does not mount under.
      let parent = entry.group.mountsAtRoot ? nil : "v\(entry.group.apiVersion)"
      if parent != nil, !versions.contains(entry.group.apiVersion) {
        versions.append(entry.group.apiVersion)
      }
      byTag[name] = (entry.group.name, parent, entry.availability.summary)
    }

    let parents = versions.sorted().map { version in
      OrderedJSON.obj([
        ("name", .string("v\(version)")),
        ("summary", .string("API v\(version)")),
        ("description", .string(versionDescription(version))),
        ("kind", .string("nav")),
      ])
    }

    let groups = order.map { name -> OrderedJSON in
      let tag = byTag[name]
      return .obj([
        ("name", .string(name)),
        ("summary", tag.map { .string($0.display) }),
        ("description", tag.map { .string($0.description) }),
        ("parent", tag?.parent.map { .string($0) }),
        ("kind", .string("nav")),
      ])
    }

    return .array(parents + groups)
  }

  private static func versionDescription(_ version: Int) -> String {
    switch version {
    case 1:
      return "Routes mounted under `/api/v1`."
    case 2:
      return "Routes mounted under `/api/v2`. Every one of them is individually gated; see "
        + "each operation's `x-availability` for the setting or flag that makes it reachable. "
        + "A server with default settings serves none of them."
    default:
      return "Routes mounted under `/api/v\(version)`."
    }
  }

  /// Group name plus version, because `Chat` exists in both v1 and v2 and they are not the
  /// same set of endpoints.
  /// The tag's `name`, which is an identifier rather than a label: operations reference it,
  /// so it must be unique and stable. `Chat` exists in both v1 and v2 and they are not the
  /// same set of endpoints, hence the version suffix. The human-facing string is `summary`.
  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func tagName(for entry: RouteCatalog.Entry) -> String {
    let slug = entry.group.name
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: "-")
    return entry.group.mountsAtRoot ? slug : "\(slug)-v\(entry.group.apiVersion)"
  }
}
