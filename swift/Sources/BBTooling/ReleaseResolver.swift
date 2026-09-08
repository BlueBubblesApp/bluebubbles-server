//  ReleaseResolver
//  Turning "what is the current version" into a URL to fetch.
//
//  The three source shapes are not a generalisation for its own sake — they are what the four
//  tunnels actually do, and the difference is visible to the user:
//
//    - **GitHub releases** (cloudflared, zrok) publish a version tag and per-architecture
//      assets. The version is known BEFORE downloading, so "2024.8.2 is available, you have
//      2024.6.1" is a sentence that can be shown, and an update can be declined.
//    - **A Homebrew bottle** (Tailscale) is the same claim from a different registry: one
//      tag per version, one bottle per macOS release and architecture, and a digest that is
//      also the download's address. See `HomebrewBottles`.
//    - **A rolling URL** (ngrok) always serves the current build and never says what it is.
//      The best available answer to "is there something newer" is that the bytes at the URL
//      changed, which is what `ETag`/`Last-Modified` say. The version is learned afterwards,
//      by running the binary.
//
//  The temptation is to flatten these into one interface that reports a version either way,
//  which would mean inventing one for ngrok. An invented version is worse than an honest
//  "there is a newer build": it looks authoritative and is wrong the first time the vendor
//  ships without changing whatever we guessed from.

import BBCore
import BBServiceKit
import Foundation

/// Everything needed to fetch one specific build.
public struct ResolvedRelease: Sendable, Equatable {
  public let version: String
  /// Whether `version` was published by the vendor or read off the binary afterwards.
  public let isVersionKnownInAdvance: Bool
  /// Which channel this actually IS — not which was asked for. A recommended version that
  /// could not be found resolves to the latest, and this says so rather than letting an
  /// install be recorded as something it is not.
  public let channel: ToolChannel
  /// SHA-256 the plugin pinned for this build, when it pinned one.
  public let pinnedDigest: String?
  /// SHA-256 the SOURCE published for this build, when the source publishes one per build.
  ///
  /// A Homebrew bottle's, read from the version's index. Checked by the installer like a
  /// checksums file would be, and — like a checksums file — it is what lets an unsigned
  /// download be adopted. Nil for the sources that publish digests elsewhere or not at all.
  public let publishedDigest: String?
  /// Headers the download itself needs. A registry that refuses anonymous requests puts its
  /// token here; everything else leaves it empty.
  public let requestHeaders: [String: String]
  /// Set when the recommended version was asked for and could not be found.
  ///
  /// The install continues on the latest rather than failing: a recommendation is advice
  /// that ships in a manifest, and a stale one should not be the reason a user cannot get a
  /// working tunnel. It is reported, though — silently installing something other than what
  /// was asked for is how a wrong pin survives a release unnoticed.
  public let recommendationUnavailable: String?
  public let build: ToolBuild
  public let downloadURL: URL
  public let checksumsURL: URL?
  public let releaseNotesURL: String?
  public let publishedAt: Date?
  /// The HTTP validator, for rolling sources.
  public let validator: String?

  public init(
    version: String,
    isVersionKnownInAdvance: Bool,
    channel: ToolChannel = .latest,
    pinnedDigest: String? = nil,
    publishedDigest: String? = nil,
    requestHeaders: [String: String] = [:],
    recommendationUnavailable: String? = nil,
    build: ToolBuild,
    downloadURL: URL,
    checksumsURL: URL? = nil,
    releaseNotesURL: String? = nil,
    publishedAt: Date? = nil,
    validator: String? = nil
  ) {
    self.version = version
    self.isVersionKnownInAdvance = isVersionKnownInAdvance
    self.channel = channel
    self.pinnedDigest = pinnedDigest
    self.publishedDigest = publishedDigest
    self.requestHeaders = requestHeaders
    self.recommendationUnavailable = recommendationUnavailable
    self.build = build
    self.downloadURL = downloadURL
    self.checksumsURL = checksumsURL
    self.releaseNotesURL = releaseNotesURL
    self.publishedAt = publishedAt
    self.validator = validator
  }

  /// The version placeholder used until a rolling download has been run and asked.
  public static let unknownVersion = "current"
}

public struct ReleaseResolver: Sendable {

  private let transport: any ToolTransport

  public init(transport: any ToolTransport) {
    self.transport = transport
  }

