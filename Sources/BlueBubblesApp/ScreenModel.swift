//  ScreenModel
//  What a screen that reads from the server holds, in one place.
//
//  Every administration page needs the same things: state per collection, a `reload()`, a
//  `mutate` wrapper, and an error. Written per screen, the copies drift in the way copies
//  do: an error that is declared and rendered but never assigned, a `(try? await …) ?? []`
//  that makes "the server refused" and "there are none" the same value, three collections
//  re-read as separate statements so a failure halfway leaves one fresh beside two stale.
//
//  So this is the load half of a screen, once. A screen supplies WHAT to read as a single
//  `Value`, a snapshot struct when it needs more than one collection, which is also what
//  makes the read atomic, and gets back a state it can switch on. Errors are captured
//  rather than swallowed.
//
//  It is deliberately NOT a base class to subclass. Screens compose one as `@State`, and
//  their own actions stay declared at the call site where they read:
//  `perform { try await service.revoke(…) }` so nothing has to be overridden and a screen
//  that needs something unusual is not fighting an inherited shape.
//
//  WHICH SCREENS. Every page whose content IS a server read: the administration lists, and
//  `ScheduleComposer`'s conversation picker. Not every page that touches the server:
//  `HomeView` shows `-` for a count it does not have, which is honest for a glance
//  dashboard and does not want an error banner; `LogsView` follows a local file sink in a
//  loop and has no load to fail; `ServiceFormView` and the onboarding steps hold form and
//  validation state, which is not a read at all. A screen that is not a read does not want
//  this, and adopting it there would be consistency for its own sake.
//
//  WHERE IT LIVES decides whether the value survives navigation. Composed as `@State`, it is
//  torn down with the view when the detail column shows another page, and the next visit
//  reads from nothing: right for a list that is cheap to read and may have changed. Held on
//  the model (`HomeModel`), it keeps its value across visits, and `reload(for:unlessFresherThan:)`
//  lets the visit skip the read when the same key was read recently enough. That is the
//  shape for a read expensive enough to be worth not repeating; see `ReadFreshness`.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import SwiftUI

/// Where a screen's data has got to.
///
/// `idle` and `loading` are separate states because they mean different things to a
/// person: nothing has been asked for yet, versus something was asked for and has not come
/// back. Collapsing them into one `isLoading` flag is what makes a page flash its empty
/// state before its first result arrives.
enum ScreenState<Value: Sendable>: Sendable {
  case idle
  case loading
  case loaded(Value)
  case failed(String)

  /// The value, if there is one.
  ///
  /// A reload that fails keeps the previous value visible (see `ScreenModel.reload`)
  /// so this stays non-nil across a failed refresh and the page does not blank out
  /// underneath the person reading it.
  var value: Value? {
    if case .loaded(let value) = self { return value }
    return nil
  }

  var errorMessage: String? {
    if case .failed(let message) = self { return message }
    return nil
  }

  var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }
}

/// A screen's data, and the two operations every administration page performs on it.
///
/// `@MainActor` because it is read from `body`. The work it awaits is not on the main
/// actor: the interfaces layer is `Sendable` and does its own isolation, so `await`
/// here suspends rather than blocking, and the page stays live while a slow read is in
/// flight.
@MainActor
@Observable
final class ScreenModel<Value: Sendable> {

  private(set) var state: ScreenState<Value> = .idle

  /// True while an action from `perform` is running.
  ///
  /// Separate from `state.isLoading`, which describes the READ. A page needs both: a
  /// button that fired should disable itself without the list it sits above dropping to
  /// its loading state.
  private(set) var isPerforming = false

  /// What the last action failed with, if it did.
  ///
  /// Distinct from `state.failed`, which is about the READ. An action failing (a revoke
  /// that was refused) must not replace the list with an error page; it is a message
  /// beside a list that is still perfectly valid.
  private(set) var lastActionError: String?

