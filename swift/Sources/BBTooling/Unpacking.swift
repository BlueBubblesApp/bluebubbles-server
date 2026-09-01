//  Unpacking
//  Getting an executable out of what the vendor published, and making it runnable.
//
//  Two of the three formats in use are archives — ngrok ships a zip, cloudflared and zrok ship
//  gzipped tarballs — and one is the bare executable. `/usr/bin/unzip` and `/usr/bin/tar` are
//  on every Mac, handle both, and are the same tools the user would use by hand; a Swift
//  archive library here would be a dependency to avoid duplicating what the system already
//  does correctly.
//
//  The part that is easy to skip and not optional is `com.apple.quarantine`. Anything that
//  arrives from the network can carry it, it is inherited by files extracted from a quarantined
//  archive, and a quarantined executable launched by a background server does not prompt — it
//  simply fails, with a message about the developer not being verified that no one is present
//  to read. Stripping it is a deliberate act and it is recorded here as one.

import BBCore
import BBServiceKit
import Darwin
import Foundation

public enum Unpacking {

  /// Unpacks `archive` into `directory` and returns the executable inside it.
  public static func unpack(
    _ archive: URL,
    format: ArchiveFormat,
    into directory: URL,
    executableName: String,
    pathInArchive: String?,
    toolID: String
  ) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    switch format {
    case .executable:
      // Not an archive: the download IS the program, under whatever name the vendor
      // gave it (`cloudflared-darwin-arm64`). Renamed on the way in, so what ends up
      // installed is called what the service asks for.
      let destination = directory.appendingPathComponent(executableName)
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: archive, to: destination)
      return destination

    case .zip:
      try run(
        "/usr/bin/unzip",
        // `-o` overwrite, `-q` quiet, `-j`-free: some archives have a directory and
        // flattening them would collide.
        ["-o", "-q", archive.path, "-d", directory.path],
        toolID: toolID
      )

    case .tarGzip:
      // No `-P`: without it both bsdtar and GNU tar strip leading slashes and refuse
      // `..` components, which is what keeps a hostile archive from writing outside
      // this directory.
      try run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path], toolID: toolID)
    }

    guard
      let executable = locate(
        executableName: executableName, pathInArchive: pathInArchive, in: directory
      )
    else {
      throw ToolError.executableNotFoundInArchive(
        tool: toolID, expected: pathInArchive ?? executableName
      )
    }
    return executable
  }

  /// Finds the executable inside an unpacked archive.
  ///
  /// Searched rather than assumed, because vendors disagree about depth: zrok's tarball puts
  /// the binary at the root, others nest it under a versioned directory. A declared
  /// `pathInArchive` wins when the manifest supplies one.
  static func locate(
    executableName: String,
    pathInArchive: String?,
    in directory: URL
  ) -> URL? {
    if let pathInArchive {
      let candidate = directory.appendingPathComponent(pathInArchive)
      return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    // Shallowest match wins, so `zrok` at the root beats a `zrok` in some `docs/`
    // subdirectory of a tarball that happens to contain both.
    var best: (depth: Int, url: URL)?
    while let entry = enumerator?.nextObject() as? URL {
      guard entry.lastPathComponent == executableName else { continue }
      let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      let depth = entry.pathComponents.count
      if best == nil || depth < best!.depth { best = (depth, entry) }
    }
    return best?.url
  }

  /// Makes a freshly unpacked file executable and removes its quarantine.
  ///
  /// Both, and in this order, because either alone leaves a program that will not run: a
  /// tarball can preserve a mode we cannot rely on, and a quarantined binary is refused
  /// before its mode is ever consulted.
  public static func makeRunnable(_ executable: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path
    )
    removeQuarantine(executable)
  }

  /// Strips `com.apple.quarantine`, recursively.
  ///
  /// `removexattr` rather than shelling out to `xattr`: it is one syscall, it cannot be
  /// confused by a path with a space in it, and `ENOATTR` — the overwhelmingly common case,
  /// since a `URLSession` download does not set the attribute at all — is not an error worth
  /// reporting.
  public static func removeQuarantine(_ url: URL) {
    var paths: [String] = [url.path]
    if let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: nil
    ) {
      while let entry = enumerator.nextObject() as? URL { paths.append(entry.path) }
    }
    for path in paths {
      _ = path.withCString { removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }
  }

  // MARK: - Running the unpackers

  /// - Parameter timeout: five minutes. There used to be NONE, so an unpacker that decided
  ///   to prompt hung the install with no way out — `unzip` does exactly that when an
  ///   archive contains a name that already exists. Generous, because a large archive on a
  ///   slow disk is legitimate; the point is only that it ends.
  ///
  /// Synchronous because `unpack` is. The draining and the detached stdin that used to be
  /// spelled out here are `Subprocess`'s job now.
  private static func run(
    _ executable: String, _ arguments: [String], toolID: String,
    timeout: Duration = .seconds(300)
  ) throws {
    let result: Subprocess.Result
    do {
      result = try Subprocess.runSynchronously(
        executable, arguments, output: .merged, timeout: timeout
      )
    } catch {
      throw ToolError.unpackFailed(tool: toolID, reason: String(describing: error))
    }

    guard result.succeeded else {
      let text = result.trimmedText
      throw ToolError.unpackFailed(
        tool: toolID,
        reason: text.isEmpty
          ? "\(executable) exited with \(result.status)"
          : String(text.suffix(400))
      )
    }
  }
}
