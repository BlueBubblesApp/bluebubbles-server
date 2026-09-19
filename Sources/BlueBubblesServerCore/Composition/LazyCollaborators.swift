//  LazyCollaborators
//  The subsystems a server builds on first use and then holds for its life.
//
//  Separate from `AppContext` because each of these is optional in practice: most servers
//  never open the call log, read a sticker, mint a FaceTime link or restart Messages, and
//  building any of them eagerly would add a SQLite handle, a Full Disk Access failure or a
//  coordinator with its own tasks to every start. An actor rather than a set of `private var`s
//  on the container, so "built once, on demand" is one type with one rule, and the container
//  is left holding references rather than deciding when to make them.

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

actor LazyCollaborators {

  private let settings: SettingsStore
  private let logger: Logger

  init(settings: SettingsStore, logger: Logger) {
    self.settings = settings
    self.logger = logger
  }

  // MARK: - Call history

  /// `loaded` is separate from the value so a machine with NO call history (a real,
  /// non-error state) is not retried on every request.
  private var callHistoryRepository: CallHistoryRepository?
  private var callHistoryLoaded = false

  /// The macOS call log, opened on first use and then held.
  func callHistory() async -> CallHistoryRepository? {
    if callHistoryLoaded { return callHistoryRepository }
    callHistoryLoaded = true
    do {
      callHistoryRepository = try await CallHistoryRepository()
    } catch {
      // Almost always Full Disk Access. Logged rather than thrown so recents degrade
      // to "empty" instead of failing the request with a SQLite error.
      logger.warning(
        "Could not open the macOS call log",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
    return callHistoryRepository
  }

  // MARK: - Stickers

  /// A missing file is a real state rather than an error: `stickers.stickerdb` does not
  /// exist until the user has had a sticker. `loaded` is separate from the value so that
  /// Mac is not retried on every request.
  private var stickerRepository: StickerRepository?
  private var stickerRepositoryLoaded = false

  /// This Mac's sticker store, opened on first use and then held.
  func stickerLibrary() async -> StickerRepository? {
    if stickerRepositoryLoaded { return stickerRepository }
    stickerRepositoryLoaded = true
    let path = StickerRepository.defaultPath()
    guard FileManager.default.fileExists(atPath: path) else {
      // Not warned about: a Mac with no stickers is ordinary, and a warning on every such
      // server would be noise that trains people to ignore warnings.
      logger.debug("This Mac has no sticker store", metadata: ["path": .string(path)])
      return nil
    }
    do {
      stickerRepository = StickerRepository(database: try ReadOnlyDatabase(path: path))
    } catch {
      // Almost always Full Disk Access, same as the call log.
      logger.warning(
        "Could not open this Mac's sticker store",
        metadata: [
          "path": .string(path),
          "error": .string(String(describing: error)),
        ])
    }
    return stickerRepository
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
    let coordinator = FaceTimeCoordinator(
      settings: settings, privateAPI: privateAPI, logger: logger
    )
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