  /// The build to install for this machine, on the channel asked for.
  public func resolve(
    _ descriptor: ManagedToolDescriptor,
    channel: ToolChannel = .recommended,
    architectures: [ToolArchitecture] = ToolArchitecture.runnable
  ) async throws -> ResolvedRelease {
    guard let build = descriptor.build(preferring: architectures) else {
      let published = descriptor.builds.map(\.architecture)
      // Two different failures with two different remedies, and telling them apart is
      // the difference between "install Rosetta" and "this will never work here".
      if ToolArchitecture.host == .arm64,
        published.contains(.x86_64),
        !ToolArchitecture.canRunIntelBuilds
      {
        throw ToolError.rosettaRequired(tool: descriptor.id)
      }
      throw ToolError.noBuildForArchitecture(
        tool: descriptor.id, host: .host, available: published
      )
    }

    switch descriptor.source {
    case .gitHubReleases(let owner, let repository, let allowPrereleases):
      // The recommended version, when there is one and it was asked for. A vendor with
      // no addressable versions cannot have one — the validator refuses that manifest —
      // so `recommended` being nil here means the plugin simply did not name a version.
      if channel == .recommended, let recommended = descriptor.recommended {
        return try await resolvePinned(
          descriptor, build: build, recommended: recommended,
          owner: owner, repository: repository, allowPrereleases: allowPrereleases
        )
      }
      return try await resolveGitHub(
        descriptor, build: build,
        owner: owner, repository: repository, allowPrereleases: allowPrereleases
      )
    case .homebrewBottle(let formula):
      let registry = HomebrewRegistry(formula: formula, transport: transport)
      if channel == .recommended, let recommended = descriptor.recommended {
        return try await resolvePinnedBottle(
          descriptor, build: build, recommended: recommended, registry: registry
        )
      }
      return try await resolveBottle(descriptor, build: build, registry: registry, version: nil)
    case .rollingURL:
      return try await resolveRolling(descriptor, build: build)
    }
  }

  // MARK: - A named version

  /// Fetches one specific release by tag.
  ///
  /// Falls back to the latest rather than failing when the tag is not there. A recommendation
  /// is a string in a manifest — it goes stale when a vendor deletes a release, and it goes
  /// wrong when someone bumps it by hand — and neither is a good reason for a user to be
  /// unable to install a tunnel at all. What it must not do is pretend: the fallback is
  /// carried on the result and ends up in front of the user.
  private func resolvePinned(
    _ descriptor: ManagedToolDescriptor,
    build: ToolBuild,
    recommended: RecommendedBuild,
    owner: String,
    repository: String,
    allowPrereleases: Bool
  ) async throws -> ResolvedRelease {
    let pinnedDigest = recommended.digest(for: build.architecture)

    // Tags are written both ways by the two vendors here — `v1.0.4` and `2024.8.2` — and
    // the manifest stores the version rather than the tag, so both forms are tried before
    // concluding the release is gone.
    for tag in [recommended.version, "v\(recommended.version)"] {
      guard
        let url = URL(
          string: "https://api.github.com/repos/\(owner)/\(repository)/releases/tags/\(tag)"
        )
      else { continue }

      guard let (data, response) = try? await transport.fetch(url), response.isSuccess,
        let release = try? GitHubRelease.newest(from: data, toolID: descriptor.id),
        case .releaseAsset(let pattern) = build.download,
        let asset = release.asset(matching: pattern),
        let downloadURL = URL(string: asset.downloadURL)
      else { continue }

      return ResolvedRelease(
        version: release.version,
        isVersionKnownInAdvance: true,
        channel: .recommended,
        pinnedDigest: pinnedDigest,
        build: build,
        downloadURL: downloadURL,
        checksumsURL: checksumsURL(for: descriptor, in: release),
        releaseNotesURL: release.htmlURL,
        publishedAt: release.publishedAt
      )
    }

    let latest = try await resolveGitHub(
      descriptor, build: build,
      owner: owner, repository: repository, allowPrereleases: allowPrereleases
    )
    return ResolvedRelease(
      version: latest.version,
      isVersionKnownInAdvance: true,
      channel: .latest,
      // Deliberately NOT carried over: the digest was pinned for a version that is not
      // the one being installed, and checking it would fail every time.
      pinnedDigest: nil,
      recommendationUnavailable: "\(descriptor.displayName) \(recommended.version) is "
        + "recommended but is no longer published; \(latest.version) was installed "
        + "instead.",
      build: build,
      downloadURL: latest.downloadURL,
      checksumsURL: latest.checksumsURL,
      releaseNotesURL: latest.releaseNotesURL,
      publishedAt: latest.publishedAt
    )
  }

  // MARK: - GitHub

