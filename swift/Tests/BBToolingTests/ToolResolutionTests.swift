//  ToolResolutionTests
//  Choosing a build, finding the release, and deciding whether anything newer exists.
//
//  The architecture cases are the ones worth having: an x86_64 asset on an Apple Silicon Mac
//  is installable only if Rosetta is there, an arm64 asset on an Intel Mac never is, and both
//  failures look identical at the point they bite — a process that launches and immediately
//  dies — unless they are separated here, before anything is downloaded.

import BBServiceKit
import Darwin
import Foundation
import Testing

@testable import BBTooling

@Suite("Architecture selection")
struct ArchitectureSelectionTests {

  private func descriptor(_ architectures: [ToolArchitecture]) -> ManagedToolDescriptor {
    ManagedToolDescriptor(
      id: "tool",
      displayName: "tool",
      summary: "",
      executableName: "tool",
      source: .rollingURL,
      builds: architectures.map {
        ToolBuild(
          architecture: $0,
          download: .url("https://example.test/\($0.rawValue).zip"),
          archive: .zip
        )
      },
      signature: .trustOnFirstUse
    )
  }

  @Test("The native build wins when both are published")
  func nativeWins() {
    let tool = descriptor([.x86_64, .arm64])
    #expect(tool.build(preferring: [.arm64, .x86_64])?.architecture == .arm64)
    #expect(tool.build(preferring: [.x86_64])?.architecture == .x86_64)
  }

  @Test("An Intel build is acceptable on Apple Silicon, but only as a fallback")
  func intelFallback() {
    let tool = descriptor([.x86_64])
    // The order is supplied by the host, which is what knows whether Rosetta is present.
    #expect(tool.build(preferring: [.arm64, .x86_64])?.architecture == .x86_64)
    #expect(tool.build(preferring: [.arm64]) == nil)
  }

  @Test("An arm64-only tool has no build for an Intel Mac")
  func noBuildForIntel() {
    #expect(descriptor([.arm64]).build(preferring: [.x86_64]) == nil)
  }

  @Test("The runnable list never offers arm64 to an Intel Mac")
  func runnableOrder() {
    // Whatever this machine is, the invariant holds in both directions: the native
    // architecture is first, and translation is never claimed in the impossible direction.
    let runnable = ToolArchitecture.runnable
    #expect(runnable.first == ToolArchitecture.host)
    if ToolArchitecture.host == .x86_64 {
      #expect(!runnable.contains(.arm64))
    }
  }
}

@Suite("Release resolution")
struct ReleaseResolutionTests {

  private let latest = "https://api.github.com/repos/example/example/releases/latest"

  private func gitHubTool(prereleases: Bool = false) -> ManagedToolDescriptor {
    ManagedToolDescriptor(
      id: "tool",
      displayName: "tool",
      summary: "",
      executableName: "tool",
      source: .gitHubReleases(
        owner: "example", repository: "example", allowPrereleases: prereleases
      ),
      builds: ToolArchitecture.allCases.map {
        ToolBuild(
          architecture: $0,
          download: .releaseAsset(
            namePattern: "tool_*_darwin_\($0 == .arm64 ? "arm64" : "amd64").tar.gz"
          ),
          archive: .tarGzip
        )
      },
      signature: .unsigned,
      checksums: .releaseAsset(namePattern: "*checksums*.txt")
    )
  }

  private var assetSuffix: String {
    ToolArchitecture.runnable.first == .arm64 ? "arm64" : "amd64"
  }

  @Test("An asset is matched by pattern, so a version in its name does not break it")
  func matchesVersionedAssetName() async throws {
    var transport = StubTransport()
    transport.bodies[latest] = ToolFixtures.gitHubRelease(
      tag: "v1.0.4",
      assets: [
        ("tool_1.0.4_darwin_\(assetSuffix).tar.gz", "https://example.test/tool.tar.gz"),
        ("tool_1.0.4_checksums.txt", "https://example.test/checksums.txt"),
        ("tool_1.0.4_linux_amd64.tar.gz", "https://example.test/linux.tar.gz"),
      ]
    )

    let release = try await ReleaseResolver(transport: transport).resolve(gitHubTool())
    #expect(release.version == "1.0.4")
    #expect(release.downloadURL.absoluteString == "https://example.test/tool.tar.gz")
    #expect(release.checksumsURL?.absoluteString == "https://example.test/checksums.txt")
    #expect(release.isVersionKnownInAdvance)
  }

