//  ToolInstaller
//  Download, verify, unpack, prove it runs, and only then make it the current one.
//
//  The order is the design. Every step happens in a scratch directory, and the `current`
//  symlink moves last — so a download that fails verification, an archive that does not
//  contain what it should, or a binary built for the wrong architecture all leave the
//  previously working install exactly where it was. The failure mode this avoids is specific
//  and bad: the tunnel is the only route to this machine, and a half-applied update to it is
//  not something the user can come and fix.
//
//  Running the binary once before adopting it is the step that looks superfluous and is not.
//  It is the only check that covers "the vendor's arm64 asset actually contains an x86_64
//  binary", "the archive contained a wrapper script that needs something we do not have", and
//  every other way a download can be intact, correctly signed, and still not work here. For a
//  rolling source it is also the only way to learn the version at all.

import BBCore
import BBServiceKit
import Crypto
import Foundation
import Logging

/// What stage an install is at, for the UI.
public enum ToolInstallPhase: Sendable, Equatable {
  case resolving
  case downloading(fraction: Double)
  case verifying
  case unpacking
  case activating
}

public struct ToolInstaller: Sendable {

  private let transport: any ToolTransport
  private let store: ToolStore
  private let logger: Logger

  public init(transport: any ToolTransport, store: ToolStore, logger: Logger) {
    self.transport = transport
    self.store = store
    self.logger = logger
  }

  /// Installs `release` and returns what was installed, leaving `state` updated but unsaved
  /// — the caller owns persistence, so a failure mid-flight cannot leave a state file
  /// claiming something that is not there.
  public func install(
    _ descriptor: ManagedToolDescriptor,
    release: ResolvedRelease,
    pinnedTeamID: String?,
    progress: @escaping @Sendable (ToolInstallPhase) -> Void
  ) async throws -> InstalledBuild {

    let layout = store.layout(for: descriptor.id)
    let scratch = layout.downloadsDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    // Whatever happens, the scratch space goes. A failed install that leaves 38 MB behind
    // does it again on every retry.
    defer { try? FileManager.default.removeItem(at: scratch) }

    // 1. Download.
    let downloadName =
      release.downloadURL.lastPathComponent.isEmpty
      ? "\(descriptor.executableName).\(release.build.archive.fileExtension)"
      : release.downloadURL.lastPathComponent
    let archiveFile = scratch.appendingPathComponent(downloadName)

    progress(.downloading(fraction: 0))
    let response: ToolHTTPResponse
    do {
      response = try await transport.download(release.downloadURL, to: archiveFile) { fraction in
        progress(.downloading(fraction: fraction))
      }
    } catch {
      throw ToolError.downloadFailed(
        tool: descriptor.id,
        url: release.downloadURL.absoluteString,
        reason: String(describing: error)
      )
    }
    guard response.isSuccess else {
      throw ToolError.downloadFailed(
        tool: descriptor.id,
        url: release.downloadURL.absoluteString,
        reason: "the server answered \(response.statusCode)"
      )
    }

    // 2. Digest, always — it is what gets recorded even when nothing is published to
    //    compare it against, so a later "is this the same binary" has an answer.
    progress(.verifying)
    let digest = try sha256(of: archiveFile, toolID: descriptor.id)

    // The plugin's own pin first, where it has one. This is the strongest check available:
    // the digest travelled inside the signed application rather than down the same
    // connection as the file it describes, so unlike a vendor's checksums file it cannot
    // be replaced by whoever replaced the download.
    if let pinned = release.pinnedDigest {
      guard pinned.caseInsensitiveCompare(digest) == .orderedSame else {
        throw ToolError.checksumMismatch(
          tool: descriptor.id, expected: pinned, actual: digest
        )
      }
    }

    if let checksumsURL = release.checksumsURL {
      try await verifyChecksum(
        descriptor, digest: digest, assetName: downloadName, checksumsURL: checksumsURL
      )
    } else if descriptor.signature == .unsigned {
      // Belt and braces against a manifest that got past validation — an unsigned tool
      // with no checksums is bytes from the internet that nothing has checked.
      throw ToolError.checksumMissing(tool: descriptor.id, asset: downloadName)
    }

    // 3. Unpack.
    progress(.unpacking)
    let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
    let executable = try Unpacking.unpack(
      archiveFile,
      format: release.build.archive,
      into: unpacked,
      executableName: descriptor.executableName,
      pathInArchive: release.build.pathInArchive,
      toolID: descriptor.id
    )
    try Unpacking.makeRunnable(executable)

    // 4. Signature. AFTER unpacking, because the signature is on the executable and not on
    //    the tarball around it.
    progress(.verifying)
    let signature = try verifySignature(
      descriptor, executable: executable, pinnedTeamID: pinnedTeamID
    )

    // 5. Run it. For a rolling source this is where the version comes from.
    let probed = try await probeVersion(descriptor, executable: executable)
    let version =
      release.isVersionKnownInAdvance
      ? release.version
      : (probed ?? ResolvedRelease.unknownVersion)

    // 6. Adopt it.
    progress(.activating)
    let destination = layout.versionDirectory(
      version: version, architecture: release.build.architecture)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // A reinstall of the same version replaces it rather than failing — that is what
    // "install again" means when someone is trying to fix a broken copy.
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: unpacked, to: destination)

