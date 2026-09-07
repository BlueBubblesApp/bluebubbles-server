//  ToolInstallTests
//  The install pipeline, end to end, against real archives and a real filesystem.
//
//  Four properties matter here and each has cost someone a day somewhere:
//
//    1. A failed install leaves the working one alone. The tunnel is the only route to the
//       machine; a half-applied update to it is unrecoverable remotely.
//    2. Revert is a symlink repoint, so it works with no network.
//    3. A digest that does not match the published one is refused, and nothing is adopted.
//    4. The binary is RUN before it is adopted, which is the only check that catches a
//       download that is intact, correctly named, and built for the wrong architecture.

import BBServiceKit
import BBTooling
import Foundation
import Testing

@Suite("Managed tool installs", .serialized)
struct ToolInstallTests {

  /// Builds a release of `version` and the transport that serves it.
  private func release(
    version: String,
    descriptor: ManagedToolDescriptor,
    corruptChecksum: Bool = false
  ) throws -> (transport: StubTransport, assetURL: String) {
    let staging = try ToolFixtures.temporaryDirectory()
    let payload = staging.appendingPathComponent("payload", isDirectory: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    _ = try ToolFixtures.fakeExecutable(
      named: descriptor.executableName, version: version, in: payload
    )

    let assetName = ToolFixtures.assetName(id: descriptor.id, version: version)
    let archive = staging.appendingPathComponent(assetName)
    try ToolFixtures.tarGzip(contentsOf: payload, to: archive)

    let assetURL = "https://example.test/\(assetName)"
    let checksumsURL = "https://example.test/checksums.txt"
    let digest =
      corruptChecksum
      ? String(repeating: "0", count: 64)
      : try ToolFixtures.sha256Hex(of: archive)

    var transport = StubTransport()
    transport.bodies["https://api.github.com/repos/example/example/releases/latest"] =
      ToolFixtures.gitHubRelease(
        tag: "v\(version)",
        assets: [
          (assetName, assetURL),
          ("checksums.txt", checksumsURL),
        ]
      )
    transport.bodies[assetURL] = try Data(contentsOf: archive)
    transport.bodies[checksumsURL] = Data("\(digest)  \(assetName)\n".utf8)
    return (transport, assetURL)
  }

  @Test("An install lands under versions/ with current pointing at it")
  func installsAndActivates() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let descriptor = ToolFixtures.unsignedDescriptor()
    let (transport, _) = try release(version: "1.2.3", descriptor: descriptor)

    let manager = ToolManager(store: ToolStore(root: root), transport: transport)
    await manager.register(descriptor)
    let installed = try await manager.install(descriptor.id)

    #expect(installed.version == "1.2.3")
    #expect(installed.architecture == ToolArchitecture.runnable.first)
    #expect(FileManager.default.isExecutableFile(atPath: installed.executablePath))

    // `current` is a symlink, and it resolves to the version that was just installed —
    // the property revert depends on.
    let currentLink = root.appendingPathComponent("\(descriptor.id)/current")
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: currentLink.path)
    #expect(target == "versions/1.2.3-\(installed.architecture.rawValue)")