  private func resolveGitHub(
    _ descriptor: ManagedToolDescriptor,
    build: ToolBuild,
    owner: String,
    repository: String,
    allowPrereleases: Bool
  ) async throws -> ResolvedRelease {
    // `/releases/latest` already excludes prereleases and drafts, which is what we want by
    // default; the list endpoint is only needed when prereleases count.
    let path =
      allowPrereleases
      ? "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=10"
      : "https://api.github.com/repos/\(owner)/\(repository)/releases/latest"
    guard let url = URL(string: path) else {
      throw ToolError.releaseLookupFailed(tool: descriptor.id, reason: "bad repository name")
    }

    let (data, response) = try await transport.fetch(url)
    guard response.isSuccess else {
      throw ToolError.releaseLookupFailed(
        tool: descriptor.id,
        // 403 here is almost always the unauthenticated rate limit, and saying so
        // saves someone diagnosing their network.
        reason: response.statusCode == 403
          ? "GitHub is rate limiting this Mac; try again in an hour"
          : "GitHub answered \(response.statusCode)"
      )
    }

    let release = try GitHubRelease.newest(from: data, toolID: descriptor.id)
    guard case .releaseAsset(let pattern) = build.download else {
      throw ToolError.releaseLookupFailed(
        tool: descriptor.id,
        reason: "this build names a fixed URL or a Homebrew bottle, which a GitHub release "
          + "cannot supply"
      )
    }
    guard let asset = release.asset(matching: pattern),
      let downloadURL = URL(string: asset.downloadURL)
    else {
      throw ToolError.assetNotFound(
        tool: descriptor.id, pattern: pattern, available: release.assets.map(\.name)
      )
    }

    return ResolvedRelease(
      version: release.version,
      isVersionKnownInAdvance: true,
      channel: .latest,
      build: build,
      downloadURL: downloadURL,
      checksumsURL: checksumsURL(for: descriptor, in: release),
      releaseNotesURL: release.htmlURL,
      publishedAt: release.publishedAt
    )
  }

  private func checksumsURL(
    for descriptor: ManagedToolDescriptor, in release: GitHubRelease
  ) -> URL? {
    switch descriptor.checksums {
    case .releaseAsset(let pattern):
      release.asset(matching: pattern).flatMap { URL(string: $0.downloadURL) }
    case .url(let string):
      URL(string: string)
    case nil:
      nil
    }
  }

  // MARK: - Homebrew

  /// The recommended bottle, falling back to the newest the way `resolvePinned` does and for
  /// the same reason: a stale pin is not a reason to have no tunnel, and the fallback is
  /// reported rather than hidden.
  private func resolvePinnedBottle(
    _ descriptor: ManagedToolDescriptor,
    build: ToolBuild,
    recommended: RecommendedBuild,
    registry: HomebrewRegistry
  ) async throws -> ResolvedRelease {
    if let pinned = try? await resolveBottle(
      descriptor, build: build, registry: registry, version: recommended.version
    ) {
      return ResolvedRelease(
        version: pinned.version,
        isVersionKnownInAdvance: true,
        channel: .recommended,
        pinnedDigest: recommended.digest(for: build.architecture),
        publishedDigest: pinned.publishedDigest,
        requestHeaders: pinned.requestHeaders,
        build: build,
        downloadURL: pinned.downloadURL,
        releaseNotesURL: pinned.releaseNotesURL,
        publishedAt: pinned.publishedAt
      )
    }

    let latest = try await resolveBottle(
      descriptor, build: build, registry: registry, version: nil
    )
    return ResolvedRelease(
      version: latest.version,
      isVersionKnownInAdvance: true,
      channel: .latest,
      // Not carried over: the pin describes a version that is not the one being installed.
      pinnedDigest: nil,
      publishedDigest: latest.publishedDigest,
      requestHeaders: latest.requestHeaders,
      recommendationUnavailable: "\(descriptor.displayName) \(recommended.version) is "
        + "recommended but is no longer published; \(latest.version) was installed "
        + "instead.",
      build: build,
      downloadURL: latest.downloadURL,
      releaseNotesURL: latest.releaseNotesURL,
      publishedAt: latest.publishedAt
    )
  }

