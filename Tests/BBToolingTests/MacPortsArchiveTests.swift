//  MacPortsArchiveTests
//  A vendor whose only headless macOS build is the one MacPorts makes, faked at the package
//  server.
//
//  The server is stubbed, and so is the signing key: each test signs its archives with a key
//  it generates, and hands the resolver that key's public half in place of MacPorts' own.
//  Everything under that (the bzip2 tarball, the signature check, unpacking, running the
//  binary) happens for real, as in `ToolInstallTests`. The things that matter:
//
//    1. The archive chosen is the newest revision, built on the oldest macOS that is no
//       newer than this Mac, so a pin is the same file on every Mac and a Sonoma Mac is never
//       handed a Tahoe build.
//    2. "Latest" is the newest version this Mac has an archive for. MacPorts' Intel builders
//       lag its Apple Silicon ones, and the newest version listed is not an update an Intel
//       Mac can take until its archive lands.
//    3. An unsigned program is adopted because MacPorts' signature on the archive verified,
//       and refused when it does not, when it is missing, and when a key this build does not
//       know made it.

import BBServiceKit
import CryptoKit
import Foundation
import Testing

@testable import BBTooling

@Suite("MacPorts archives", .serialized)
struct MacPortsArchiveTests {

  private static let port = "faketool"
  private static let server = "https://packages.macports.org/faketool/"

  /// A signing key standing in for MacPorts', in `signify` form.
  private struct TestKey {
    let privateKey = Curve25519.Signing.PrivateKey()
    let keyNumber = Data((0..<8).map { _ in UInt8.random(in: 0...255) })

    var publicKey: SignifyPublicKey {
      let raw = Data("Ed".utf8) + keyNumber + privateKey.publicKey.rawRepresentation
      return SignifyPublicKey(name: "test-archives.pub", base64: raw.base64EncodedString())!
    }

    func signatureFile(for data: Data, keyName: String = "test-archives.pub") throws -> Data {
      let signature = try privateKey.signature(for: data)
      let raw = Data("Ed".utf8) + keyNumber + signature
      return Data(
        "untrusted comment: verify with \(keyName)\n\(raw.base64EncodedString())\n".utf8)
    }
  }

  private var host: ToolArchitecture { ToolArchitecture.runnable.first ?? .arm64 }

  private func descriptor(recommended: RecommendedBuild? = nil) -> ManagedToolDescriptor {
    ManagedToolDescriptor(
      id: Self.port,
      displayName: "Fake Tool",
      summary: "A program MacPorts builds.",
      executableName: Self.port,
      source: .macPortsArchive(port: Self.port),
      builds: [
        ToolBuild(architecture: .arm64, download: .macPortsArchive, archive: .tarBzip2),
        ToolBuild(architecture: .x86_64, download: .macPortsArchive, archive: .tarBzip2),
      ],
      signature: .unsigned,
      recommended: recommended,
      versionProbe: VersionProbe(arguments: ["version"], timeoutSeconds: 5)
    )
  }

  private func resolver(
    _ transport: StubToolTransport, key: TestKey, darwin: Int = 23
  ) -> ReleaseResolver {
    ReleaseResolver(transport: transport, macPortsKeys: [key.publicKey], hostDarwinMajor: darwin)
  }

  /// An HTML index listing `names`, in the shape the server's directory listing has.
  private func directoryIndex(_ names: [String]) -> Data {
    let rows = names.map { "<tr><td><a href=\"\($0)\">\($0)</a></td></tr>" }
    return Data(
      """
      <html><body><table><tr><th><a href="?C=N;O=D">Name</a></th></tr>
      <tr><td><a href="/">Parent Directory</a></td></tr>
      \(rows.joined(separator: "\n"))
      </table></body></html>
      """.utf8)
  }

  /// A server holding one real, signed archive per name, each a bzip2 tarball in MacPorts'
  /// install-tree layout with the program reporting the archive's version.
  private func server(_ names: [String], key: TestKey) throws -> StubToolTransport {
    var transport = StubToolTransport()
    transport.bodies[Self.server] = directoryIndex(names + names.map { $0 + ".sig" })
    for name in names {
      let archive = try #require(MacPortsArchive.parse(name, port: Self.port))
      let staging = try ToolFixtures.temporaryDirectory()
      let payload = staging.appendingPathComponent("payload", isDirectory: true)
      let bin = payload.appendingPathComponent("opt/local/bin", isDirectory: true)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      _ = try ToolFixtures.fakeExecutable(named: Self.port, version: archive.version, in: bin)
      try Data("+CONTENTS".utf8).write(to: payload.appendingPathComponent("+CONTENTS"))
      let file = staging.appendingPathComponent(name)
      try ToolFixtures.tarBzip2(contentsOf: payload, to: file)

      let bytes = try Data(contentsOf: file)
      transport.bodies[Self.server + name] = bytes
      transport.bodies[Self.server + name + ".sig"] = try key.signatureFile(for: bytes)
    }
    return transport
  }

