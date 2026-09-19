//  ToolDiscovery
//  Finding a copy of a program that is already on this Mac, so a second one is never
//  downloaded beside it.
//
//  A user who has run `brew install cloudflared` had their copy ignored and a second 38 MB
//  build fetched into Application Support: two installs, two versions, and an update story
//  that only covers one of them. This is the part that looks first.
//
//  **What it will not do is adopt a binary on trust.** It executes the candidate to ask its
//  version, which is the same act the whole managed-tool design is careful about, so the
//  licence to do it rests on three things and the code below is mostly those three:
//
//    - a FIXED list of prefixes, never `$PATH`. The server's environment comes from launchd
//      or from whichever shell started it, and widening the set of files we will execute by
//      something an installer or a dotfile can set gives away the entire argument.
//    - the declared companions have to sit beside it, so a daemon and the CLI that drives it
//      can only ever come from one install.
//    - the version it reports has to fall inside the range its manifest declares. A tool that
//      declares no range is not scanned for at all.
//
//  Two traps, both of which silently switch the feature off rather than breaking loudly, and
//  both of which were measured rather than reasoned about:
//
//    - `/opt/homebrew/bin` is entirely SYMLINKS into `../Cellar/<formula>/<version>/bin/`.
//      The allowlist is therefore about the path we LOOK UP, not about where the link lands;
//      requiring the resolved target to be inside a prefix refuses every Homebrew install,
//      which is the exact case this file exists for.
//    - `/opt/homebrew/bin` is `drwxrwxr-x`, group `admin`. A "not group-writable" rule reads
//      as prudent and refuses Homebrew on every Apple Silicon Mac. The check is
//      world-writable only; group-writable-by-`admin` is the trust boundary Homebrew itself
//      runs on, and an admin user can already `sudo`.
//
//  See `.claude/docs/performance.md` for why nothing here constructs a `Process`.

import BBCore
import BBServiceKit
import Foundation
import Logging

public struct ToolDiscovery: Sendable {

  /// Where a package manager or a hand install legitimately puts a binary.
  ///
  /// `/usr/bin` and `/bin` are deliberately absent: from macOS 14 they are on the sealed
  /// system volume, so nothing third-party can ever be installed there and listing them would
  /// buy two `stat` calls and the suggestion that a system binary is adoptable.
  public static let searchPrefixes: [String] = [
    "/opt/homebrew/bin", "/opt/homebrew/sbin",
    "/usr/local/bin", "/usr/local/sbin",
    "/opt/local/bin", "/opt/local/sbin",
  ]

  private let prefixes: [String]
  private let logger: Logger

  /// `prefixes` is injectable because it is the only seam a test has: discovery touches no
  /// network, so nothing here is stubbed and a test points this at a temporary directory
  /// holding real executables.
  public init(
    prefixes: [String] = ToolDiscovery.searchPrefixes,
    logger: Logger = Logger(label: "bluebubbles.tools.discovery")
  ) {
    self.prefixes = prefixes
    self.logger = logger
  }

  // MARK: - Scanning

  /// Looks for a copy already on this Mac.
  ///
  /// Returns the first candidate whose reported version falls inside the declared range. When
  /// none does, it returns the first candidate it managed to probe at all, so the page can say
  /// "zrok 2.0.4 is installed at /opt/homebrew/bin and this server needs something below
  /// 2.0.0" rather than showing nothing and offering a download with no explanation.
  ///
  /// A candidate that fails never stops the search: an Intel binary in `/usr/local/bin` must
  /// not hide a working arm64 one in `/opt/homebrew/bin`.
  public func find(_ descriptor: ManagedToolDescriptor) async -> ProbedCopy? {
    guard let range = descriptor.compatible else { return nil }

    var firstProbed: ProbedCopy?
    for prefix in prefixes {
      let candidate = (prefix as NSString).appendingPathComponent(descriptor.executableName)
      guard isUsableCandidate(candidate, directory: prefix, descriptor: descriptor) else {
        continue
      }
      guard let fingerprint = FileFingerprint.read(candidate) else { continue }

      let outcome = await ToolVersionProbe.run(descriptor, executable: candidate)
      let probed = ProbedCopy(
        executablePath: candidate, outcome: outcome, fingerprint: fingerprint
      )
      if case .wouldNotRun(let reason) = outcome {
        // Usually the wrong architecture. Worth a line, never worth stopping for.
        logger.debug(
          "A program on this Mac would not run",
          metadata: [
            "tool": .string(descriptor.id), "path": .string(candidate),
            "reason": .string(reason),
          ])
        if firstProbed == nil { firstProbed = probed }
        continue
      }
      if let version = outcome.version, range.contains(version) {
        logger.info(
          "Found a usable copy of a program already on this Mac",
          metadata: [
            "tool": .string(descriptor.id), "path": .string(candidate),
            "version": .string(version),
          ])
        return probed
      }
      if firstProbed == nil { firstProbed = probed }
    }
    return firstProbed
  }

  // MARK: - One known path

  /// Probes a path somebody named, for the explicit choice and for re-checking a copy in use.
  ///
  /// Throws only for the structural refusals, which are the ones a person can act on by
  /// choosing a different file. Judging the VERSION is the caller's, because what an
  /// unreadable version means differs between a scan and a deliberate choice.
  public func inspect(
    _ path: String, as descriptor: ManagedToolDescriptor
  ) async throws -> ProbedCopy {
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw ToolError.externalBinaryUnusable(path: path, reason: "it is not an executable file")
    }
    let directory = (path as NSString).deletingLastPathComponent
    if isWorldWritable(path) || isWorldWritable(directory)
      || isWorldWritable(resolved(path))
    {
      throw ToolError.externalBinaryInWritableDirectory(path: path)
    }
    for companion in descriptor.companionExecutables {
      let beside = (directory as NSString).appendingPathComponent(companion)
      guard FileManager.default.isExecutableFile(atPath: beside) else {
        throw ToolError.externalBinaryMissingCompanion(
          tool: descriptor.id, path: path, companion: companion
        )
      }
    }
    guard let fingerprint = FileFingerprint.read(path) else {
      throw ToolError.externalBinaryUnusable(path: path, reason: "it could not be read")
    }
    let outcome = await ToolVersionProbe.run(descriptor, executable: path)
    if case .wouldNotRun(let reason) = outcome {
      throw ToolError.externalBinaryWouldNotRun(
        tool: descriptor.id, path: path, reason: reason
      )
    }
    return ProbedCopy(executablePath: path, outcome: outcome, fingerprint: fingerprint)
  }

  // MARK: - Checks

  private func isUsableCandidate(
    _ path: String, directory: String, descriptor: ManagedToolDescriptor
  ) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    // The lookup path, its directory, and wherever the link actually lands. Not a
    // requirement that the target be inside a prefix: on Homebrew it never is.
    guard !isWorldWritable(path), !isWorldWritable(directory), !isWorldWritable(resolved(path))
    else {
      logger.warning(
        "Ignoring a program in a directory any user can write to",
        metadata: ["tool": .string(descriptor.id), "path": .string(path)]
      )
      return false
    }
    for companion in descriptor.companionExecutables {
      let beside = (directory as NSString).appendingPathComponent(companion)
      guard FileManager.default.isExecutableFile(atPath: beside) else { return false }
    }
    return true
  }

  /// Where a symlink lands, or the path itself.
  private func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  private func isWorldWritable(_ path: String) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let permissions = attributes[.posixPermissions] as? NSNumber
    else { return false }
    // World-writable ONLY. See the header: the group bit is Homebrew's normal layout.
    return permissions.int16Value & 0o002 != 0
  }
}
