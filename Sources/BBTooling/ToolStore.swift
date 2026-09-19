//  ToolStore
//  Where an installed program lives, and what is remembered about it.
//
//  The layout is the whole revert story:
//
//      Tools/<tool>/versions/<version>-<arch>/<exe>
//      Tools/<tool>/current -> versions/<version>-<arch>
//      Tools/<tool>/state.json
//
//  A symlink rather than a copy, because reverting is then a repoint of one link: instant,
//  atomic, and needing no network. That matters more here than anywhere else in the server:
//  the thing being reverted is the tunnel, so the moment it breaks the user is on the far side
//  of a connection that no longer exists and cannot get to this Mac to fix it. An update that
//  can only be undone by downloading something is not an update anyone should accept.
//
//  Versions are keyed by version AND architecture. A Time Machine restore onto a different
//  Mac carries this directory along, and an arm64 binary in a folder called `2024.8.2` on an
//  Intel Mac fails in a way nobody would connect to having changed computers.

import BBServiceKit
import Foundation

/// The on-disk layout for one tool.
public struct ToolLayout: Sendable {

  public let root: URL
  public let toolID: String

  public init(root: URL, toolID: String) {
    self.root = root
    self.toolID = toolID
  }

  public var directory: URL { root.appendingPathComponent(toolID, isDirectory: true) }
  public var versionsDirectory: URL {
    directory.appendingPathComponent("versions", isDirectory: true)
  }
  public var currentLink: URL { directory.appendingPathComponent("current") }
  public var stateFile: URL { directory.appendingPathComponent("state.json") }
  /// Scratch space for a download in progress. On the same volume as the destination, so
  /// the final move is a rename rather than a copy.
  public var downloadsDirectory: URL {
    directory.appendingPathComponent("downloads", isDirectory: true)
  }

  public func versionDirectory(version: String, architecture: ToolArchitecture) -> URL {
    versionsDirectory.appendingPathComponent(
      "\(Self.sanitize(version))-\(architecture.rawValue)", isDirectory: true
    )
  }

  /// A version string reduced to something safe as a path component.
  ///
  /// Vendors put all sorts of things in a tag, and a version is not a name we chose: a
  /// slash in it would silently create a nested directory that nothing would ever look in.
  public static func sanitize(_ version: String) -> String {
    let allowed = version.map { character -> Character in
      character.isLetter || character.isNumber || character == "." || character == "-"
        ? character : "_"
    }
    let text = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return text.isEmpty ? "unknown" : String(text.prefix(64))
  }

  /// The default location, alongside everything else this server keeps.
  public static func defaultRoot() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        "Library/Application Support/bluebubbles-server/Tools", isDirectory: true
      )
  }
}

// MARK: - Persisted state

/// One installed build.
public struct InstalledBuild: Sendable, Codable, Equatable {
  public var version: String
  public var architecture: ToolArchitecture
  /// Absolute, because that is what gets handed to `Process`.
  public var executablePath: String
  public var sha256: String?
  public var sourceURL: String
  /// Who signed it. Kept so an update signed by someone else can be recognised as such.
  public var teamID: String?
  /// Which channel this came from.
  ///
  /// Remembered because it decides what counts as an update afterwards. Someone who chose
  /// the newest published build should not be told about a "newer" recommended version that
  /// is older than what they are running, and someone on the recommended version should not
  /// be nagged towards a build nothing has tested.
  public var channel: ToolChannel
  public var installedAt: Date

  public init(
    version: String,
    architecture: ToolArchitecture,
    executablePath: String,
    sha256: String? = nil,
    sourceURL: String,
    teamID: String? = nil,
    channel: ToolChannel = .latest,
    installedAt: Date = Date()
  ) {
    self.version = version
    self.architecture = architecture
    self.executablePath = executablePath
    self.sha256 = sha256
    self.sourceURL = sourceURL
    self.teamID = teamID
    self.channel = channel
    self.installedAt = installedAt
  }
}

/// Something newer that exists and has NOT been installed.
///
/// Recorded rather than acted on. See `ToolManager`; nothing here ever updates a tool by
/// itself, and this type is the reason that is expressible: an available update is a fact the
/// UI can show, not a task queued up.
public struct AvailableUpdate: Sendable, Codable, Equatable {
  public var version: String
  /// Which channel this offer is on. See `ToolState` for why there can be two at once.
  public var channel: ToolChannel
  public var foundAt: Date
  public var releaseNotesURL: String?
  /// For a rolling source, where there is no version: the HTTP validator that changed.
  public var validator: String?

