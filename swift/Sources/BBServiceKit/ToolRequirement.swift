//  ToolRequirement
//  The external program a service needs, declared the same way everything else about a
//  service is: as data.
//
//  Three of the connection methods are a wrapper around someone else's binary, and the Node
//  server solved that by committing 200 MB of vendored executables to the repository —
//  `appResources/macos/daemons/<provider>/<arch>/`, two architectures each, cloudflared alone
//  38 MB, updated by hand when someone remembered. Every one of those bytes ships in the app,
//  in every Sparkle delta, to every user, including the ones using a connection method that
//  needs no binary at all.
//
//  So the binary is fetched rather than bundled. The part worth designing is not the download
//  — it is that a PLUGIN has to be able to say "I need this program" without shipping Swift
//  code that goes and gets it. If ngrok's downloader is a closure compiled into this binary,
//  a third-party tunnel can never have one, and we are back to a model where built-in services
//  can do things plugins cannot. Hence: no behaviour here. A descriptor says where a build
//  comes from, how to tell it apart from a forgery, and how to ask it its version. The host
//  reads that and does the work, identically for a service we ship and for one we do not.
//
//  Per-architecture builds are not a detail. A Mac is arm64 or x86_64, an x86_64 build runs on
//  Apple Silicon only if Rosetta is installed, and an arm64 build does not run on an Intel Mac
//  at all. Guessing wrong produces `Bad CPU type in executable` from a process that was
//  launched successfully a moment earlier — which reads as "the tunnel crashed".
//
//  See `.claude/docs/performance.md` and `docs/EVENTS.md`.

import Foundation

// MARK: - Architecture

/// A Mac's CPU architecture, as the vendors name their builds.
///
/// Only the two: macOS 14 is the floor, so there is no ppc and no fat-binary story to carry.
public enum ToolArchitecture: String, Sendable, Codable, CaseIterable, CustomStringConvertible {
  case arm64
  // swift-format-ignore: AlwaysUseLowerCamelCase
  // Not renamed to satisfy the rule. The case name IS the architecture identifier, and the
  // rawValue is matched against the strings vendors put in their release asset names — so
  // `x8664 = "x86_64"` would buy a lint pass at the cost of a name nobody writes or reads.
  case x86_64

  public var description: String { rawValue }

  /// What a person calls it. "x86_64" is not what anyone reads on the About This Mac screen.
  public var displayName: String {
    switch self {
    case .arm64: "Apple Silicon"
    case .x86_64: "Intel"
    }
  }
}

// MARK: - Where a build comes from

/// How the host discovers what the current version IS.
///
/// Two shapes, because the three tunnels genuinely have two: cloudflared and zrok publish
/// GitHub releases with version tags and per-architecture assets, while ngrok publishes one
/// URL per architecture that always serves the current build and never says what it is. A
/// single "download strategy" that pretended those were the same would have to invent a
/// version for ngrok, and the invented one would be wrong the moment ngrok shipped.
public enum ToolSource: Sendable, Codable, Equatable {

  /// A GitHub repository's releases. The tag is the version; assets are matched by name.
  case gitHubReleases(owner: String, repository: String, allowPrereleases: Bool = false)

  /// One URL per architecture that always serves the vendor's current build.
  ///
  /// There is no version to read before downloading, so "is there something newer" is
  /// answered from the HTTP validators (`ETag`, `Last-Modified`) and the version itself is
  /// learned by running the binary afterwards. That is weaker than a version tag and it is
  /// what the vendor offers.
  case rollingURL

  /// The hosts a check or a download will actually reach.
  ///
  /// Derived rather than declared so a manifest cannot list a friendly-looking host and then
  /// fetch from somewhere else — `ManifestValidator` requires these to be covered by the
  /// service's `.network` entitlement, which is what puts them on the permissions list the
  /// user reads before enabling anything.
  ///
  /// The GitHub set includes `objects.githubusercontent.com` because that is where a release
  /// asset download REDIRECTS to; declaring only `api.github.com` would describe the check
  /// and not the download.
  public var hosts: Set<String> {
    switch self {
    case .gitHubReleases:
      ["api.github.com", "github.com", "objects.githubusercontent.com"]
    case .rollingURL:
      []
    }
  }
}

