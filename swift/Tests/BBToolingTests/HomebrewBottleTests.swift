//  HomebrewBottleTests
//  A vendor whose only macOS build is the one Homebrew makes, faked at the registry boundary.
//
//  The registry is stubbed; everything under it — the tarball, the digest, unpacking, running
//  the binary — happens for real, as in `ToolInstallTests`. The three things that matter:
//
//    1. The newest version is found on the LAST page of the tag list, not the first. The
//       registry pages at a hundred, oldest first; reading one page reports a version a year
//       stale and nobody notices until an update that should exist never appears.
//    2. The bottle chosen is a macOS one for this architecture, built on the oldest macOS in
//       the index, so a Sonoma Mac is never handed a Tahoe build.
//    3. An unsigned bottle is adopted because the registry's digest matched, and refused when
//       it does not — the digest is the verification, and it has to actually be checked.

import BBServiceKit
import Foundation
import Testing

@testable import BBTooling

@Suite("Homebrew bottles", .serialized)
struct HomebrewBottleTests {

  private static let formula = "faketool"
  private static let registry = "https://ghcr.io/v2/homebrew/core/faketool"
  private static let token = ["Authorization": HomebrewRegistry.anonymousAuthorization]

  private func descriptor(recommended: RecommendedBuild? = nil) -> ManagedToolDescriptor {
    ManagedToolDescriptor(
      id: Self.formula,
      displayName: "Fake Tool",
      summary: "A program Homebrew builds.",
      executableName: Self.formula,
      source: .homebrewBottle(formula: Self.formula),
      builds: [
        ToolBuild(architecture: .arm64, download: .homebrewBottle, archive: .tarGzip),
        ToolBuild(architecture: .x86_64, download: .homebrewBottle, archive: .tarGzip),
      ],
      signature: .unsigned,
      recommended: recommended,
      versionProbe: VersionProbe(arguments: ["version"], timeoutSeconds: 5)
    )
  }

  /// The platform strings the resolver will look for on THIS machine.
  private var hostArchitecture: String {
    ToolArchitecture.runnable.first == .arm64 ? "arm64" : "amd64"
  }

  /// One bottle entry in an index, in the shape Homebrew publishes.
  private func entry(
    name: String, os: String, architecture: String, osVersion: String, digest: String
  ) -> String {
    """
    {"mediaType": "application/vnd.oci.image.manifest.v1+json",
     "digest": "sha256:\(String(repeating: "1", count: 64))", "size": 1,
     "platform": {"architecture": "\(architecture)", "os": "\(os)", "os.version": "\(osVersion)"},
     "annotations": {"org.opencontainers.image.ref.name": "\(name)",
                     "sh.brew.bottle.digest": "\(digest)", "sh.brew.bottle.size": "1"}}
    """
  }

  /// An index whose macOS bottles for this architecture were built on Tahoe AND Sonoma, and
  /// which also carries a Linux build — the shape that trips a naive "first match".
  private func index(version: String, digest: String, decoy: String) -> Data {
    let entries = [
      entry(
        name: "\(version).\(hostArchitecture)_linux", os: "linux", architecture: hostArchitecture,
        osVersion: "Ubuntu 22.04.5", digest: decoy),
      entry(
        name: "\(version).\(hostArchitecture)_tahoe", os: "darwin", architecture: hostArchitecture,
        osVersion: "macOS 26", digest: decoy),
      entry(
        name: "\(version).\(hostArchitecture)_sonoma", os: "darwin", architecture: hostArchitecture,
        osVersion: "macOS 14.8", digest: digest),
    ]
    return Data(
      """
      {"schemaVersion": 2, "manifests": [\(entries.joined(separator: ","))],
       "annotations": {"org.opencontainers.image.version": "\(version)",
                       "org.opencontainers.image.created": "2026-08-20T19:41:10Z"}}
      """.utf8)
  }