  private func name(_ version: String, revision: Int = 0, darwin: Int, _ arch: ToolArchitecture)
    -> String
  {
    "\(Self.port)-\(version)_\(revision).darwin_\(darwin).\(arch.rawValue).tbz2"
  }

  // MARK: - Names and listings

  @Test("An archive name is read from the right, so a dotted version survives")
  func archiveNamesParse() throws {
    let archive = try #require(
      MacPortsArchive.parse("faketool-1.104.4_2.darwin_23.x86_64.tbz2", port: "faketool"))
    #expect(archive.version == "1.104.4")
    #expect(archive.revision == 2)
    #expect(archive.darwinMajor == 23)
    #expect(archive.architecture == .x86_64)

    // A variant build, another port whose name starts the same, a signature file and a
    // directory link are not archives of this port.
    for other in [
      "faketool-1.104.4_0+universal.darwin_23.x86_64.tbz2",
      "faketool-extras-1.0_0.darwin_23.arm64.tbz2",
      "faketool-1.104.4_0.darwin_23.arm64.tbz2.sig",
      "faketool-1.104.4_0.darwin_23.noarch.tbz2",
      "/",
    ] {
      #expect(MacPortsArchive.parse(other, port: "faketool") == nil, "\(other)")
    }
  }

  @Test("The newest revision, built on the oldest macOS no newer than this Mac, is chosen")
  func picksOldestUsableBuildOfNewestRevision() {
    let listing = MacPortsListing.parse(
      String(
        decoding: directoryIndex([
          name("1.104.4", darwin: 21, .x86_64),
          name("1.104.4", revision: 1, darwin: 24, .x86_64),
          name("1.104.4", revision: 1, darwin: 22, .x86_64),
          name("1.104.4", revision: 1, darwin: 22, .arm64),
        ]), as: UTF8.self),
      port: Self.port)

    let chosen = listing.archive(version: "1.104.4", architecture: .x86_64, hostDarwinMajor: 23)
    #expect(chosen?.fileName == name("1.104.4", revision: 1, darwin: 22, .x86_64))

    // Only a Sequoia-built archive: not offered to a Sonoma Mac.
    let newerOnly = MacPortsListing.parse(
      String(decoding: directoryIndex([name("1.0.0", darwin: 24, .arm64)]), as: UTF8.self),
      port: Self.port)
    #expect(newerOnly.archive(version: "1.0.0", architecture: .arm64, hostDarwinMajor: 23) == nil)
  }

  @Test("Latest is the newest version this architecture has an archive for")
  func latestSkipsAVersionWhoseBuildHasNotLanded() {
    let listing = MacPortsListing.parse(
      String(
        decoding: directoryIndex([
          name("1.98.10", darwin: 23, .x86_64),
          name("1.104.4", darwin: 23, .x86_64),
          name("1.104.5", darwin: 23, .arm64),
        ]), as: UTF8.self),
      port: Self.port)
    #expect(listing.newest(architecture: .x86_64, hostDarwinMajor: 23)?.version == "1.104.4")
    #expect(listing.newest(architecture: .arm64, hostDarwinMajor: 23)?.version == "1.104.5")
  }

  // MARK: - Resolving

  @Test("A recommended version still on the server is resolved, signature and all")
  func recommendedVersionIsAddressable() async throws {
    let key = TestKey()
    let transport = try server(
      [name("1.98.10", darwin: 23, host), name("1.104.4", darwin: 23, host)], key: key)
    let release = try await resolver(transport, key: key).resolve(
      descriptor(recommended: RecommendedBuild(version: "1.98.10")), channel: .recommended)

    #expect(release.version == "1.98.10")
    #expect(release.channel == .recommended)
    #expect(release.downloadURL.absoluteString == Self.server + name("1.98.10", darwin: 23, host))
    #expect(release.archiveSignature?.url.absoluteString.hasSuffix(".tbz2.sig") == true)
    #expect(release.archiveSignature?.trustedKeys == [key.publicKey])
  }

  @Test("A recommended version the server no longer keeps falls back, and says so")
  func missingRecommendationFallsBack() async throws {
    let key = TestKey()
    let transport = try server([name("1.104.4", darwin: 23, host)], key: key)
    let release = try await resolver(transport, key: key).resolve(
      descriptor(recommended: RecommendedBuild(version: "1.90.3")), channel: .recommended)

    #expect(release.version == "1.104.4")
    #expect(release.channel == .latest)
    #expect(release.pinnedDigest == nil)
    #expect(release.recommendationUnavailable?.contains("1.90.3") == true)
  }

  /// A listing that could not be read says nothing about whether the pin is published.
  @Test("A listing that could not be read is an error, not a fallback")
  func failedListingDoesNotFallBack() async throws {
    let key = TestKey()
    var transport = StubToolTransport()
    transport.statusCodes[Self.server] = 503
    await #expect(throws: ToolError.self) {
      _ = try await resolver(transport, key: key).resolve(
        self.descriptor(recommended: RecommendedBuild(version: "1.90.3")),
        channel: .recommended)
    }
  }

  @Test("A port with nothing this Mac can run says which archives it does have")
  func noArchiveForThisMac() async throws {
    let other: ToolArchitecture = host == .arm64 ? .x86_64 : .arm64
    let key = TestKey()
    let transport = try server([name("1.104.4", darwin: 23, other)], key: key)
    do {
      _ = try await resolver(transport, key: key).resolve(descriptor(), channel: .latest)
      Issue.record("resolved an archive for the wrong architecture")
    } catch ToolError.assetNotFound(_, _, let available) {
      #expect(available == [name("1.104.4", darwin: 23, other)])
    }
  }

  // MARK: - Installing

  private func install(
    _ transport: StubToolTransport, key: TestKey
  ) async throws -> (InstalledBuild, ToolStore) {
    let store = ToolStore(root: try ToolFixtures.temporaryDirectory())
    let release = try await resolver(transport, key: key).resolve(descriptor(), channel: .latest)
    let installed = try await ToolInstaller(transport: transport, store: store).install(
      descriptor(), release: release, pinnedTeamID: nil
    ) { _ in }
    return (installed, store)
  }

  @Test("An unsigned program installs because MacPorts' signature on its archive verified")
  func installsBySignedArchive() async throws {
    let key = TestKey()
    let transport = try server([name("1.104.4", darwin: 23, host)], key: key)
    let (installed, _) = try await install(transport, key: key)

    #expect(installed.version == "1.104.4")
    #expect(installed.executablePath.hasSuffix("/opt/local/bin/\(Self.port)"))
    #expect(FileManager.default.isExecutableFile(atPath: installed.executablePath))
  }

  @Test("An archive whose bytes do not match its signature is refused")
  func tamperedArchiveIsRefused() async throws {
    let key = TestKey()
    let file = name("1.104.4", darwin: 23, host)
    var transport = try server([file], key: key)
    var bytes = try #require(transport.bodies[Self.server + file])
    bytes[bytes.count / 2] ^= 0xFF
    transport.bodies[Self.server + file] = bytes

    await #expect(throws: ToolError.self) { _ = try await install(transport, key: key) }
  }

  @Test("An archive with no signature published is refused, not installed unchecked")
  func missingSignatureIsRefused() async throws {
    let key = TestKey()
    let file = name("1.104.4", darwin: 23, host)
    var transport = try server([file], key: key)
    transport.bodies[Self.server + file + ".sig"] = nil

    await #expect(throws: ToolError.self) { _ = try await install(transport, key: key) }
  }

  /// What a rotated MacPorts key looks like to a build that predates it: a valid signature
  /// by a key nobody shipped. It must refuse, and the reason must name the key, because the
  /// remedy is a release carrying it.
  @Test("An archive signed by a key this build does not know is refused, naming the key")
  func unknownKeyIsRefused() async throws {
    let key = TestKey()
    let successor = TestKey()
    let file = name("1.104.4", darwin: 23, host)
    var transport = try server([file], key: key)
    let bytes = try #require(transport.bodies[Self.server + file])
    transport.bodies[Self.server + file + ".sig"] = try successor.signatureFile(
      for: bytes, keyName: "macports-archives-2099.pub")

    do {
      _ = try await install(transport, key: key)
      Issue.record("installed an archive signed by an untrusted key")
    } catch ToolError.signatureInvalid(_, let reason) {
      #expect(reason.contains("macports-archives-2099.pub"))
    }
  }

  // MARK: - The real key

  /// The key is decoded from base64 at startup and a typo would leave the list empty, which
  /// refuses every install as "signed by a key this version does not trust".
  @Test("MacPorts' archive key decodes")
  func shippedKeyDecodes() {
    #expect(MacPortsRepository.archiveKeys.map(\.name) == ["macports-archives-2025.pub"])
  }

  @Test("This Mac's Darwin major is read, and is at least Sonoma's")
  func hostDarwinMajorIsRead() {
    #expect(MacPortsRepository.hostDarwinMajor >= 23)
    #expect(MacPortsRepository.hostDarwinMajor < 100)
  }
}
