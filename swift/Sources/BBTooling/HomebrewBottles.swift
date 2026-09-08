//  HomebrewBottles
//  Reading Homebrew's bottle registry the way `brew` does, for a vendor that ships no macOS
//  binary of its own.
//
//  Tailscale publishes its daemon for macOS in exactly two forms: an App Store or notarized
//  GUI application whose daemon lives inside a system extension and cannot be driven headless,
//  and a Homebrew formula. There is no darwin tarball on `pkgs.tailscale.com` and no asset on a
//  GitHub release. So the open-source daemon this server runs comes from where Homebrew keeps
//  it: an OCI registry on `ghcr.io`, one repository per formula, one tag per version, and per
//  tag an index naming a bottle for each macOS release and architecture with the SHA-256 the
//  bottle is fetched by.
//
//  That last part is what makes the source acceptable without a Developer ID signature. A
//  bottle's digest is not a checksum file published beside it — it IS its address. The bytes
//  are requested by SHA-256 and the installer hashes what arrived, so a registry serving the
//  wrong bytes for a digest fails closed, and the plugin's own pin on top of that is verified
//  against a value that shipped inside this signed application.
//
//  Two things about the registry are not obvious and both bit during development:
//    - Every request needs an `Authorization` header, even for a public package. Homebrew's
//      own client sends the fixed anonymous token below, and the registry accepts it.
//    - The tag list is paged at a hundred and the pages come oldest-first, so reading only
//      the first one reports a version a year stale. The `Link` header is followed.
//
//  See `.claude/docs/performance.md`.

import BBCore
import BBServiceKit
import Foundation

/// One bottle in a version's index.
struct HomebrewBottle: Sendable, Equatable {
  /// Homebrew's platform tag, as `1.102.3.arm64_sonoma`.
  let referenceName: String
  /// `arm64` or `amd64`, as the OCI platform names them.
  let architecture: String
  /// `darwin` or `linux`.
  let operatingSystem: String
  /// `macOS 14.8`, or `Ubuntu 22.04.5`. Ordered numerically to pick the oldest.
  let operatingSystemVersion: String
  /// SHA-256 of the bottle tarball — the blob digest it is downloaded by.
  let digest: String
  let size: Int?

  /// The numeric part of `macOS 14.8`, for choosing the oldest build.
  var operatingSystemNumber: Double {
    let digits = operatingSystemVersion.split(separator: " ").last.map(String.init) ?? ""
    return Double(digits) ?? .greatestFiniteMagnitude
  }
}

/// A version's index: every bottle Homebrew built for it.
struct HomebrewBottleIndex: Sendable, Equatable {
  let version: String
  let bottles: [HomebrewBottle]
  let createdAt: Date?

  /// The bottle a Mac of this architecture should install.
  ///
  /// macOS only — the same formula also carries Linux bottles — and of the macOS builds the
  /// one built on the OLDEST release, because a bottle built on Sonoma runs on Sequoia and
  /// Tahoe while the reverse is not promised. That is also what makes a pinned digest
  /// stable: the choice depends on what the index carries, not on which Mac is asking.
  func bottle(for architecture: ToolArchitecture) -> HomebrewBottle? {
    let wanted =
      switch architecture {
      case .arm64: "arm64"
      case .x86_64: "amd64"
      }
    return
      bottles
      .filter { $0.operatingSystem == "darwin" && $0.architecture == wanted }
      .min { lhs, rhs in
        if lhs.operatingSystemNumber != rhs.operatingSystemNumber {
          return lhs.operatingSystemNumber < rhs.operatingSystemNumber
        }
        return lhs.referenceName < rhs.referenceName
      }
  }

  /// Parses the OCI image index Homebrew publishes per version.
  ///
  /// Hand-decoded from the two annotation keys that matter, for the same reason
  /// `ZrokEnvironment` decodes zrok's overview by hand: the document's shape is Homebrew's
  /// business, and a `Codable` model of all of it would break on every key they add.
  static func parse(_ data: Data, fallbackVersion: String) -> HomebrewBottleIndex? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let manifests = object["manifests"] as? [[String: Any]]
    else { return nil }

    let annotations = object["annotations"] as? [String: Any] ?? [:]
    let version = annotations["org.opencontainers.image.version"] as? String ?? fallbackVersion
    let created = (annotations["org.opencontainers.image.created"] as? String).flatMap {
      ISO8601DateFormatter().date(from: $0)
    }

    let bottles = manifests.compactMap { manifest -> HomebrewBottle? in
      let platform = manifest["platform"] as? [String: Any] ?? [:]
      let notes = manifest["annotations"] as? [String: Any] ?? [:]
      guard let name = notes["org.opencontainers.image.ref.name"] as? String,
        let digest = notes["sh.brew.bottle.digest"] as? String,
        let architecture = platform["architecture"] as? String,
        let operatingSystem = platform["os"] as? String
      else { return nil }
      return HomebrewBottle(
        referenceName: name,
        architecture: architecture,
        operatingSystem: operatingSystem,
        operatingSystemVersion: platform["os.version"] as? String ?? "",
        digest: digest.lowercased(),
        size: (notes["sh.brew.bottle.size"] as? String).flatMap(Int.init)
      )
    }
    return HomebrewBottleIndex(version: version, bottles: bottles, createdAt: created)
  }
}

