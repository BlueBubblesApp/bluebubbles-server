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
//  **Every member is judged BEFORE anything is extracted.** A ZIP can name
//  `../../../etc/thing`, an absolute path, or a symbolic link that a later member is written
//  through, and an archive that walks out of its destination is the classic way a restore
//  becomes an overwrite. `ditto` is better behaved than `unzip` here, but "the tool probably
//  handles it" is not a property worth resting on, and a check made afterwards by walking
//  the destination cannot see a file written OUTSIDE it: by the time anything could look,
//  the overwrite has happened. So `ZipMembers` reads the archive's own directory of names
//  first (the central directory, and each entry's local header, which is where a mismatched
//  name would hide) and refuses the whole archive on one bad member. Only the names are
//  read; decompression stays `ditto`'s.
//
//  What is extracted is then held to what was listed: a regular file or a directory, each
//  one a listed member or a folder one sits in. A tool that wrote something the listing did
//  not show is refused rather than trusted.

import BBCore
import Foundation

public enum ZipArchive {

  /// Long enough for a large contact table on a slow disk, short enough that a wedged
  /// `ditto` cannot hold a UI action open for ever. `Subprocess` requires one on purpose.
  static let timeout: Duration = .seconds(120)

  static let ditto = "/usr/bin/ditto"

  public enum Failure: BBError, CustomStringConvertible, Equatable {
    case archiveFailed(String)
    case extractFailed(String)
    /// A member tried to write outside the destination, or through a link. See the header.
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

  /// Extracts `archive` into a new directory.
  ///
  /// Judges every member first and refuses the archive before `ditto` runs if one is
  /// unsafe. The caller owns the directory and removes it on every path, this one's failures
  /// included: once extraction has started, the directory may hold somebody's settings.
  public static func extract(_ archive: URL, into directory: URL) async throws {
    let members = try ZipMembers.read(archive)

    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let result = try await Subprocess.run(
      ditto, ["-x", "-k", archive.path, directory.path], timeout: timeout)
    guard result.succeeded else {
      throw Failure.extractFailed(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    try verifyExtracted(in: directory, listed: members)
  }

  /// Everything extracted must be what was listed: a regular file or a directory, each a
  /// listed member or a folder one sits in. See the header.
  ///
  /// Compared on the RESOLVED root, because `/tmp` is a symlink to `/private/tmp` on this
  /// platform and the enumerator reports paths under whichever it was handed.
  private static func verifyExtracted(in directory: URL, listed: [String]) throws {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    var allowed = Set<String>()
    for member in listed {
      var path = member.hasSuffix("/") ? String(member.dropLast()) : member
      while !path.isEmpty {
        allowed.insert(path)
        guard let slash = path.lastIndex(of: "/") else { break }
        path = String(path[..<slash])
      }
    }

    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
    guard
      let walk = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [])
    else {
      throw Failure.extractFailed("the extracted files could not be listed")
    }
    for case let url as URL in walk {
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(root.path + "/") else {
        throw Failure.unsafeMember(url.lastPathComponent)
      }
      let relative = String(path.dropFirst(root.path.count + 1))
      let kind = try url.resourceValues(forKeys: Set(keys))
      let isPlain =
        kind.isSymbolicLink != true && (kind.isRegularFile == true || kind.isDirectory == true)
      guard isPlain, allowed.contains(relative) else {
        throw Failure.unsafeMember(relative)
      }
    }
  }
}

/// The member names a ZIP declares, read without extracting anything.
///
/// Only the directory of names is parsed: the end-of-central-directory record, each
/// central-directory entry, and the local header each entry points at. A ZIP64 archive is
/// refused rather than parsed: an export is a handful of small JSON files, nowhere near the
/// four-gigabyte or 65,535-entry limits that make one necessary.
enum ZipMembers {

  private static let endSignature: UInt32 = 0x0605_4b50
  private static let centralSignature: UInt32 = 0x0201_4b50
  private static let localSignature: UInt32 = 0x0403_4b50
  private static let endRecordLength = 22
  private static let centralHeaderLength = 46
  private static let localHeaderLength = 30
  /// `S_IFMT` and `S_IFLNK`, as a Unix-made entry carries them in its external attributes.
  private static let fileTypeMask: UInt32 = 0o170000
  private static let symbolicLink: UInt32 = 0o120000
  private static let unixHost: UInt8 = 3