  /// One version's bottle for this build, or the newest version's when `version` is nil.
  private func resolveBottle(
    _ descriptor: ManagedToolDescriptor,
    build: ToolBuild,
    registry: HomebrewRegistry,
    version: String?
  ) async throws -> ResolvedRelease {
    guard case .homebrewBottle = build.download else {
      throw ToolError.releaseLookupFailed(
        tool: descriptor.id,
        reason: "this build names a release asset or a URL, which a Homebrew formula "
          + "cannot supply"
      )
    }

    let wanted: String
    if let version {
      wanted = version
    } else {
      guard let newest = try await registry.versions(toolID: descriptor.id).last else {
        throw ToolError.releaseLookupFailed(
          tool: descriptor.id, reason: "the Homebrew registry lists no versions"
        )
      }
      wanted = newest.text
    }

    guard let index = try await registry.index(version: wanted, toolID: descriptor.id) else {
      throw ToolError.releaseLookupFailed(
        tool: descriptor.id, reason: "the Homebrew registry has no \(wanted)"
      )
    }
    guard let bottle = index.bottle(for: build.architecture),
      let downloadURL = registry.downloadURL(for: bottle)
    else {
      throw ToolError.assetNotFound(
        tool: descriptor.id,
        pattern: "a macOS \(build.architecture.displayName) bottle",
        available: index.bottles.map(\.referenceName)
      )
    }

    return ResolvedRelease(
      version: index.version,
      isVersionKnownInAdvance: true,
      channel: .latest,
      publishedDigest: bottle.digest,
      requestHeaders: HomebrewRegistry.headers(),
      build: build,
      downloadURL: downloadURL,
      releaseNotesURL: registry.formulaPage,
      publishedAt: index.createdAt
    )
  }

  // MARK: - Rolling

  private func resolveRolling(
    _ descriptor: ManagedToolDescriptor,
    build: ToolBuild
  ) async throws -> ResolvedRelease {
    guard case .url(let string) = build.download, let url = URL(string: string) else {
      throw ToolError.releaseLookupFailed(
        tool: descriptor.id, reason: "this build names no URL to download from"
      )
    }

    // A HEAD, so a check costs a request rather than 20 MB. A vendor that answers without
    // validators leaves `validator` nil, and `ToolManager` reports "cannot tell" rather
    // than inventing an answer either way.
    let response = try? await transport.head(url)

    var checksumsURL: URL?
    if case .url(let string)? = descriptor.checksums { checksumsURL = URL(string: string) }

    return ResolvedRelease(
      version: ResolvedRelease.unknownVersion,
      isVersionKnownInAdvance: false,
      build: build,
      downloadURL: url,
      checksumsURL: checksumsURL,
      validator: response?.validator
    )
  }
}

// MARK: - GitHub's JSON

/// Only the fields used, parsed leniently.
struct GitHubRelease: Sendable, Equatable {

  struct Asset: Sendable, Equatable {
    let name: String
    let downloadURL: String
  }

  let version: String
  let assets: [Asset]
  let htmlURL: String?
  let publishedAt: Date?
  let isPrerelease: Bool
  let isDraft: Bool

  func asset(matching pattern: String) -> Asset? {
    assets.first { GlobPattern.matches(pattern, $0.name) }
  }

  /// Parses either endpoint's response — a single release, or a list.
  ///
  /// One function for both because the caller picks the endpoint by policy and should not
  /// then have to remember which shape comes back.
  static func newest(from data: Data, toolID: String) throws -> GitHubRelease {
    let json = try? JSONSerialization.jsonObject(with: data)

    if let object = json as? [String: Any], let release = parse(object) {
      return release
    }
    if let array = json as? [[String: Any]] {
      let releases = array.compactMap(parse).filter { !$0.isDraft }
      // Ordered by version rather than by position: GitHub returns creation order, and
      // a patch published for an older branch after a newer release is not the newest
      // thing — it just happens to be first in the list.
      if let newest = releases.max(by: { $0.semantic < $1.semantic }) {
        return newest
      }
    }
    throw ToolError.releaseLookupFailed(
      tool: toolID, reason: "GitHub's answer contained no usable release"
    )
  }

  private static func parse(_ object: [String: Any]) -> GitHubRelease? {
    guard let tag = object["tag_name"] as? String else { return nil }
    // `v1.0.4` and `2024.8.2` are both real tags from the two vendors here, and the `v` is
    // punctuation rather than part of the version. Stripped so what is stored, compared
    // and shown is one form — otherwise a directory called `v1.0.4` sits next to a version
    // string of `1.0.4` read back from the binary, and neither matches the other.
    let version =
      tag.first == "v" && tag.dropFirst().first?.isNumber == true
      ? String(tag.dropFirst())
      : tag
    let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset -> Asset? in
      guard let name = asset["name"] as? String,
        let url = asset["browser_download_url"] as? String
      else { return nil }
      return Asset(name: name, downloadURL: url)
    }
    return GitHubRelease(
      version: version,
      assets: assets,
      htmlURL: object["html_url"] as? String,
      publishedAt: (object["published_at"] as? String).flatMap {
        ISO8601DateFormatter().date(from: $0)
      },
      isPrerelease: object["prerelease"] as? Bool ?? false,
      isDraft: object["draft"] as? Bool ?? false
    )
  }

  /// For ordering only.
  var semantic: SemanticVersion { SemanticVersion(version) }
}
