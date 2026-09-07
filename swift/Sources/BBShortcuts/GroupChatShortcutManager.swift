//  GroupChatShortcutManager
//  Install, detect, run, remove — the whole life of the one shortcut this server uses.
//
//  THE SHAPE OF THIS TYPE IS DICTATED BY WHAT THE CLI CANNOT DO
//  -----------------------------------------------------------
//  `shortcuts` has `list`, `run` and `sign`. It has no `add` and no `delete`. So:
//
//    - **Installing is a user gesture we can only START.** We generate the workflow, sign
//      it, and hand the file to `open`; the Shortcuts app then shows a sheet that a person
//      has to confirm. There is no callback. `install()` returns as soon as the sheet is
//      showing, and the caller learns the outcome by asking `isInstalled()` again later.
//    - **Removing is a user gesture we cannot start at all.** The only programmatic route
//      would be writing to `~/Library/Shortcuts/Shortcuts.sqlite`, which is a private
//      Core Data store owned by a running application. Corrupting a user's entire shortcut
//      library to save them one click is not a trade worth making. `uninstall()` opens the
//      Shortcuts app and the UI explains the one step.
//
//  DETECTION IS CHECKED BEFORE EVERY USE, NOT CACHED FOR LONG
//  ---------------------------------------------------------
//  The user can delete the shortcut in the Shortcuts app at any moment, and nothing tells
//  us. A server that cached "installed" at launch would keep offering group creation and
//  keep failing with the CLI's single, meaningless error string. So availability is
//  re-read on a short TTL, and `createGroup` re-checks before it runs.
//
//  See `GroupChatShortcut` for why the payload is JSON, and `.claude/docs/imessage.md`.

import BBCore
import Foundation
import Logging

/// What the app shows and what routing decides on.
public struct GroupChatShortcutStatus: Sendable, Equatable {
  /// Present in the user's Shortcuts library right now.
  public let isInstalled: Bool
  /// When this was last determined.
  public let checkedAt: Date

  public init(isInstalled: Bool, checkedAt: Date = Date()) {
    self.isInstalled = isInstalled
    self.checkedAt = checkedAt
  }

  public static let unknown = GroupChatShortcutStatus(
    isInstalled: false, checkedAt: .distantPast
  )
}

public actor GroupChatShortcutManager {

  private let command: any ShortcutsCommanding
  private let logger: Logger
  /// Opens a file with the user's default handler. Injected so a test never launches an app.
  private let opener: @Sendable (String) async throws -> Void

  /// How long a status reading is trusted.
  ///
  /// Short, because the thing it describes can be deleted by a person at any time with no
  /// notification. Long enough that rendering a settings page does not spawn a subprocess
  /// per redraw.
  private static let freshness: TimeInterval = 10

  private var cached: GroupChatShortcutStatus = .unknown

  public init(
    command: any ShortcutsCommanding = ShortcutsCommand(),
    logger: Logger = Logger(label: "bluebubbles.shortcuts"),
    opener: (@Sendable (String) async throws -> Void)? = nil
  ) {
    self.command = command
    self.logger = logger
    self.opener =
      opener ?? { path in
        _ = try await Subprocess.run(
          "/usr/bin/open", [path], output: .discarded, timeout: .seconds(30)
        )
      }
  }

  // MARK: - Detection

  /// Whether the shortcut is installed, re-reading if the last answer is stale.
  @discardableResult
  public func status(forceRefresh: Bool = false) async -> GroupChatShortcutStatus {
    if !forceRefresh, Date().timeIntervalSince(cached.checkedAt) < Self.freshness {
      return cached
    }
    let installed: Bool
    do {
      installed = try await command.list().contains(GroupChatShortcut.name)
    } catch {
      // A CLI that will not run is reported as "not installed" rather than thrown. The
      // caller's question is always "can I use this right now", and the answer is no
      // either way; a throw here would turn a settings page into an error screen.
      logger.debug(
        "Could not list shortcuts",
        metadata: ["error": .string(String(describing: error))])
      installed = false
    }
    cached = GroupChatShortcutStatus(isInstalled: installed)
    return cached
  }

  public func isInstalled() async -> Bool {
    await status().isInstalled
  }

  // MARK: - Installation

  /// Generates, signs and presents the shortcut for the user to add.
  ///
  /// Returns once the import sheet has been handed to the Shortcuts app. It does NOT mean
  /// the shortcut was installed — only the user can decide that, and the only way to find
  /// out is `status(forceRefresh: true)` afterwards.
  ///
  /// **Refuses when a copy is already installed, and that is not caution — it is required.**
  /// Importing a shortcut whose name is already taken creates a SECOND entry rather than
  /// replacing the first, and the CLI addresses shortcuts only by name. Two entries called
  /// `BlueBubbles - Create Group Chat` make every `shortcuts run` fail with "Couldn't find
  /// shortcut", so an innocent-looking reinstall would break the feature and leave the user
  /// with two identical rows and no way to tell which to delete. Removal has to come first,
  /// and only a person can do it.
  public func install(replacingExisting: Bool = false) async throws {
    if !replacingExisting, await status(forceRefresh: true).isInstalled {
      throw ShortcutsError.alreadyInstalled
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BlueBubblesShortcut-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let unsigned = directory.appendingPathComponent("unsigned.shortcut")
    // The SIGNED file carries the name the library will show, because the import takes it
    // from the filename. Naming the unsigned one would put a stray copy under the real
    // name into the temporary directory.
    let signed = directory.appendingPathComponent("\(GroupChatShortcut.name).shortcut")

    try GroupChatShortcut.workflowData().write(to: unsigned)
    try await command.sign(input: unsigned.path, output: signed.path)
    try await opener(signed.path)

    // Deliberately invalidated rather than set: what we know is that a sheet is open, and
    // recording "installed" here would make the UI claim success before the user acted.
    cached = .unknown
  }

  /// Opens the Shortcuts app so the user can delete it. See the file header.
  public func revealForRemoval() async throws {
    try await opener("/System/Applications/Shortcuts.app")
    cached = .unknown
  }

  // MARK: - Running

  /// Sends `message` to `recipients`, creating the conversation if it does not exist.
  ///
  /// Two or more recipients land in one group chat — Messages resolves the participant set
  /// to an existing conversation when there is one and creates a group when there is not.
  /// A single recipient is an ordinary direct message, which is why the AppleScript path
  /// handles that case instead: it needs no install and no approval.
  ///
  /// - Returns: Nothing. **The send action produces no output**, so the caller cannot learn
  ///   the new chat's GUID from here and has to find it in `chat.db`.
  public func send(recipients: [String], message: String) async throws {
    guard !recipients.isEmpty else {
      throw ShortcutsError.definitionInvalid(reason: "no recipients")
    }
    // Re-checked immediately before use: the user may have deleted it since the last read,
    // and the failure that produces is indistinguishable from every other failure.
    guard await status(forceRefresh: true).isInstalled else {
      throw ShortcutsError.runFailed(output: "not installed")
    }

    let payload = GroupChatShortcut.Payload(recipients: recipients, message: message)
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-shortcut-\(UUID().uuidString).json")
    try payload.encoded().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = try await command.run(name: GroupChatShortcut.name, inputPath: file.path)
    guard result.succeeded else {
      logger.error(
        "The group chat Shortcut failed",
        metadata: [
          "recipients": .string("\(recipients.count)"),
          "output": .string(result.output),
        ])
      throw ShortcutsError.runFailed(output: result.output)
    }
  }
}
