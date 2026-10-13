//  LazyCollaborators
//  The subsystems a server builds on first use and then holds for its life.
//
//  Separate from `AppContext` because each of these is optional in practice: most servers
//  never open the call log, read a sticker, mint a FaceTime link or restart Messages, and
//  building any of them eagerly would add a SQLite handle, a Full Disk Access failure or a
//  coordinator with its own tasks to every start. An actor rather than a set of `private var`s
//  on the container, so "built once, on demand" is one type with one rule, and the container
//  is left holding references rather than deciding when to make them.
//
//  The two stores opened from disk go through `OnDemand`, which holds a success and only a
//  success: a store that could not be opened, or is not there yet, is looked for again on the
//  next use. Holding the failure is the bug it prevents. The likeliest failure is Full Disk
//  Access, which a person grants WHILE the server runs, so a server asked once before the
//  grant would answer "no call history" until it was restarted.

import BBFaceTime
import BBIMessage
import BBInterfaces
import BBPersistence
import BBPrivateAPI
import BBPrivateAPIContract
import BBSettings
import BBSystem
import Foundation
import Logging

/// One collaborator built on first use.
///
/// Three rules, each the answer to a way a `loaded` flag beside an optional goes wrong:
///
/// - **A success is held** for the life of the server, and every later use gets it.
/// - **Anything else is not.** A build that produced nothing (it failed, or there was nothing
///   to open) is forgotten when it returns, so the next use tries again.
/// - **Concurrent first uses share ONE build.** The build awaits, and an actor is re-entered
///   across an await: a flag set before it tells a second caller arriving mid-build that the
///   work is done, and hands it the nil that is still there.
actor OnDemand<Value: Sendable> {

  /// The build in progress, which every caller that arrives while it runs awaits. A task that
  /// produces a value callers join, not a loop anything owns.
  private var building: Task<Value?, Never>?
  private var built: Value?

  init() {}

  /// The value, building it if nothing holds one yet.
  ///
  /// - Parameter build: returns nil for "not available now", having logged why if that is
  ///   worth logging. Only the first caller's closure runs; one arriving mid-build joins it.
  func value(_ build: @escaping @Sendable () async -> Value?) async -> Value? {
    if let built { return built }
    if let building { return await building.value }
    let task = Task { await build() }
    building = task
    let result = await task.value
    building = nil
    built = result
    return result
  }
}

actor LazyCollaborators {

  private let logger: Logger
  /// Where the two stores are opened from: this Mac's, unless a test says otherwise.
  private let callHistoryPath: String
  private let stickerPath: String

  init(
    logger: Logger,
    callHistoryPath: String = CallHistoryRepository.defaultPath,
    stickerPath: String = StickerRepository.defaultPath()
  ) {
    self.logger = logger
    self.callHistoryPath = callHistoryPath
    self.stickerPath = stickerPath
  }

  // MARK: - Call history

  private let callHistoryStore = OnDemand<CallHistoryRepository>()

  /// The macOS call log, opened on first use and then held.
  ///
  /// Nil while this Mac has none (it has never placed a call) or it cannot be read, and in
  /// both cases asked again next time: the first call, or the Full Disk Access grant, is
  /// something that happens while the server runs, and asking again costs one `stat` of a
  /// file that is not there or one refused open.
  func callHistory() async -> CallHistoryRepository? {
    let path = callHistoryPath
    let logger = self.logger
    return await callHistoryStore.value {
      do {
        return try await CallHistoryRepository(path: path)
      } catch {
        // Almost always Full Disk Access. Logged rather than thrown so recents degrade
        // to "empty" instead of failing the request with a SQLite error.
        logger.warning(
          "Could not open the macOS call log",
          metadata: [
            "error": .string(String(describing: error))
          ])
        return nil
      }
    }
  }

  // MARK: - Stickers

  private let stickerStore = OnDemand<StickerRepository>()

  /// This Mac's sticker store, opened on first use and then held.
  ///
  /// A missing file is a real state rather than an error: `stickers.stickerdb` does not
  /// exist until the user has had a sticker, and is looked for again on the next use for
  /// the reason `callHistory()` gives.
  func stickerLibrary() async -> StickerRepository? {
    let path = stickerPath
    let logger = self.logger
    return await stickerStore.value {
      guard FileManager.default.fileExists(atPath: path) else {
        // Not warned about: a Mac with no stickers is ordinary, and a warning on every such
        // server would be noise that trains people to ignore warnings.
        logger.debug("This Mac has no sticker store", metadata: ["path": .string(path)])
        return nil
      }
      do {
        return StickerRepository(database: try ReadOnlyDatabase(path: path))
      } catch {
        // Almost always Full Disk Access, same as the call log.
        logger.warning(
          "Could not open this Mac's sticker store",
          metadata: [
            "path": .string(path),
            "error": .string(String(describing: error)),
          ])
        return nil
      }
    }
  }

  // MARK: - FaceTime

  /// Held because it must be ONE instance: the ledger it owns is the only record of which
  /// links this server minted, and a second coordinator would clean up against an empty
  /// one and leave every real link behind.
  private var faceTimeBacking: FaceTimeCoordinator?

  /// FaceTime link bookkeeping, hand-off tracking and cleanup.
  ///
  /// `privateAPI` is resolved per call inside the coordinator, not captured here: the helper
  /// connects and drops while the server runs, and a reference taken now would be stale
  /// after the next helper restart. The closure is taken on the first call only; later
  /// calls return the coordinator already built.
  func faceTime(
    privateAPI: @escaping @Sendable () async -> (any PrivateAPI)?
  ) -> FaceTimeCoordinator {
    if let faceTimeBacking { return faceTimeBacking }
    let coordinator = FaceTimeCoordinator(privateAPI: privateAPI, logger: logger)
    faceTimeBacking = coordinator
    return coordinator
  }

  // MARK: - Application restart

  private var applicationRestartBacking: ApplicationRestartCoordinator?

  /// Restarting Messages or FaceTime with the helper re-injected. Same shape as
  /// `faceTime(privateAPI:)`: the runtime is looked up per restart, because a restart is
  /// exactly the moment the runtime is replaced.
  func applicationRestart(
    privateAPIRuntime: @escaping @Sendable () async -> PrivateAPIRuntime?
  ) -> ApplicationRestartCoordinator {
    if let applicationRestartBacking { return applicationRestartBacking }
    let coordinator = ApplicationRestartCoordinator(
      privateAPIRuntime: privateAPIRuntime, logger: logger
    )
    applicationRestartBacking = coordinator
    return coordinator
  }
}
