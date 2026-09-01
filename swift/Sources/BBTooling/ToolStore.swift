//  ToolStore
//  Where an installed program lives, and what is remembered about it.
//
//  The layout is the whole revert story:
//
//      Tools/<tool>/versions/<version>-<arch>/<exe>
//      Tools/<tool>/current -> versions/<version>-<arch>
//      Tools/<tool>/state.json
//
//  A symlink rather than a copy, because reverting is then a repoint of one link — instant,
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
  /// Vendors put all sorts of things in a tag, and a version is not a name we chose — a
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
/// Recorded rather than acted on. See `ToolManager` — nothing here ever updates a tool by
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
  /// no working internet connection at all — that is frequently WHY they are configuring a
  /// tunnel — so "download it" cannot be the only way to have one.
  public var externalPath: String?
  /// Whoever signed the first install, pinned for every one after it. See `SignaturePolicy`.
  public var pinnedTeamID: String?
  public var lastCheckedAt: Date?
  /// A newer RECOMMENDED version — the plugin's own declaration moved, which happens when
  /// the thing that ships the plugin is updated.
  ///
  /// This is the offer that matters, and the only one that produces a notification: it means
  /// the people who maintain this integration have tested something newer.
  public var recommendedUpdate: AvailableUpdate?
  /// Something newer than the recommended version, published by the vendor.
  ///
  /// Kept separate because it is a weaker claim. Being on the recommended version is the good
  /// state; this is available for someone who wants it — a fix they are waiting for — and is
  /// deliberately not presented as something to act on.
  public var latestUpdate: AvailableUpdate?
  /// Something the last install needs to say for itself — a recommended version that was
  /// gone, for instance.
  public var note: String?
  /// The `ETag`/`Last-Modified` of the last rolling download, which is the only way to tell
  /// a vendor that publishes no versions has published something.
  public var lastValidator: String?

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
    // handing a tunnel a path to nothing — which fails as "the tunnel program is missing"
    // several layers away from the cause.
    if let installed = state.installed, !isExecutable(installed.executablePath) {
      state.installed = nil
    }
    if let previous = state.previous, !isExecutable(previous.executablePath) {
      state.previous = nil
    }
    if let external = state.externalPath, !isExecutable(external) {
      state.externalPath = nil
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