  /// What the last REFRESH failed with, if it did: a re-read over a value already on screen.
  ///
  /// Beside the list for the same reason as an action failure, and its own field for a
  /// different one: it lives exactly as long as the value is stale. The next read that
  /// succeeds clears it, and the next action does not. Stored in `lastActionError` it was
  /// cleared only by an action, so on a page that has none, a refresh that failed once was
  /// reported for the life of the window.
  private(set) var lastReloadError: String?

  /// What this screen reads.
  ///
  /// Returning `nil` means "not available yet" rather than "failed": the server is not
  /// running, so the capability behind it does not exist. That is the normal state of
  /// every one of these pages when the app opens, and reporting it as an error would put
  /// a red message on a screen where nothing is wrong. The pages already render their own
  /// `ContentUnavailableView` for it.
  private let read: @MainActor () async throws -> Value?

  /// When the loaded value was read, and for what key. Only `reload(for:unlessFresherThan:)`
  /// consults it; a screen that never calls that reads on every appearance, as before.
  private var freshness = ReadFreshness()

  /// When the value on screen was read. For a page that says how old what it shows is.
  var readAt: Date? { freshness.readAt }

  init(read: @escaping @MainActor () async throws -> Value?) {
    self.read = read
  }

  /// Reads, and records what happened.
  ///
  /// A failure keeps whatever was already loaded. The alternative (dropping to `.failed`
  /// and losing the value) means a refresh that fails once wipes a list the person was
  /// reading, which is a worse answer than a stale list with an error line above it.
  func reload() async {
    // No key: the read is for whatever key was last recorded, and the date moves. A manual
    // Refresh is this, and a visit straight after it must not read a second time.
    await load(recording: nil)
  }

  /// Reads, unless the value on screen was read for `key` less than `maxAge` ago.
  ///
  /// For a screen whose value outlives its view. `.task(id:)` fires on every appearance,
  /// so without this a page held on the model still re-read on every visit; with it, a
  /// visit inside `maxAge` shows what the last one read. A different key always reads: it
  /// means the range moved, or a version followed from a stream did, and the value on
  /// screen is of something else.
  func reload(for key: AnyHashable, unlessFresherThan maxAge: TimeInterval) async {
    if state.value != nil, freshness.isFresh(for: key, within: maxAge) { return }
    await load(recording: key)
  }

  /// Drops the value and every message, so a stopped server shows nothing stale. The next
  /// appearance reads whatever its key.
  func clear() {
    state = .idle
    lastReloadError = nil
    lastActionError = nil
    freshness.invalidate()
  }

  private func load(recording key: AnyHashable?) async {
    if state.value == nil { state = .loading }
    do {
      guard let value = try await read() else {
        state = .idle
        lastReloadError = nil
        freshness.invalidate()
        return
      }
      state = .loaded(value)
      lastReloadError = nil
      freshness.record(key)
    } catch {
      // A cancelled read is not a failure, and reports nothing. Every `reloads` is a
      // `.task(id:)`, which cancels the read in flight whenever its key moves and starts
      // another: Home's activity section keys on the message count, so a message arriving
      // mid-read cancels it. The read that was cancelled has nothing to say and the one
      // replacing it will; recorded as a failure, it put "CancellationError()" under the
      // section header. Checked both ways because a cancelled read may surface as its own
      // error type from the layer underneath rather than as `CancellationError`.
      if error is CancellationError || Task.isCancelled { return }
      // A failed refresh keeps the value (below) but not its freshness: the next visit
      // must try again rather than show the stale value for another `maxAge`.
      freshness.invalidate()
      // `DiagnosticText.sentence(for:)` rather than `String(describing:)`: the
      // interfaces layer throws `InterfaceError`, whose `body` is written to be read by
      // someone who is not a developer. `String(describing:)` on that enum renders the
      // CASE: `invalidRequest("…")`, escaped quotes and all.
      if let value = state.value {
        state = .loaded(value)
        lastReloadError = DiagnosticText.sentence(for: error)
      } else {
        state = .failed(DiagnosticText.sentence(for: error))
      }
    }
  }