  public init(
    version: String,
    channel: ToolChannel = .latest,
    foundAt: Date = Date(),
    releaseNotesURL: String? = nil,
    validator: String? = nil
  ) {
    self.version = version
    self.channel = channel
    self.foundAt = foundAt
    self.releaseNotesURL = releaseNotesURL
    self.validator = validator
  }
}

/// Which bytes were probed.
///
/// A copy already on the Mac belongs to whatever put it there, and `brew upgrade` replaces it
/// without telling anyone. The moment it does, the version recorded beside it becomes a claim
/// about a program that is no longer at that path. One `stat` says whether the record still
/// describes the file, which is what keeps the steady state free of subprocesses.
public struct FileFingerprint: Sendable, Codable, Equatable {

  public var size: Int64
  public var modifiedAt: Date
  /// Caught the case size and mtime miss: a rebuild that lands the same bytes at the same
  /// second in a new file.
  public var inode: UInt64

  public init(size: Int64, modifiedAt: Date, inode: UInt64) {
    self.size = size
    self.modifiedAt = modifiedAt
    self.inode = inode
  }

  /// Reads the fingerprint of whatever is at a path now, or nil when nothing is.
  public static func read(_ path: String) -> FileFingerprint? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attributes[.size] as? NSNumber,
      let modified = attributes[.modificationDate] as? Date,
      let inode = attributes[.systemFileNumber] as? NSNumber
    else { return nil }
    return FileFingerprint(
      size: size.int64Value, modifiedAt: modified, inode: inode.uint64Value
    )
  }

  public func matches(pathAt path: String) -> Bool {
    Self.read(path) == self
  }
}

/// A copy of a program that this server did not install, and what it said when asked.
///
/// Deliberately records the FACT and not the verdict. Whether a version is acceptable is
/// decided by the range in the manifest, the manifest ships inside the application, and the
/// application updates: a stored "this one is fine" would be a stale answer to a question
/// whose rule had since moved. `ToolManager.resolve` has the descriptor in hand and judges
/// there.
public struct ProbedCopy: Sendable, Codable, Equatable {

  public var executablePath: String
  public var outcome: ProbeOutcome
  public var probedAt: Date
  public var fingerprint: FileFingerprint

  public init(
    executablePath: String, outcome: ProbeOutcome, probedAt: Date = Date(),
    fingerprint: FileFingerprint
  ) {
    self.executablePath = executablePath
    self.outcome = outcome
    self.probedAt = probedAt
    self.fingerprint = fingerprint
  }

  /// Whether this record still describes the file it was taken from.
  public var isCurrent: Bool { fingerprint.matches(pathAt: executablePath) }

  public var version: String? { outcome.version }
}

/// Which copy of a program to use when this Mac has more than one.
public enum ToolPreference: String, Sendable, Codable, Equatable, CaseIterable {
  /// Use whatever is already here when it is usable; download only when nothing is.
  case automatic
  /// Use the copy BlueBubbles installed, and ignore anything else on this Mac.
  case dedicated
}

/// Everything remembered about one tool between launches.
public struct ToolState: Sendable, Codable, Equatable {

  public var toolID: String
  public var installed: InstalledBuild?
  /// Kept so revert is a symlink repoint. Exactly one, deliberately: a chain of old versions
  /// is 38 MB each and nobody reverts twice.
  public var previous: InstalledBuild?
  /// A binary the user pointed us at instead of one we downloaded.
  ///
  /// The offline path, and the Homebrew path. A first-run user configuring a tunnel may have
  /// no working internet connection at all (that is frequently WHY they are configuring a
  /// tunnel) so "download it" cannot be the only way to have one.
  public var externalPath: String?
  /// Whoever signed the first install, pinned for every one after it. See `SignaturePolicy`.
  public var pinnedTeamID: String?
  public var lastCheckedAt: Date?
  /// A newer RECOMMENDED version: the plugin's own declaration moved, which happens when
  /// the thing that ships the plugin is updated.
  ///
  /// This is the offer that matters, and the only one that produces a notification: it means
  /// the people who maintain this integration have tested something newer.
  public var recommendedUpdate: AvailableUpdate?
  /// Something newer than the recommended version, published by the vendor.
  ///
  /// Kept separate because it is a weaker claim. Being on the recommended version is the good
  /// state; this is available for someone who wants it (a fix they are waiting for) and is
  /// deliberately not presented as something to act on.
  public var latestUpdate: AvailableUpdate?
  /// Something the last install needs to say for itself: a recommended version that was
  /// gone, for instance.
  public var note: String?
  /// The `ETag`/`Last-Modified` of the last rolling download, which is the only way to tell
  /// a vendor that publishes no versions has published something.
  public var lastValidator: String?

