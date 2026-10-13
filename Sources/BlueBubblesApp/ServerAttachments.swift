//  ServerAttachments
//  What a start has attached to the server, each entry beside the call that undoes it.
//
//  `AppModel.start` attaches a child model at a time, at whichever moment that child can
//  first be given what it needs: storage before the migration gate, the settings store
//  before the start delay, the alert centre once the services are up. Teardown used to be a
//  second, hand-maintained list in `tearDown`, and the two had drifted: a start that stopped
//  at the migration wizard (or failed before a server existed) had attached onboarding, Home
//  and the archive to storage nothing would ever detach them from, because the teardown
//  list only ran once there was a server to stop.
//
//  So there is one list. `attach(_:_:)` runs the attach and records the child's `detach` in
//  the same call, so nothing can be attached through it without being detached, and
//  `detachAll` undoes every entry in reverse order on every way out: a stop, a failed start,
//  and the next start after one that stopped short. `FrontEndPlumbingPolicyTests` refuses an
//  attach or a detach in `AppModel.swift` that does not go through here.

import Foundation

/// A child model whose state is tied to a running server, or to its storage.
@MainActor
protocol ServerAttachable: AnyObject {
  /// Lets go of whatever `attach` was handed and clears what it held. Called once per
  /// attach, by `ServerAttachments.detachAll`.
  func detach() async
}

@MainActor
final class ServerAttachments {

  private var entries: [(name: String, undo: @MainActor () async -> Void)] = []

  /// What is attached now, in the order it was attached. For tests and for the policy that
  /// every child is attached through here.
  var names: [String] { entries.map(\.name) }

  /// Attaches `child` and records its detach in the same step.
  ///
  /// The detach is recorded only once `attach` has returned: a child whose attach threw has
  /// nothing to undo, and the throw goes to the caller, whose own failure path runs
  /// `detachAll` for everything before it.
  func attach<Child: ServerAttachable>(
    _ child: Child, _ attach: @MainActor (Child) async throws -> Void
  ) async rethrows {
    try await attach(child)
    entries.append((String(describing: Child.self), { await child.detach() }))
  }

  /// Records an undo for something that is not a child model: the composition itself, the
  /// follows. Named so a test can say what is attached.
  func onDetach(_ name: String, _ undo: @escaping @MainActor () async -> Void) {
    entries.append((name, undo))
  }

  /// Undoes every entry, the most recent first, and empties the list.
  ///
  /// Taken off the list before any undo runs, so an undo that suspends cannot see a
  /// half-emptied list, and a second `detachAll` arriving meanwhile finds nothing to repeat.
  func detachAll() async {
    let undoing = entries
    entries = []
    for entry in undoing.reversed() { await entry.undo() }
  }
}

// Every child model that `AppModel.start` attaches. A child with an `attach` and no
// conformance here cannot be passed to `ServerAttachments.attach`, which is the only way
// `AppModel` attaches one.
extension PermissionsModel: ServerAttachable {}
extension AlertsModel: ServerAttachable {}
extension UpdatesModel: ServerAttachable {}
extension SparkleUpdater: ServerAttachable {}
extension IntegrationsModel: ServerAttachable {}
extension OnboardingModel: ServerAttachable {}
extension HomeModel: ServerAttachable {}
extension ArchiveModel: ServerAttachable {}
extension SettingsModel: ServerAttachable {}
extension MigrationModel: ServerAttachable {}
extension LogsModel: ServerAttachable {}
extension MetricsModel: ServerAttachable {}
extension WebhooksModel: ServerAttachable {}