  @Test("A release with no matching asset names what it does have")
  func reportsAvailableAssets() async throws {
    var transport = StubTransport()
    transport.bodies[latest] = ToolFixtures.gitHubRelease(
      tag: "v1.0.4",
      assets: [("tool_1.0.4_windows_amd64.zip", "https://example.test/win.zip")]
    )

    await #expect(throws: ToolError.self) {
      try await ReleaseResolver(transport: transport).resolve(gitHubTool())
    }
  }

  @Test("Newest by version, not by the order GitHub lists them")
  func picksNewestByVersion() async throws {
    // The list endpoint returns creation order, and a patch cut for an older branch after
    // a newer release appears first. Sorted lexically, 1.9.0 also beats 1.10.0.
    let body = Data(
      """
      [
        {"tag_name": "v1.9.0", "draft": false, "prerelease": false, "assets": [
          {"name": "tool_1.9.0_darwin_\(assetSuffix).tar.gz",
           "browser_download_url": "https://example.test/old.tar.gz"}]},
        {"tag_name": "v1.10.0", "draft": false, "prerelease": false, "assets": [
          {"name": "tool_1.10.0_darwin_\(assetSuffix).tar.gz",
           "browser_download_url": "https://example.test/new.tar.gz"}]}
      ]
      """.utf8)
    var transport = StubTransport()
    transport.bodies["https://api.github.com/repos/example/example/releases?per_page=10"] = body

    let release = try await ReleaseResolver(transport: transport)
      .resolve(gitHubTool(prereleases: true))
    #expect(release.version == "1.10.0")
    #expect(release.downloadURL.absoluteString == "https://example.test/new.tar.gz")
  }

  @Test("GitHub's rate limit is reported as itself, not as a network failure")
  func rateLimitIsExplained() async throws {
    var transport = StubTransport()
    transport.statusCodes[latest] = 403
    transport.bodies[latest] = Data()

    do {
      _ = try await ReleaseResolver(transport: transport).resolve(gitHubTool())
      Issue.record("expected a lookup failure")
    } catch let error as ToolError {
      #expect(error.description.contains("rate limiting"))
    }
  }

  @Test("A rolling source reports the URL's validator instead of a version")
  func rollingUsesValidators() async throws {
    let url = "https://example.test/\(ToolArchitecture.runnable.first!.rawValue).zip"
    var transport = StubTransport()
    transport.headers[url] = ["ETag": "\"abc123\""]

    let tool = ManagedToolDescriptor(
      id: "tool",
      displayName: "tool",
      summary: "",
      executableName: "tool",
      source: .rollingURL,
      builds: ToolArchitecture.allCases.map {
        ToolBuild(
          architecture: $0,
          download: .url("https://example.test/\($0.rawValue).zip"),
          archive: .zip
        )
      },
      signature: .trustOnFirstUse
    )

    let release = try await ReleaseResolver(transport: transport).resolve(tool)
    #expect(!release.isVersionKnownInAdvance)
    #expect(release.version == ResolvedRelease.unknownVersion)
    #expect(release.validator == "\"abc123\"")
  }
}

@Suite("Where a tool's executable comes from")
struct ToolResolutionOrderTests {

  private func installedState(
    toolID: String, at path: String, root: URL
  ) throws -> ToolStore {
    let store = ToolStore(root: root)
    var state = ToolState(toolID: toolID)
    state.installed = InstalledBuild(
      version: "1.0.0",
      architecture: .host,
      executablePath: path,
      sourceURL: "https://example.test/tool.tar.gz"
    )
    try store.save(state)
    return store
  }

  @Test("A binary the user chose beats the managed install, which beats the bundled copy")
  func precedence() async throws {
    let directory = try ToolFixtures.temporaryDirectory()
    let managed = try ToolFixtures.fakeExecutable(named: "managed", version: "1", in: directory)
    let chosen = try ToolFixtures.fakeExecutable(named: "chosen", version: "2", in: directory)
    let bundled = try ToolFixtures.fakeExecutable(named: "bundled", version: "3", in: directory)

    let root = try ToolFixtures.temporaryDirectory()
    let store = try installedState(toolID: "tool", at: managed.path, root: root)
    let descriptor = ToolFixtures.unsignedDescriptor(id: "tool", executableName: "tool")

    let manager = ToolManager(
      store: store,
      transport: StubTransport(),
      bundledLocator: { _ in bundled.path }
    )
    await manager.register(descriptor)

    #expect(await manager.executablePath(for: "tool") == managed.path)

    try await manager.adoptExternalBinary(at: chosen.path, for: "tool")
    #expect(await manager.executablePath(for: "tool") == chosen.path)
    #expect(await manager.status(of: "tool")?.origin == .external)

    try await manager.clearExternalBinary(for: "tool")
    #expect(await manager.executablePath(for: "tool") == managed.path)
  }