  /// Runs an action, then re-reads.
  ///
  /// Re-reading rather than mutating local state is what the screens already did, and it
  /// is right: it keeps the page showing what the service actually holds, including
  /// changes it made for its own reasons: a block that expired while the window was
  /// open, an id the database assigned.
  ///
  /// - Parameter failureMessage: Replaces the error's own sentence. For the handful of
  ///   actions with one overwhelmingly likely cause that the error itself does not name:
  ///   a contacts re-index that fails is almost always a missing Contacts permission, and
  ///   "check Contacts permission" is worth more to the person reading it than the
  ///   underlying `CNError`. Leave it nil everywhere else: a generic sentence supplied
  ///   here would hide a specific one the layer already wrote.
  func perform(
    failureMessage: String? = nil,
    _ action: @MainActor () async throws -> Void
  ) async {
    lastActionError = nil
    isPerforming = true
    defer { isPerforming = false }
    do {
      // An action is something the person did, so it is recorded as theirs; see
      // `asOperator`. `OperatorAttributionPolicyTests` accepts a write inside `perform`.
      try await asOperator { try await action() }
    } catch {
      lastActionError = failureMessage ?? DiagnosticText.sentence(for: error)
      // Still re-read. The action may have partly applied before it threw, and a page
      // that skipped the refresh would show the state from before it ran.
    }
    await reload()
  }

  /// The one message this screen should be showing, if any.
  ///
  /// Action failures win over read failures because they are the more recent answer to
  /// "what just happened", and because a read failure with a value still on screen is the
  /// less urgent of the two. A failed refresh over a value comes before a failed first
  /// read only nominally: the two cannot both be set, since one needs a value and the
  /// other is the absence of one.
  ///
  /// A screen with an empty-state branch must consult this BEFORE deciding it is empty. A
  /// failed read has no value, so `value ?? []` is an empty array, and a page that keys
  /// its empty state off the count alone renders "nothing here yet" over an error, which
  /// is the same class of bug as swallowing the error in the first place.
  var problem: String? {
    lastActionError ?? lastReloadError ?? state.errorMessage
  }
}

// MARK: - Reading with the server

extension View {
  /// Reads when the page appears, and again whenever the server comes up or goes down.
  ///
  /// NOT a bare `.task { await screen.reload() }`, and the difference is the whole bug it
  /// replaces. A bare task reads once for the life of the view, and every list page is a
  /// `ListPage` that switches between `ServerStoppedNotice` and its content: the same view,
  /// so the same task. `ServerStoppedNotice` puts a Start button on every page, which makes
  /// the common path: open Devices, press Start, server comes up, page shows "No devices"
  /// over a read that ran once against no server and never again. Contacts told the person
  /// to grant a permission they already had. Keyed on `isRunning`, the read runs again the
  /// moment there is a server to read from, and the stopped notice returns to `.idle` when
  /// there is not. `ScreenReloadPolicyTests` refuses the bare form.
  func reloads<Value>(_ screen: ScreenModel<Value>, following model: AppModel) -> some View {
    task(id: model.phase.isRunning) { await screen.reload() }
  }

  /// The same, and again whenever `key` changes: for a page whose rows are written by
  /// something other than the page, such as a webhook registered by a client over HTTP.
  /// The key is a version the model follows from a stream, never a timer.
  func reloads<Value, Key: Hashable>(
    _ screen: ScreenModel<Value>, following model: AppModel, alsoOn key: Key
  ) -> some View {
    task(id: ReloadKey(isRunning: model.phase.isRunning, key: key)) { await screen.reload() }
  }

  /// The same, for a screen held on the model: the visit reads only when the key moved or
  /// the value it holds is older than `maxAge`. See `ScreenModel.reload(for:unlessFresherThan:)`.
  func reloads<Value, Key: Hashable>(
    _ screen: ScreenModel<Value>, following model: AppModel, alsoOn key: Key,
    unlessFresherThan maxAge: TimeInterval
  ) -> some View {
    let key = ReloadKey(isRunning: model.phase.isRunning, key: key)
    return task(id: key) {
      await screen.reload(for: AnyHashable(key), unlessFresherThan: maxAge)
    }
  }
}

private struct ReloadKey<Key: Hashable>: Hashable {
  let isRunning: Bool
  let key: Key
}