/// How the bytes for one architecture are found and unpacked.
public struct ToolBuild: Sendable, Codable, Equatable {

  public let architecture: ToolArchitecture
  public let download: ToolDownload
  public let archive: ArchiveFormat
  /// Where the executable sits inside the archive, when it is not simply the tool's
  /// executable name at some depth. zrok's tarball has it at the root; cloudflared's is the
  /// binary itself under a different name.
  public let pathInArchive: String?

  public init(
    architecture: ToolArchitecture,
    download: ToolDownload,
    archive: ArchiveFormat,
    pathInArchive: String? = nil
  ) {
    self.architecture = architecture
    self.download = download
    self.archive = archive
    self.pathInArchive = pathInArchive
  }
}

/// Which bytes to fetch.
public enum ToolDownload: Sendable, Codable, Equatable {
  /// Matched against the names of a GitHub release's assets, `*` matching any run of
  /// characters.
  ///
  /// A pattern rather than a name because the version is IN the name for most projects —
  /// `zrok_1.0.4_darwin_arm64.tar.gz` — so an exact name would have to be rewritten on every
  /// release, which is the maintenance this whole mechanism exists to avoid.
  case releaseAsset(namePattern: String)
  /// A fixed URL.
  case url(String)

  public var host: String? {
    switch self {
    case .releaseAsset: nil
    case .url(let string): URL(string: string)?.host
    }
  }
}

/// What the downloaded file is.
public enum ArchiveFormat: String, Sendable, Codable, Equatable {
  /// The executable itself, no container.
  case executable
  case zip
  case tarGzip = "tar.gz"

  public var fileExtension: String {
    switch self {
    case .executable: ""
    case .zip: "zip"
    case .tarGzip: "tar.gz"
    }
  }
}

// MARK: - Proving the download is the vendor's

/// What signature the executable must carry.
///
/// A checksum alone is not verification. It proves the file matches what the release metadata
/// said, and the release metadata came down the same connection from the same place — an
/// attacker who can serve one can serve both. macOS will tell us who signed a binary, and that
/// answer is anchored in Apple's root rather than in the download.
public enum SignaturePolicy: Sendable, Codable, Equatable {

  /// Must carry a valid Developer ID signature from exactly this team.
  ///
  /// The strongest option and the one to move to once a Team ID has been read off a real
  /// download — never transcribed from documentation, because a wrong Team ID here bricks
  /// installation for everyone with an error that looks like tampering.
  case pinnedTeam(String)

  /// Must be validly signed; whoever signed the FIRST install is pinned for every update
  /// after it.
  ///
  /// The honest default for a vendor whose Team ID we have not verified ourselves. It does
  /// not protect the first install beyond "signed by someone Apple issued a Developer ID
  /// to", and it does protect every install after it: a build signed by a different team
  /// than the one already trusted is refused rather than installed, which is the shape a
  /// supply-chain substitution takes.
  case trustOnFirstUse

  /// The vendor does not sign its binaries.
  ///
  /// Permitted only alongside a checksum source — `ManifestValidator` rejects the
  /// combination of "unsigned" and "no checksums", because that is a download with nothing
  /// checking it at all.
  case unsigned
}

/// A published list of digests to check the download against.
public enum ChecksumSource: Sendable, Codable, Equatable {
  /// A file published as an asset of the same release (goreleaser's `checksums.txt` and its
  /// variants).
  case releaseAsset(namePattern: String)
  case url(String)

  public var host: String? {
    switch self {
    case .releaseAsset: nil
    case .url(let string): URL(string: string)?.host
    }
  }
}

// MARK: - Which build to install