    // And the manager hands that path out.
    let resolved = await manager.executablePath(for: descriptor.id)
    #expect(resolved == installed.executablePath)
    let status = await manager.status(of: descriptor.id)
    #expect(status?.origin == .managed)
  }

  @Test("A second install keeps the first, and revert goes back to it without a network")
  func revertRepointsTheSymlink() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let store = ToolStore(root: root)
    let descriptor = ToolFixtures.unsignedDescriptor()

    let first = try release(version: "1.0.0", descriptor: descriptor)
    let manager = ToolManager(store: store, transport: first.transport)
    await manager.register(descriptor)
    let old = try await manager.install(descriptor.id)

    // A second manager over the same store, serving a newer release — the shape an update
    // actually takes across launches.
    let second = try release(version: "2.0.0", descriptor: descriptor)
    let updater = ToolManager(store: store, transport: second.transport)
    await updater.register(descriptor)
    let new = try await updater.install(descriptor.id)
    #expect(new.version == "2.0.0")
    #expect(await updater.status(of: descriptor.id)?.canRevert == true)

    // The old version is still on disk, which is what makes the next line offline.
    #expect(FileManager.default.isExecutableFile(atPath: old.executablePath))

    try await updater.revert(descriptor.id)
    let reverted = await updater.status(of: descriptor.id)
    #expect(reverted?.installedVersion == "1.0.0")
    #expect(await updater.executablePath(for: descriptor.id) == old.executablePath)
    // And forward again: reverting sets the version just left as the one to go back to.
    #expect(reverted?.canRevert == true)
  }

  @Test("A download whose digest does not match is refused, and nothing is installed")
  func checksumMismatchIsRefused() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let descriptor = ToolFixtures.unsignedDescriptor()
    let (transport, _) = try release(
      version: "1.0.0", descriptor: descriptor, corruptChecksum: true
    )

    let manager = ToolManager(store: ToolStore(root: root), transport: transport)
    await manager.register(descriptor)

    await #expect(throws: ToolError.self) { try await manager.install(descriptor.id) }
    #expect(await manager.executablePath(for: descriptor.id) == nil)
    // Nothing adopted means no `current` at all, rather than one pointing at a rejected
    // download.
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("\(descriptor.id)/current").path
      ))
  }

  @Test("A failed update leaves the working install exactly where it was")
  func failedUpdateDoesNotDisturbTheCurrentInstall() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let store = ToolStore(root: root)
    let descriptor = ToolFixtures.unsignedDescriptor()

    let good = try release(version: "1.0.0", descriptor: descriptor)
    let manager = ToolManager(store: store, transport: good.transport)
    await manager.register(descriptor)
    let installed = try await manager.install(descriptor.id)

    let bad = try release(version: "2.0.0", descriptor: descriptor, corruptChecksum: true)
    let updater = ToolManager(store: store, transport: bad.transport)
    await updater.register(descriptor)
    await #expect(throws: ToolError.self) { try await updater.install(descriptor.id) }

    // The whole point: the tunnel still has a binary to run.
    #expect(await updater.executablePath(for: descriptor.id) == installed.executablePath)
    #expect(await updater.status(of: descriptor.id)?.installedVersion == "1.0.0")
  }

  @Test("An unsigned binary is refused when the vendor is supposed to sign its builds")
  func unsignedBuildIsRefusedUnderASignaturePolicy() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    // Same fixture, but declared as a vendor that signs — which the shell script does not.
    let signed = ManagedToolDescriptor(
      id: "signedtool",
      displayName: "signedtool",
      summary: "A test program that claims to be signed.",
      executableName: "signedtool",
      source: .gitHubReleases(owner: "example", repository: "example"),
      builds: ToolArchitecture.allCases.map {
        ToolBuild(
          architecture: $0,
          download: .releaseAsset(
            namePattern: "signedtool_*_darwin_\($0 == .arm64 ? "arm64" : "amd64").tar.gz"
          ),
          archive: .tarGzip
        )
      },
      signature: .trustOnFirstUse,
      checksums: .releaseAsset(namePattern: "*checksums*.txt"),
      versionProbe: VersionProbe(arguments: ["version"], timeoutSeconds: 5)
    )
    let (transport, _) = try release(version: "1.0.0", descriptor: signed)

    let manager = ToolManager(store: ToolStore(root: root), transport: transport)
    await manager.register(signed)
    await #expect(throws: ToolError.self) { try await manager.install(signed.id) }
    #expect(await manager.executablePath(for: signed.id) == nil)
  }

  @Test("Old versions are pruned; the current one and its predecessor are kept")
  func pruningKeepsTwo() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let store = ToolStore(root: root)
    let descriptor = ToolFixtures.unsignedDescriptor()

    for version in ["1.0.0", "2.0.0", "3.0.0"] {
      let published = try release(version: version, descriptor: descriptor)
      let manager = ToolManager(store: store, transport: published.transport)
      await manager.register(descriptor)
      _ = try await manager.install(descriptor.id)
    }

    let versions = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("\(descriptor.id)/versions").path
    )
    #expect(versions.count == 2)
    #expect(versions.contains { $0.hasPrefix("3.0.0-") })
    #expect(versions.contains { $0.hasPrefix("2.0.0-") })
  }
}