  /// A registry holding `versions`, paged one tag per page, each version served as a real
  /// tarball with a real digest.
  private func registry(
    versions: [String], corruptDigestFor corrupt: String? = nil
  ) throws -> StubTransport {
    var transport = StubTransport()

    // The tag list, one tag per page, oldest first, linked by `Link` headers.
    for (index, version) in versions.enumerated() {
      let url =
        index == 0
        ? "\(Self.registry)/tags/list?n=1000"
        : "\(Self.registry)/tags/list?last=\(versions[index - 1])&n=1000"
      transport.bodies[url] = Data(
        "{\"name\": \"homebrew/core/faketool\", \"tags\": [\"\(version)\"]}".utf8)
      transport.requiredRequestHeaders[url] = Self.token
      if index + 1 < versions.count {
        transport.headers[url] = [
          "Link": "</v2/homebrew/core/faketool/tags/list?last=\(version)&n=1000>; rel=\"next\""
        ]
      }
    }

    for version in versions {
      let staging = try ToolFixtures.temporaryDirectory()
      // Homebrew's layout: <formula>/<version>/bin/<executable>. Packed from its own
      // directory so the archive being written is not swept into itself.
      let payload = staging.appendingPathComponent("payload", isDirectory: true)
      let bin = payload.appendingPathComponent("\(Self.formula)/\(version)/bin", isDirectory: true)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      _ = try ToolFixtures.fakeExecutable(named: Self.formula, version: version, in: bin)
      let archive = staging.appendingPathComponent("bottle.tar.gz")
      try ToolFixtures.tarGzip(contentsOf: payload, to: archive)

      let real = try ToolFixtures.sha256Hex(of: archive)
      let published = version == corrupt ? String(repeating: "0", count: 64) : real
      let decoy = String(repeating: "f", count: 64)

      let indexURL = "\(Self.registry)/manifests/\(version)"
      transport.bodies[indexURL] = index(version: version, digest: published, decoy: decoy)
      transport.requiredRequestHeaders[indexURL] = Self.token

      let blobURL = "\(Self.registry)/blobs/sha256:\(published)"
      transport.bodies[blobURL] = try Data(contentsOf: archive)
      transport.requiredRequestHeaders[blobURL] = Self.token
    }
    return transport
  }

  @Test("The newest version is on the last page of the tag list")
  func newestIsFoundAcrossPages() async throws {
    let transport = try registry(versions: ["1.90.3", "1.98.10", "1.102.3"])
    let release = try await ReleaseResolver(transport: transport).resolve(descriptor())

    #expect(release.version == "1.102.3")
    #expect(release.isVersionKnownInAdvance)
    #expect(release.channel == .latest)
    #expect(release.requestHeaders["Authorization"] == HomebrewRegistry.anonymousAuthorization)
  }

  @Test("The oldest macOS bottle for this architecture is chosen, never the Linux one")
  func picksOldestMacOSBottle() async throws {
    let transport = try registry(versions: ["1.102.3"])
    let release = try await ReleaseResolver(transport: transport).resolve(descriptor())

    // The Sonoma bottle's digest is the real one; Tahoe and Linux share a decoy.
    let decoy = String(repeating: "f", count: 64)
    #expect(release.publishedDigest != decoy)
    let expectedSuffix = "sha256:\(release.publishedDigest ?? "")"
    #expect(release.downloadURL.absoluteString.hasSuffix(expectedSuffix))
  }

  @Test("A recommended version is fetched by tag and carries both digests")
  func recommendedVersionIsAddressable() async throws {
    let transport = try registry(versions: ["1.90.3", "1.102.3"])
    let probe = try await ReleaseResolver(transport: transport).resolve(
      descriptor(), channel: .latest)
    // Pin the OLDER version, which a latest-only resolver could never reach.
    let pin = String(repeating: "a", count: 64)
    let older = try await ReleaseResolver(transport: transport).resolve(
      descriptor(
        recommended: RecommendedBuild(version: "1.90.3", digests: ["arm64": pin, "x86_64": pin])
      ),
      channel: .recommended)

    #expect(probe.version == "1.102.3")
    #expect(older.version == "1.90.3")
    #expect(older.channel == .recommended)
    #expect(older.pinnedDigest == pin)
    #expect(older.publishedDigest != nil)
  }