    // Located again inside the destination rather than derived from the staging path by
    // string surgery. `/var` is a symlink to `/private/var` on macOS, so a temporary
    // directory's URL and the path `FileManager` reports for things inside it disagree on
    // their prefix — subtracting one from the other produced `…/privatefaketool`, and the
    // install failed on a file that existed.
    guard
      let installedExecutable = Unpacking.locate(
        executableName: descriptor.executableName,
        pathInArchive: release.build.pathInArchive,
        in: destination
      )
    else {
      throw ToolError.executableNotFoundInArchive(
        tool: descriptor.id, expected: descriptor.executableName
      )
    }
    try Unpacking.makeRunnable(installedExecutable)

    try activate(destination, layout: layout, toolID: descriptor.id)

    logger.info(
      "Installed tool",
      metadata: [
        "tool": .string(descriptor.id),
        "version": .string(version),
        "channel": .string(release.channel.rawValue),
        "architecture": .string(release.build.architecture.rawValue),
      ])

    return InstalledBuild(
      version: version,
      architecture: release.build.architecture,
      executablePath: installedExecutable.path,
      sha256: digest,
      sourceURL: release.downloadURL.absoluteString,
      teamID: signature.teamID,
      // What was actually resolved, not what was asked for — a recommended version that
      // had been withdrawn resolves to the latest, and recording it as recommended would
      // mean the next check compared against a version nobody is running.
      channel: release.channel
    )
  }

  /// Points `current` at a version directory.
  ///
  /// Replaced through a temporary link and a rename, so there is no instant at which
  /// `current` does not exist. A service resolving its executable during that instant would
  /// otherwise conclude the tool is not installed and raise an alert about it.
  func activate(_ versionDirectory: URL, layout: ToolLayout, toolID: String) throws {
    let temporary = layout.directory.appendingPathComponent(".current.\(UUID().uuidString)")
    do {
      // Relative, so the whole Tools directory can be moved or restored from a backup
      // without every link pointing at a home directory that may not exist any more.
      try FileManager.default.createSymbolicLink(
        atPath: temporary.path,
        withDestinationPath: "versions/\(versionDirectory.lastPathComponent)"
      )
      // `rename(2)` over an existing symlink is atomic; `FileManager.moveItem` refuses a
      // destination that exists, and removing it first is exactly the gap being avoided.
      guard rename(temporary.path, layout.currentLink.path) == 0 else {
        throw ToolError.installFailed(
          tool: toolID, reason: String(cString: strerror(errno))
        )
      }
    } catch let error as ToolError {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw ToolError.installFailed(tool: toolID, reason: String(describing: error))
    }
  }

  // MARK: - Verification

  private func verifyChecksum(
    _ descriptor: ManagedToolDescriptor,
    digest: String,
    assetName: String,
    checksumsURL: URL
  ) async throws {
    let (data, response) = try await transport.fetch(checksumsURL)
    guard response.isSuccess else {
      throw ToolError.checksumMissing(tool: descriptor.id, asset: assetName)
    }
    guard let expected = Self.digest(for: assetName, in: String(decoding: data, as: UTF8.self))
    else {
      throw ToolError.checksumMissing(tool: descriptor.id, asset: assetName)
    }
    guard expected.caseInsensitiveCompare(digest) == .orderedSame else {
      throw ToolError.checksumMismatch(
        tool: descriptor.id, expected: expected, actual: digest
      )
    }
  }

  /// Pulls one file's digest out of a `sha256  filename` listing.
  ///
  /// The formats in the wild differ in whitespace and in the `*` binary marker GNU coreutils
  /// writes, and the filename is sometimes a path. Matching on the last path component
  /// handles all of them without a format-specific parser per vendor.
  static func digest(for assetName: String, in listing: String) -> String? {
    for line in listing.split(separator: "\n") {
      let parts = line.split(whereSeparator: \.isWhitespace)
      guard parts.count >= 2 else { continue }
      let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
      guard (name as NSString).lastPathComponent == assetName else { continue }
      return String(parts[0])
    }
    return nil
  }

  private func verifySignature(
    _ descriptor: ManagedToolDescriptor,
    executable: URL,
    pinnedTeamID: String?
  ) throws -> CodeSignatureInfo {
    let information = try CodeSignature.inspect(executable.path, toolID: descriptor.id)

    switch descriptor.signature {
    case .unsigned:
      // Nothing to check; the checksum above is what stands in for it.
      return information

    case .pinnedTeam(let expected):
      guard information.isSigned else { throw ToolError.notSigned(tool: descriptor.id) }
      try CodeSignature.satisfiesDeveloperID(
        executable.path, teamID: expected, toolID: descriptor.id
      )
      return information

    case .trustOnFirstUse:
      guard information.isSigned else { throw ToolError.notSigned(tool: descriptor.id) }
      // The team already trusted for this tool, or — on a first install — whoever this
      // one is signed by. Either way the requirement is evaluated by the system rather
      // than by comparing the string we just read.
      let team = pinnedTeamID ?? information.teamID
      if let pinnedTeamID, let found = information.teamID, pinnedTeamID != found {
        throw ToolError.signatureTeamChanged(
          tool: descriptor.id, pinned: pinnedTeamID, found: found
        )
      }
      try CodeSignature.satisfiesDeveloperID(
        executable.path, teamID: team, toolID: descriptor.id
      )
      return information
    }
  }

  // MARK: - Digest and version

  private func sha256(of file: URL, toolID: String) throws -> String {
    guard let handle = try? FileHandle(forReadingFrom: file) else {
      throw ToolError.installFailed(tool: toolID, reason: "the download could not be read")
    }
    defer { try? handle.close() }

    // Streamed in chunks: the whole point of downloading to a file was to not hold 38 MB
    // in memory, and `Data(contentsOf:)` here would undo that at the last step.
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Runs the binary and reads a version out of what it says.
  ///
  /// Nil rather than throwing when the output cannot be parsed: a tool that runs and prints
  /// something unexpected has still passed the check that matters — it EXECUTED — and
  /// refusing the install over an unparseable version string would be refusing a working
  /// binary. A tool that cannot run at all does throw.
  private func probeVersion(
    _ descriptor: ManagedToolDescriptor, executable: URL
  ) async throws -> String? {
    let result: Subprocess.Result
    do {
      result = try await Subprocess.run(
        executable.path, descriptor.versionProbe.arguments,
        output: .merged,
        timeout: .seconds(descriptor.versionProbe.timeoutSeconds)
      )
    } catch let failure as Subprocess.Failure {
      // Both cases are fatal to the install and both are worth naming. A LAUNCH failure is
      // where a wrong-architecture download surfaces — `posix_spawn` reports
      // "Bad CPU type in executable" before anything runs. A TIMEOUT is a binary that
      // decided to wait for input or phone home. `Subprocess.Failure.body` says which.
      throw ToolError.versionProbeFailed(tool: descriptor.id, reason: failure.body)
    }
    // The exit status is deliberately not checked — see the doc comment above: a tool that
    // ran and printed something unexpected has passed the check that matters.
    return Self.version(in: result.text)
  }

  /// The first version-looking token in a line of output.
  ///
  /// `ngrok version 3.18.4`, `cloudflared version 2024.8.2 (built …)`, `zrok v1.0.4` — all
  /// answered by finding the first dotted number rather than by a pattern per vendor, which
  /// would be one more thing to maintain per tool for no gain.
  static func version(in output: String) -> String? {
    var current = ""
    for character in output {
      if character.isNumber || character == "." {
        current.append(character)
      } else {
        if current.contains("."), current.first?.isNumber == true {
          return current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        current = ""
      }
    }
    if current.contains("."), current.first?.isNumber == true {
      return current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    return nil
  }
}