/// Which version of a program to install.
///
/// The distinction exists because "newest" and "known to work" are not the same claim, and a
/// tunnel is the wrong place to find out. A plugin states the version it was built and tested
/// against; that is what installs by default, and anything newer is an offer rather than a
/// prompt.
public enum ToolChannel: String, Sendable, Codable, Equatable, CaseIterable {
  /// The version the declaring plugin was tested against. The default.
  case recommended
  /// Whatever the vendor has published most recently.
  case latest

  public var displayName: String {
    switch self {
    case .recommended: "Recommended"
    case .latest: "Latest"
    }
  }
}

/// The version a plugin says it works with.
///
/// **Declared by the plugin, and only by the plugin.** Nothing central tracks which version of
/// cloudflared is good — the service that runs cloudflared is the only thing that knows what it
/// was tested against, and it ships that knowledge in its own manifest. A registry of blessed
/// versions maintained beside the plugins would be a second place to update and a first place
/// to forget, and a third-party plugin could never write to it anyway.
///
/// Because it is part of the manifest, it travels with whatever ships the plugin: updating the
/// server updates the recommendation, and the next install picks it up. Only the version does —
/// the bytes are still fetched on demand, which is the whole reason this mechanism exists.
public struct RecommendedBuild: Sendable, Codable, Equatable {

  /// The vendor's version, as it appears in their release tag.
  public let version: String

  /// SHA-256 of each architecture's download, keyed by architecture.
  ///
  /// Optional, and worth filling in: these digests ship inside the signed application, so
  /// they are the one check on a download whose trust does NOT come from the same host that
  /// served it. A vendor's own checksums file proves the download matches the release
  /// metadata; both arrive over the same connection from the same place.
  ///
  /// Keyed by `ToolArchitecture.rawValue` rather than by the enum, so the JSON a third-party
  /// manifest carries is `{"arm64": "…"}` rather than the array form Swift encodes a
  /// non-string-keyed dictionary as.
  public let digests: [String: String]?

  public init(version: String, digests: [String: String]? = nil) {
    self.version = version
    self.digests = digests
  }

  public func digest(for architecture: ToolArchitecture) -> String? {
    digests?[architecture.rawValue]
  }
}

/// How to ask an installed binary what version it is.
///
/// Needed for the rolling sources, where it is the ONLY way to know — and useful everywhere
/// else as a smoke test, because running the thing once at install time is what turns a
/// wrong-architecture download into a clear message instead of a tunnel that fails to start
/// hours later.
public struct VersionProbe: Sendable, Codable, Equatable {
  public let arguments: [String]
  /// Seconds. Small on purpose: a `--version` that takes longer than this is not going to
  /// answer at all.
  public let timeoutSeconds: Double

  public init(arguments: [String] = ["--version"], timeoutSeconds: Double = 10) {
    self.arguments = arguments
    self.timeoutSeconds = timeoutSeconds
  }
}

// MARK: - The descriptor

/// One external program a service needs, and everything the host must know to manage it.
public struct ManagedToolDescriptor: Sendable, Codable, Equatable, Identifiable {

  /// Stable, and used as a DIRECTORY NAME — hence `isWellFormed` below. Tools are keyed
  /// globally rather than per service on purpose: two services wanting cloudflared should
  /// share one install, one update and one 38 MB download.
  public let id: String
  public let displayName: String
  /// One line, shown next to the install button.
  public let summary: String
  /// The name the executable is installed under, and the name looked for inside an archive.
  public let executableName: String
  /// Where a user goes to read about it, or to download it by hand for an offline install.
  public let homepage: URL?
  public let source: ToolSource
  /// One per architecture. A machine whose architecture is not listed cannot install it,
  /// which is a clear message rather than a download that will not execute.
  public let builds: [ToolBuild]
  public let signature: SignaturePolicy
  public let checksums: ChecksumSource?
  /// The version installed by default. See `RecommendedBuild`.
  ///
  /// Nil means there is nothing to recommend, and for a `.rollingURL` source that is not a
  /// choice: a vendor publishing one URL that always serves its current build offers no way
  /// to ask for a particular version, so the only thing installable is whatever is there.
  public let recommended: RecommendedBuild?
  public let versionProbe: VersionProbe