  @Test("With nothing installed, the bundled copy is used and reported as such")
  func bundledFallback() async throws {
    let directory = try ToolFixtures.temporaryDirectory()
    let bundled = try ToolFixtures.fakeExecutable(named: "tool", version: "1", in: directory)
    let root = try ToolFixtures.temporaryDirectory()

    let manager = ToolManager(
      store: ToolStore(root: root),
      transport: StubTransport(),
      bundledLocator: { _ in bundled.path }
    )
    await manager.register(ToolFixtures.unsignedDescriptor(id: "tool", executableName: "tool"))

    #expect(await manager.executablePath(for: "tool") == bundled.path)
    #expect(await manager.status(of: "tool")?.origin == .bundled)
  }

  @Test("An install recorded in state but missing from disk reads as not installed")
  func stalePathsAreNotBelieved() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let store = try installedState(
      toolID: "tool", at: "/nowhere/at/all/tool", root: root
    )
    // The state file still says it is installed; the filesystem disagrees, and the
    // filesystem is right. Believing the file hands a tunnel a path to nothing.
    #expect(store.load("tool").installed == nil)
  }

  @Test("A binary that is not executable is refused as a chosen one")
  func refusesUnusableExternalBinary() async throws {
    let directory = try ToolFixtures.temporaryDirectory()
    let plain = directory.appendingPathComponent("notes.txt")
    try "hello".write(to: plain, atomically: true, encoding: .utf8)

    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: StubTransport()
    )
    await manager.register(ToolFixtures.unsignedDescriptor(id: "tool", executableName: "tool"))

    await #expect(throws: ToolError.self) {
      try await manager.adoptExternalBinary(at: plain.path, for: "tool")
    }
  }
}

@Suite("Update checks")
struct ToolUpdateCheckTests {

  @Test("A newer version is reported and nothing is installed")
  func reportsWithoutInstalling() async throws {
    let directory = try ToolFixtures.temporaryDirectory()
    let installed = try ToolFixtures.fakeExecutable(named: "tool", version: "1.9.0", in: directory)
    let root = try ToolFixtures.temporaryDirectory()

    let store = ToolStore(root: root)
    var state = ToolState(toolID: "tool")
    state.installed = InstalledBuild(
      version: "1.9.0",
      architecture: .host,
      executablePath: installed.path,
      sourceURL: "https://example.test/tool.tar.gz"
    )
    try store.save(state)

    let suffix = ToolArchitecture.runnable.first == .arm64 ? "arm64" : "amd64"
    var transport = StubTransport()
    transport.bodies["https://api.github.com/repos/example/example/releases/latest"] =
      ToolFixtures.gitHubRelease(
        tag: "v1.10.0",
        assets: [
          ("tool_1.10.0_darwin_\(suffix).tar.gz", "https://example.test/tool.tar.gz"),
          ("checksums.txt", "https://example.test/checksums.txt"),
        ]
      )

    let manager = ToolManager(store: store, transport: transport)
    await manager.register(ToolFixtures.unsignedDescriptor(id: "tool", executableName: "tool"))

    let update = try await manager.checkForUpdate("tool")
    // 1.10.0 IS newer than 1.9.0 — the comparison string ordering gets backwards, and the
    // symptom would be a server sitting on an old tunnel forever with nothing to show.
    #expect(update?.version == "1.10.0")
    // And the whole point: still running what it was running.
    #expect(await manager.executablePath(for: "tool") == installed.path)
    #expect(await manager.status(of: "tool")?.installedVersion == "1.9.0")
  }

  @Test("Nothing installed means nothing to update")
  func noInstallNoUpdate() async throws {
    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: StubTransport()
    )
    await manager.register(ToolFixtures.unsignedDescriptor(id: "tool", executableName: "tool"))
    #expect(try await manager.checkForUpdate("tool") == nil)
  }
}