/// A formula version as Homebrew tags it, ordered the way Homebrew means it.
///
/// `1.66.4-1` is REVISION one of 1.66.4 — a rebuild, newer than `1.66.4` — where a semantic
/// version would read the suffix as a prerelease and sort it older. Handled here rather than
/// by teaching `SemanticVersion` a second convention it would then apply to every appcast.
struct HomebrewVersion: Comparable, Sendable {
  let text: String
  let semantic: SemanticVersion
  let revision: Int

  init(_ text: String) {
    self.text = text
    // Homebrew writes the revision after `_` in a formula and after `-` in a registry tag,
    // so both are accepted.
    let parts = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
    if parts.count >= 2, let revision = Int(parts[parts.count - 1]) {
      self.semantic = SemanticVersion(parts.dropLast().joined(separator: "-"))
      self.revision = revision
    } else {
      self.semantic = SemanticVersion(text)
      self.revision = 0
    }
  }

  static func < (lhs: HomebrewVersion, rhs: HomebrewVersion) -> Bool {
    if lhs.semantic != rhs.semantic { return lhs.semantic < rhs.semantic }
    return lhs.revision < rhs.revision
  }
}

/// The registry, addressed by formula.
struct HomebrewRegistry: Sendable {

  /// Homebrew's anonymous bearer token, which the registry requires on every request and
  /// accepts for any public package. Not a secret: it is base64 of a single byte, and it
  /// is what every `brew install` on every Mac sends.
  static let anonymousAuthorization = "Bearer QQ=="

  static let host = "ghcr.io"

  let formula: String
  private let transport: any ToolTransport

  init(formula: String, transport: any ToolTransport) {
    self.formula = formula
    self.transport = transport
  }

  /// `homebrew/core/tailscale`; `python@3.12` becomes `homebrew/core/python/3.12`, which is
  /// the mapping Homebrew itself applies when it names the repository.
  var repository: String {
    "homebrew/core/" + formula.replacingOccurrences(of: "@", with: "/")
  }

  /// Every version the registry holds, newest last.
  func versions(toolID: String) async throws -> [HomebrewVersion] {
    var tags: [String] = []
    var next: URL? = URL(string: "https://\(Self.host)/v2/\(repository)/tags/list?n=1000")
    // Bounded, so a registry that answers every page with a `next` link cannot keep this
    // reading forever.
    var pagesLeft = 20
    while let url = next, pagesLeft > 0 {
      pagesLeft -= 1
      let (data, response) = try await transport.fetch(url, headers: Self.headers())
      guard response.isSuccess else {
        throw ToolError.releaseLookupFailed(
          tool: toolID, reason: "the Homebrew registry answered \(response.statusCode)"
        )
      }
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let page = object["tags"] as? [String]
      else {
        throw ToolError.releaseLookupFailed(
          tool: toolID, reason: "the Homebrew registry's tag list could not be read"
        )
      }
      tags.append(contentsOf: page)
      next = Self.nextPage(after: response, from: url)
    }
    return tags.map(HomebrewVersion.init).sorted()
  }

  /// The index for one version, or nil when the registry has no such tag.
  func index(version: String, toolID: String) async throws -> HomebrewBottleIndex? {
    guard let url = URL(string: "https://\(Self.host)/v2/\(repository)/manifests/\(version)")
    else {
      throw ToolError.releaseLookupFailed(tool: toolID, reason: "bad formula name")
    }
    let (data, response) = try await transport.fetch(
      url, headers: Self.headers(accept: "application/vnd.oci.image.index.v1+json")
    )
    if response.statusCode == 404 { return nil }
    guard response.isSuccess else {
      throw ToolError.releaseLookupFailed(
        tool: toolID, reason: "the Homebrew registry answered \(response.statusCode)"
      )
    }
    guard let index = HomebrewBottleIndex.parse(data, fallbackVersion: version) else {
      throw ToolError.releaseLookupFailed(
        tool: toolID, reason: "the Homebrew registry's index for \(version) could not be read"
      )
    }
    return index
  }

  /// Where a bottle's bytes are.
  func downloadURL(for bottle: HomebrewBottle) -> URL? {
    URL(string: "https://\(Self.host)/v2/\(repository)/blobs/sha256:\(bottle.digest)")
  }

  /// The page a person reads about the formula on.
  var formulaPage: String { "https://formulae.brew.sh/formula/\(formula)" }

  static func headers(accept: String? = nil) -> [String: String] {
    var headers = ["Authorization": anonymousAuthorization]
    if let accept { headers["Accept"] = accept }
    return headers
  }

  /// The `rel="next"` target of a `Link` header, resolved against the page it came with.
  static func nextPage(after response: ToolHTTPResponse, from current: URL) -> URL? {
    guard let link = response.header("Link") else { return nil }
    for entry in link.split(separator: ",") {
      let parts = entry.split(separator: ";").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      let isNext = parts.dropFirst().contains {
        $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\""
      }
      guard parts.count >= 2, isNext,
        let first = parts.first, first.hasPrefix("<"), first.hasSuffix(">")
      else { continue }
      let target = String(first.dropFirst().dropLast())
      return URL(string: target, relativeTo: current)?.absoluteURL
    }
    return nil
  }
}