  /// A copy that was already on this Mac when a scan looked.
  ///
  /// Nobody chose it, which is why the version test is the whole of its licence to be used:
  /// see `ToolManager.resolve`.
  public var discovered: ProbedCopy?

  /// What the binary at `externalPath` said when it was adopted.
  ///
  /// Kept so a scan can tell whether the file underneath someone's explicit choice has been
  /// replaced: a `brew upgrade` moves it without anyone touching this server.
  public var externalProbe: ProbedCopy?

  /// Which copy to prefer. Nil IS `.automatic`, and nil is what every state file written
  /// before this field existed carries.
  ///
  /// **Optional on purpose, and it is not a style choice.** A non-optional with a default
  /// does not decode from JSON that lacks the key: Swift's synthesised `init(from:)` throws
  /// rather than falling back to the property's default. `load` below turns a decode failure
  /// into a blank state, so a non-optional here would silently discard every existing user's
  /// install record, re-download 38 MB and orphan the copy already on disk.
  public var preference: ToolPreference?

  /// When a scan last looked for a copy already on this Mac.
  ///
  /// Distinguishes "we looked and there is nothing" from "we have not looked yet", which the
  /// page needs: the second is a spinner, the first is an offer to download.
  public var lastScanAt: Date?

  public var effectivePreference: ToolPreference { preference ?? .automatic }

  public init(toolID: String) {
    self.toolID = toolID
  }
}

/// Reads and writes the state files.
///
/// Split out from `ToolManager` so the state can be inspected in a test without standing up a
/// manager, a transport and a network.
public struct ToolStore: Sendable {

  private let root: URL

  public init(root: URL = ToolLayout.defaultRoot()) {
    self.root = root
  }

  public func layout(for toolID: String) -> ToolLayout {
    ToolLayout(root: root, toolID: toolID)
  }

  public func load(_ toolID: String) -> ToolState {
    let layout = layout(for: toolID)
    guard let data = try? Data(contentsOf: layout.stateFile),
      var state = try? JSONDecoder.toolDecoder.decode(ToolState.self, from: data)
    else {
      return ToolState(toolID: toolID)
    }

    // The file says what was installed; the filesystem says what IS. They diverge when a
    // user clears Application Support by hand, and believing the file at that point means
    // handing a tunnel a path to nothing, which fails as "the tunnel program is missing"
    // several layers away from the cause.
    if let installed = state.installed, !isExecutable(installed.executablePath) {
      state.installed = nil
    }
    if let previous = state.previous, !isExecutable(previous.executablePath) {
      state.previous = nil
    }
    if let external = state.externalPath, !isExecutable(external) {
      state.externalPath = nil
      state.externalProbe = nil
    }
    // The same rule one level deeper. The file says what was probed; the filesystem says
    // what is there now, and the filesystem is right. A record whose bytes have been
    // replaced is a version number attached to a program nobody has run.
    if let probe = state.discovered, !probe.isCurrent {
      state.discovered = nil
    }
    if let probe = state.externalProbe, !probe.isCurrent {
      state.externalProbe = nil
    }
    return state
  }

  public func save(_ state: ToolState) throws {
    let layout = layout(for: state.toolID)
    try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
    let data = try JSONEncoder.toolEncoder.encode(state)
    // Written through a temporary file: a power loss mid-write would otherwise leave a
    // truncated state file, and a tool that cannot be read is a tool that looks
    // uninstalled while 38 MB of it sits on disk.
    let temporary = layout.directory.appendingPathComponent(".state.json.\(UUID().uuidString)")
    try data.write(to: temporary, options: .atomic)
    _ = try? FileManager.default.replaceItemAt(layout.stateFile, withItemAt: temporary)
    if FileManager.default.fileExists(atPath: temporary.path) {
      try? FileManager.default.removeItem(at: temporary)
    }
  }

  private func isExecutable(_ path: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
  }
}

extension JSONEncoder {
  static var toolEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var toolDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