@Suite("Unpacking and making runnable")
struct UnpackingTests {

  @Test("A zip is unpacked and the executable found inside it")
  func unpacksZip() async throws {
    let staging = try ToolFixtures.temporaryDirectory()
    let payload = staging.appendingPathComponent("payload", isDirectory: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    _ = try ToolFixtures.fakeExecutable(named: "tool", version: "1.0", in: payload)

    let archive = staging.appendingPathComponent("tool.zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = payload
    zip.arguments = ["-q", "-r", archive.path, "."]
    try zip.run()
    zip.waitUntilExit()

    let destination = staging.appendingPathComponent("unpacked", isDirectory: true)
    let executable = try Unpacking.unpack(
      archive,
      format: .zip,
      into: destination,
      executableName: "tool",
      pathInArchive: nil,
      toolID: "tool"
    )
    try Unpacking.makeRunnable(executable)
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
  }

  @Test("Quarantine is removed, because a quarantined program does not run unattended")
  func stripsQuarantine() async throws {
    let directory = try ToolFixtures.temporaryDirectory()
    let executable = try ToolFixtures.fakeExecutable(named: "tool", version: "1.0", in: directory)

    // The attribute a browser or an unpacker would have left behind.
    let value = "0083;00000000;Safari;"
    _ = value.withCString { bytes in
      executable.path.withCString { path in
        setxattr(path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0)
      }
    }
    #expect(getxattr(executable.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)

    try Unpacking.makeRunnable(executable)
    #expect(getxattr(executable.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
  }
}

@Suite("Parsing what vendors publish")
struct ToolParsingTests {

  @Test("A checksums listing is read whatever shape the vendor writes it in")
  func readsChecksumListings() {
    let listing = """
      aaaa  tool_1.0.0_linux_amd64.tar.gz
      bbbb *tool_1.0.0_darwin_arm64.tar.gz
      cccc  ./dist/tool_1.0.0_darwin_amd64.tar.gz
      """
    #expect(ToolInstaller.digest(for: "tool_1.0.0_darwin_arm64.tar.gz", in: listing) == "bbbb")
    // A path rather than a bare name, which goreleaser has produced in both forms.
    #expect(ToolInstaller.digest(for: "tool_1.0.0_darwin_amd64.tar.gz", in: listing) == "cccc")
    #expect(ToolInstaller.digest(for: "missing.tar.gz", in: listing) == nil)
  }

  @Test("A version is read out of whatever the binary prints")
  func readsVersionOutput() {
    #expect(ToolInstaller.version(in: "ngrok version 3.18.4") == "3.18.4")
    #expect(
      ToolInstaller.version(in: "cloudflared version 2024.8.2 (built 2024-08-01)") == "2024.8.2")
    #expect(ToolInstaller.version(in: "zrok v1.0.4\n") == "1.0.4")
    #expect(ToolInstaller.version(in: "no version here") == nil)
  }

  @Test("A version becomes a safe directory name")
  func sanitisesVersions() {
    #expect(ToolLayout.sanitize("1.2.3") == "1.2.3")
    // A tag is not a name we chose. A separator in it would silently create a nested
    // directory nothing would look in.
    #expect(!ToolLayout.sanitize("release/1.2.3").contains("/"))
    #expect(ToolLayout.sanitize("") == "unknown")
  }

  @Test("State survives a round trip")
  func stateRoundTrips() throws {
    let root = try ToolFixtures.temporaryDirectory()
    let directory = try ToolFixtures.temporaryDirectory()
    let executable = try ToolFixtures.fakeExecutable(named: "tool", version: "1", in: directory)

    let store = ToolStore(root: root)
    var state = ToolState(toolID: "tool")
    state.installed = InstalledBuild(
      version: "1.0.0",
      architecture: .host,
      executablePath: executable.path,
      sha256: "abc",
      sourceURL: "https://example.test/tool.tar.gz",
      teamID: "ABCDE12345"
    )
    state.pinnedTeamID = "ABCDE12345"
    state.latestUpdate = AvailableUpdate(version: "2.0.0", channel: .latest)
    try store.save(state)

    let loaded = store.load("tool")
    #expect(loaded.installed?.version == "1.0.0")
    #expect(loaded.pinnedTeamID == "ABCDE12345")
    #expect(loaded.latestUpdate?.version == "2.0.0")
  }
}