  /// Every member's name, in central-directory order, or the refusal.
  static func read(_ archive: URL) throws -> [String] {
    let data: Data
    do {
      data = try Data(contentsOf: archive, options: .mappedIfSafe)
    } catch {
      throw ZipArchive.Failure.extractFailed(DiagnosticText.sentence(for: error))
    }
    return try names(in: [UInt8](data))
  }

  /// The parse, on bytes, so a test can hand it an archive no tool would write.
  static func names(in bytes: [UInt8]) throws -> [String] {
    let end = try endRecord(in: bytes)
    let count = Int(bytes.u16(at: end + 10))
    let directoryOffset = Int(bytes.u32(at: end + 16))
    guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else {
      throw notReadable("it is a ZIP64 archive, which no export is")
    }

    var names: [String] = []
    var cursor = directoryOffset
    for _ in 0..<count {
      guard bytes.has(centralHeaderLength, at: cursor),
        bytes.u32(at: cursor) == centralSignature
      else { throw notReadable("its list of contents is damaged") }
      let madeBy = UInt8(bytes.u16(at: cursor + 4) >> 8)
      let nameLength = Int(bytes.u16(at: cursor + 28))
      let extraLength = Int(bytes.u16(at: cursor + 30))
      let commentLength = Int(bytes.u16(at: cursor + 32))
      let attributes = bytes.u32(at: cursor + 38)
      let localOffset = Int(bytes.u32(at: cursor + 42))
      guard bytes.has(nameLength, at: cursor + centralHeaderLength) else {
        throw notReadable("its list of contents is damaged")
      }
      let raw = Array(
        bytes[(cursor + centralHeaderLength)..<(cursor + centralHeaderLength + nameLength)])
      let name = String(decoding: raw, as: UTF8.self)

      try judge(name, raw: raw)
      if madeBy == unixHost, (attributes >> 16) & fileTypeMask == symbolicLink {
        throw ZipArchive.Failure.unsafeMember(name)
      }
      // The name the local header gives is the one some readers write to. A member whose
      // two names disagree is listed as one thing and extracted as another.
      guard bytes.has(localHeaderLength, at: localOffset),
        bytes.u32(at: localOffset) == localSignature
      else { throw notReadable("an entry points at nothing") }
      let localLength = Int(bytes.u16(at: localOffset + 26))
      guard localLength == nameLength,
        bytes.has(localLength, at: localOffset + localHeaderLength),
        Array(
          bytes[(localOffset + localHeaderLength)..<(localOffset + localHeaderLength + localLength)]
        )
          == raw
      else { throw ZipArchive.Failure.unsafeMember(name) }

      names.append(name)
      cursor += centralHeaderLength + nameLength + extraLength + commentLength
    }
    return names
  }

  /// A name that could put a file anywhere but under the destination is refused.
  ///
  /// A backslash is refused outright rather than read as a separator or as a character:
  /// readers disagree about which it is, and no export contains one.
  private static func judge(_ name: String, raw: [UInt8]) throws {
    let components = name.split(separator: "/", omittingEmptySubsequences: false)
    guard !raw.isEmpty, !raw.contains(0), !name.hasPrefix("/"), !name.contains("\\"),
      !components.contains("..")
    else { throw ZipArchive.Failure.unsafeMember(name) }
  }

  /// The end-of-central-directory record: the last occurrence of its signature, searched
  /// backwards over the longest comment the format allows.
  private static func endRecord(in bytes: [UInt8]) throws -> Int {
    guard bytes.count >= endRecordLength else { throw notReadable("it is too short") }
    let earliest = max(0, bytes.count - endRecordLength - Int(UInt16.max))
    var candidate = bytes.count - endRecordLength
    while candidate >= earliest {
      if bytes.u32(at: candidate) == endSignature { return candidate }
      candidate -= 1
    }
    throw notReadable("it is not a ZIP archive")
  }

  private static func notReadable(_ why: String) -> ZipArchive.Failure {
    .extractFailed("\(why).")
  }
}

extension [UInt8] {
  /// Whether `length` bytes start at `offset`.
  fileprivate func has(_ length: Int, at offset: Int) -> Bool {
    offset >= 0 && length >= 0 && offset <= count - length
  }

  /// Little-endian, as every ZIP field is. The caller has checked the bounds.
  fileprivate func u16(at offset: Int) -> UInt16 {
    UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func u32(at offset: Int) -> UInt32 {
    UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16
      | UInt32(self[offset + 3]) << 24
  }
}
