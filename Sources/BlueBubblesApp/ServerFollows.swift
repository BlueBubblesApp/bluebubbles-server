//  ServerFollows
//  Every stream the app follows from the running server, in one table, in two shapes.
//
//  Live state is followed, never polled (see this module's `CLAUDE.md`), and `AppModel` holds
//  several follows. Each used to be its own `Task?` property on `AppModel`, its own
//  hand-written "subscribe, seed, loop" or "count the changes" body, and its own two lines in
//  `stopFollowingServer` (cancel the task, clear what it held). A follow added without its
//  lines there outlived the server it followed and kept showing what a stopped server had
//  last said. Here a follow is a case on `ServerFollow`, a follow is started through one of
//  the two helpers below, and starting one registers what stopping it clears, so
//  `stopFollowingServer` is one call that cannot miss one.
//
//  A child model that owns what it follows (`MetricsModel`, `WebhooksModel`, `LogsModel`, as
//  `AlertsModel` does) holds its follow on its own `OwnedTask` instead, and clears what it
//  held in the `detach` the attachment list runs. The counting loop is shared by both:
//  `FollowTable.countChanges(named:of:atMostEvery:bump:)`.

import Foundation
import Logging

/// One follow of the running server. The key its task and its reset are held under.
enum ServerFollow: Hashable, CaseIterable, Sendable {
  case serviceHealth
  case privateAPIRuntime
  case tools
  case pushDevices
  case auditEvents
  case accessControl
  case clientAddress
  case appearance
}

/// The tasks following the server, and what each one's state is reset to when the server
/// stops.
///
/// A reset is registered by the follow that sets the state, so the two cannot be written
/// apart. It runs only on `stopAll`, never on `cancel`: cancelling is how a follow is pointed
/// at something else (the Private API runtime's, when the service publishes another one),
/// which is not a stopped server.
@MainActor
final class FollowTable {

  private var tasks: [ServerFollow: Task<Void, Never>] = [:]
  private var resets: [ServerFollow: @MainActor () -> Void] = [:]

  /// Replaces whatever was following under `key`, cancelling it.
  func start(
    _ key: ServerFollow, reset: (@MainActor () -> Void)?, _ task: Task<Void, Never>
  ) {
    tasks[key]?.cancel()
    tasks[key] = task
    if let reset { resets[key] = reset }
  }

  /// Registers what `stopAll` resets for `key` without starting a task: for state a follow
  /// sets outside its task (the runtime a follow is pointed at).
  func onStop(_ key: ServerFollow, reset: @escaping @MainActor () -> Void) {
    resets[key] = reset
  }

  /// Stops one follow and keeps what it held.
  func cancel(_ key: ServerFollow) {
    tasks.removeValue(forKey: key)?.cancel()
  }

  /// What is being followed now, for tests.
  var following: Set<ServerFollow> { Set(tasks.keys) }

  /// Stops every follow and resets everything any of them held.
  func stopAll() {
    for task in tasks.values { task.cancel() }
    tasks = [:]
    let pending = resets
    resets = [:]
    for reset in pending.values { reset() }
  }

  /// The loop behind a counted follow, for whichever task holds it: `AppModel.countChanges`
  /// starts it under a key in this table, and a child model runs it on its own `OwnedTask`.
  ///
  /// Returns when its task is cancelled, when the observation ends without failing, or when
  /// `bump` answers false because whatever it counts for has gone.
  ///
  /// - Parameters:
  ///   - name: what the warning names when the observation fails.
  ///   - interval: the most often the counter may move. The stream keeps only the newest
  ///     element, so whatever changed during the pause arrives as one move after it.
  static func countChanges<Element: Sendable>(
    named name: String,
    of subscribe: @MainActor () -> AsyncThrowingStream<Element, any Error>,
    atMostEvery interval: Duration? = nil,
    bump: @MainActor () -> Bool
  ) async {
    var failures = 0
    while !Task.isCancelled {
      do {
        for try await _ in subscribe() {
          failures = 0
          guard bump() else { return }
          if let interval { try await Task.sleep(for: interval) }
        }
        // The observation ended without failing: the server stopped observing.
        return
      } catch is CancellationError {
        return  // `stopFollowingServer`, or the owning model's `detach`.
      } catch {
        // The observation failed, which means the database did. Nothing used to happen
        // here, on the reasoning that the page's next read would fail and say so; but
        // the page reads when THIS moves, so a dead follow froze the page on what it last
        // showed. So: one move now, for the page to read and show what it finds, then
        // follow again after a pause that lengthens while it keeps failing.
        logger.warning(
          "A followed table stopped reporting changes; following it again",
          metadata: ["follow": .string(name), "error": .string("\(error)")])
        guard bump() else { return }
        failures += 1
        do {
          try await Task.sleep(for: .seconds(min(60, 5 * failures)))
        } catch {
          return
        }
      }
    }
  }

  private static let logger = Logger(label: "bluebubbles.app.follows")
}

extension AppModel {

  /// Follows a stream whose elements ARE the state: subscribe, seed, then apply each one.
  ///
  /// Subscribed BEFORE the seed read, so a change landing between the two is not lost; the
  /// seed is what puts the state right on the first frame. The task holds the model weakly,
  /// so a follow never keeps a discarded model alive.
  ///
  /// - Parameter reset: what `stopFollowingServer` puts this follow's state back to, so a
  ///   stopped server shows nothing stale.
  func follow<Element: Sendable>(
    _ key: ServerFollow,
    subscribe: @escaping @MainActor () async -> AsyncStream<Element>,
    seed: @escaping @MainActor (AppModel) async -> Void,
    apply: @escaping @MainActor (AppModel, Element) async -> Void,
    reset: (@MainActor (AppModel) -> Void)?
  ) {
    var undo: (@MainActor () -> Void)?
    if let reset {
      undo = { [weak self] in
        guard let model = self else { return }
        reset(model)
      }
    }
    let task = Task { [weak self] in
      let changes = await subscribe()
      guard let model = self else { return }
      await seed(model)
      for await element in changes {
        guard let model = self else { return }
        await apply(model, element)
      }
    }
    follows.start(key, reset: undo, task)
  }

  /// Follows a table observation by counting it: something changed, and the page that shows
  /// the rows reads them itself.
  ///
  /// Only that something changed, never the rows. The page reads through its own
  /// `ScreenModel`, so a read that fails lands where the page can say so; handing the rows
  /// over here would make a failed read look like an empty list. Needs no seed: a GRDB
  /// observation's first element is the current state, so the counter moves once as soon as
  /// it attaches and the page reads from a standing start.
  ///
  /// - Parameter interval: the most often the counter may move. The stream keeps only the
  ///   newest element, so whatever changed during the pause arrives as one move after it.
  func countChanges<Element: Sendable>(
    _ key: ServerFollow,
    of subscribe: @escaping @MainActor () -> AsyncThrowingStream<Element, any Error>,
    atMostEvery interval: Duration? = nil,
    bump: @escaping @MainActor (AppModel) -> Void
  ) {
    let task = Task { [weak self] in
      await FollowTable.countChanges(named: "\(key)", of: subscribe, atMostEvery: interval) {
        guard let model = self else { return false }
        bump(model)
        return true
      }
    }
    follows.start(key, reset: nil, task)
  }

  /// Stops every follow and clears what it held, so a stopped server shows nothing stale.
  func stopFollowingServer() {
    follows.stopAll()
    home.clear()
  }
}
