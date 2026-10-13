//  ZipArchive
//  Making and reading the ZIP, through `ditto`.
//
//  **`ditto` rather than a dependency**, and rather than hand-writing the format. Writing a
//  stored-entry ZIP is about two hundred lines and genuinely easy; writing a READER is
//  where that stops being true, because a reader has to cope with whatever a person hands
//  it — and an import takes a file from outside this server by definition. `ditto` ships on
//  every Mac, produces and consumes ordinary ZIPs, and is reached through
//  `BBCore.Subprocess`, which is the only way this codebase constructs a process.
//
//  **Extraction is checked afterwards, not trusted.** A ZIP can name `../../../etc/thing`
//  or an absolute path, and an archive that walks out of its destination is the classic way
//  a restore becomes an overwrite. `ditto` is better behaved than `unzip` here, but "the
//  tool probably handles it" is not a property worth resting on when the check is a string
//  comparison: after extracting into a fresh temporary directory, every file found is
//  required to sit inside it.

import BBCore
import Foundation

public enum ZipArchive {

  /// Long enough for a large contact table on a slow disk, short enough that a wedged
  /// `ditto` cannot hold a UI action open for ever. `Subprocess` requires one on purpose.
  static let timeout: Duration = .seconds(120)

  static let ditto = "/usr/bin/ditto"

  public enum Failure: BBError, CustomStringConvertible {
    case archiveFailed(String)
    case extractFailed(String)
    /// A member tried to write outside the destination. See the header.
    case unsafeMember(String)

    public var code: String {
      switch self {
      case .archiveFailed: "export.archive_failed"
      case .extractFailed: "export.extract_failed"
      case .unsafeMember: "export.unsafe_member"
      }
    }
    public var domain: String { "Export" }
    public var title: String { "The archive could not be used" }
    /// The CLI prints this, so it is the same sentence the app shows.
    public var description: String { body }

    public var body: String {
      switch self {
      case .archiveFailed(let detail): "The archive could not be created: \(detail)"
      case .extractFailed(let detail): "The archive could not be opened: \(detail)"
      case .unsafeMember(let name):
        "This archive contains an entry that would be written outside the folder it was "
          + "extracted into (\(name)). It has been refused."
      }
    }
  }

  /// Zips the CONTENTS of `directory` into `destination`.
  ///
  /// `--sequesterRsrc` keeps resource forks in `__MACOSX` rather than inline, and
  /// `--keepParent` is deliberately NOT passed: an export whose members are
  /// `export.json` and `settings.json` is one a person can open and read, and one whose
  /// members all sit under a directory named after a temporary folder is not.
  public static func create(contentsOf directory: URL, into destination: URL) async throws {
    let result = try await Subprocess.run(
      ditto,
      ["-c", "-k", "--sequesterRsrc", directory.path, destination.path],
      timeout: timeout
    )
    guard result.succeeded else {
      throw Failure.archiveFailed(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// Extracts `archive` into a new directory and returns it.
  ///
  /// The caller owns the directory and is responsible for removing it; every caller here
  /// does so in a `defer`, because an abandoned extraction is somebody's settings sitting
  /// in `/tmp`.
  public static func extract(_ archive: URL, into directory: URL) async throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let result = try await Subprocess.run(
      ditto, ["-x", "-k", archive.path, directory.path], timeout: timeout)
    guard result.succeeded else {
      throw Failure.extractFailed(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    try verifyContained(in: directory)
  }

  /// Every extracted path must resolve to somewhere inside `directory`.
  ///
  /// Compared on the RESOLVED paths, because `/tmp` is a symlink to `/private/tmp` on this
  /// platform and a prefix check against the unresolved one fails for every extraction on a
  /// Mac. That is the sort of detail that turns a security check into a check somebody
  /// deletes because it never passes.
  private static func verifyContained(in directory: URL) throws {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    let manager = FileManager.default
    guard let walk = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return
    }
    for case let url as URL in walk {
      let resolved = url.resolvingSymlinksInPath().standardizedFileURL
      guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
        throw Failure.unsafeMember(url.lastPathComponent)
      }
    }
  }
}