  public init(
    id: String,
    displayName: String,
    summary: String,
    executableName: String,
    homepage: URL? = nil,
    source: ToolSource,
    builds: [ToolBuild],
    signature: SignaturePolicy,
    checksums: ChecksumSource? = nil,
    recommended: RecommendedBuild? = nil,
    versionProbe: VersionProbe = VersionProbe()
  ) {
    self.id = id
    self.displayName = displayName
    self.summary = summary
    self.executableName = executableName
    self.homepage = homepage
    self.source = source
    self.builds = builds
    self.signature = signature
    self.checksums = checksums
    self.recommended = recommended
    self.versionProbe = versionProbe
  }

  /// The build for an architecture, if there is one.
  public func build(for architecture: ToolArchitecture) -> ToolBuild? {
    builds.first { $0.architecture == architecture }
  }

  /// The first build this machine can actually run, given the architectures it can execute.
  ///
  /// Ordered by the caller — native first, then anything translation can cover — so the
  /// preference lives with the host that knows about Rosetta rather than in the manifest.
  public func build(preferring order: [ToolArchitecture]) -> ToolBuild? {
    for architecture in order {
      if let build = build(for: architecture) { return build }
    }
    return nil
  }

  /// Whether a particular version can be asked for at all.
  ///
  /// A GitHub release has a tag to address; a rolling URL has nothing but "now". A manifest
  /// recommending a version it cannot request is refused at validation rather than falling
  /// back quietly, because a recommendation that never applies is indistinguishable from one
  /// that does until someone compares versions by hand.
  public var supportsVersionSelection: Bool {
    switch source {
    case .gitHubReleases: true
    case .rollingURL: false
    }
  }

  /// Every host a check or a download reaches, for the entitlement check.
  public var networkHosts: Set<String> {
    var hosts = source.hosts
    for build in builds {
      if let host = build.download.host { hosts.insert(host) }
    }
    if let host = checksums?.host { hosts.insert(host) }
    return hosts
  }

  /// Whether this is a plausible identifier.
  ///
  /// Checked rather than trusted because it becomes a path component: an id containing a
  /// separator or a `..` would let a manifest write outside its own tool directory.
  public var isWellFormed: Bool {
    !id.isEmpty
      && id.count <= 64
      && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
      && !id.hasPrefix(".")
      && !id.contains("..")
      && !executableName.isEmpty
      && !executableName.contains("/")
  }
}

// MARK: - Name matching

/// `*`-only glob matching for release asset names.
///
/// Deliberately not `NSRegularExpression`: these patterns come out of a manifest that may have
/// arrived as JSON from a third party, and a regular expression from an untrusted source is a
/// denial-of-service waiting for the right input. `*` is all the expressiveness an asset name
/// needs, and it cannot backtrack.
public enum GlobPattern {

  public static func matches(_ pattern: String, _ candidate: String) -> Bool {
    // Segment-wise: the pattern is split on `*`, and each literal segment must appear in
    // order. Anchoring depends on whether the pattern starts or ends with `*`.
    let segments = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    guard segments.count > 1 else { return pattern == candidate }

    var remainder = Substring(candidate)

    if let first = segments.first, !first.isEmpty {
      guard remainder.hasPrefix(first) else { return false }
      remainder = remainder.dropFirst(first.count)
    }
    if let last = segments.last, !last.isEmpty {
      guard remainder.hasSuffix(last), remainder.count >= last.count else { return false }
      remainder = remainder.dropLast(last.count)
    }
    for segment in segments.dropFirst().dropLast() where !segment.isEmpty {
      guard let range = remainder.range(of: segment) else { return false }
      remainder = remainder[range.upperBound...]
    }
    return true
  }
}