  @Test("A recommended version the registry no longer has falls back, and says so")
  func missingRecommendationFallsBack() async throws {
    var transport = try registry(versions: ["1.102.3"])
    transport.statusCodes["\(Self.registry)/manifests/1.90.3"] = 404
    let release = try await ReleaseResolver(transport: transport).resolve(
      descriptor(recommended: RecommendedBuild(version: "1.90.3")),
      channel: .recommended)

    #expect(release.version == "1.102.3")
    #expect(release.channel == .latest)
    #expect(release.pinnedDigest == nil)
    #expect(release.recommendationUnavailable?.contains("1.90.3") == true)
  }

  @Test("An unsigned bottle installs because the registry's digest matched")
  func installsByPublishedDigest() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let transport = try registry(versions: ["1.102.3"])
    let manager = ToolManager(store: ToolStore(root: root), transport: transport)
    let tool = descriptor()
    await manager.register(tool)

    let installed = try await manager.install(tool.id, channel: .latest)
    #expect(installed.version == "1.102.3")
    #expect(installed.executablePath.hasSuffix("/bin/\(Self.formula)"))
    #expect(FileManager.default.isExecutableFile(atPath: installed.executablePath))
    // The token went to the registry, and only the registry.
    let blob = "\(Self.registry)/blobs/sha256:\(installed.sha256 ?? "")"
    #expect(
      transport.sentHeaders[blob]?["Authorization"] == HomebrewRegistry.anonymousAuthorization)
  }

  @Test("A bottle whose bytes do not match the registry's digest is refused")
  func mismatchedDigestIsRefused() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let transport = try registry(versions: ["1.102.3"], corruptDigestFor: "1.102.3")
    let manager = ToolManager(store: ToolStore(root: root), transport: transport)
    let tool = descriptor()
    await manager.register(tool)

    await #expect(throws: ToolError.self) { try await manager.install(tool.id, channel: .latest) }
    #expect(await manager.executablePath(for: tool.id) == nil)
  }

  @Test("Homebrew's revision suffix sorts a rebuild after the version it rebuilds")
  func revisionsOrderAfterTheirVersion() {
    let versions = ["1.66.4-1", "1.66.4", "1.102.3", "1.90.3", "1.66.4_2"]
      .map(HomebrewVersion.init)
    let sorted = versions.sorted().map(\.text)
    #expect(sorted == ["1.66.4", "1.66.4-1", "1.66.4_2", "1.90.3", "1.102.3"])
  }

  @Test("A Link header's next page is resolved against the registry")
  func linkHeaderIsFollowed() {
    let current = URL(string: "https://ghcr.io/v2/homebrew/core/faketool/tags/list?n=1000")!
    let response = ToolHTTPResponse(
      statusCode: 200,
      headers: ["Link": "</v2/homebrew/core/faketool/tags/list?last=1.90.3&n=0>; rel=\"next\""]
    )
    #expect(
      HomebrewRegistry.nextPage(after: response, from: current)?.absoluteString
        == "https://ghcr.io/v2/homebrew/core/faketool/tags/list?last=1.90.3&n=0")
    #expect(HomebrewRegistry.nextPage(after: ToolHTTPResponse(statusCode: 200), from: current) == nil)
  }

  @Test("A versioned formula name maps to the registry's nested path")
  func versionedFormulaPath() {
    let registry = HomebrewRegistry(formula: "python@3.12", transport: StubTransport())
    #expect(registry.repository == "homebrew/core/python/3.12")
  }
}
