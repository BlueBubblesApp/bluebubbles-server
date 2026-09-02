//  ScreenModel
//  What a screen that reads from the server holds, in one place.
//
//  Every administration page was written the same way and written from scratch: a
//  `@State` array per collection, a private `reload()`, a private `mutate` wrapper, and a
//  `@State var error: String?`. Seven screens, seven copies, and they had already drifted
//  apart in the way copies do:
//
//    - `WebhooksView` and `SecurityAdministration` both DECLARED an error, both RENDERED
//      it, and neither ever assigned it. The failure path was dead code in both: a webhook
//      that could not be listed showed an empty list, and a `remove` that threw showed
//      nothing at all.
//    - `WebhooksView.reload` read a list with `(try? await …) ?? []`, so "the server
//      refused" and "there are none" arrived at the view as the same value.
//    - Screens loading two or three collections re-read them as separate statements, so a
//      failure halfway through left the page showing one fresh collection beside two stale
//      ones, with nothing saying so.
//
//  So this is the load half of a screen, once. A screen supplies WHAT to read as a single
//  `Value` — a snapshot struct when it needs more than one collection, which is also what
//  makes the read atomic — and gets back a state it can switch on. Errors are captured
//  rather than swallowed, because the pattern that swallowed them is what put dead error
//  views into two screens.
//
//  It is deliberately NOT a base class to subclass. Screens compose one (or two: see
//  `LogsView`) as `@State`, and their own actions stay declared at the call site where
//  they read — `perform { try await service.revoke(…) }` — so nothing has to be overridden
//  and a screen that needs something unusual is not fighting an inherited shape.
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
  /// A reload that fails keeps the previous value visible — see `ScreenModel.reload` —
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
/// actor — the interfaces layer is `Sendable` and does its own isolation — so `await`
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
  /// Distinct from `state.failed`, which is about the READ. An action failing — a revoke
  /// that was refused — must not replace the list with an error page; it is a message
  /// beside a list that is still perfectly valid. A failed REFRESH lands here too, for the
  /// same reason: there is already a value on screen, so the failure is a line above it
  /// rather than a state the page drops into.
  private(set) var lastActionError: String?

  /// What this screen reads.
  ///
  /// Returning `nil` means "not available yet" rather than "failed" — the server is not
  /// running, so the capability behind it does not exist. That is the normal state of
  /// every one of these pages when the app opens, and reporting it as an error would put
  /// a red message on a screen where nothing is wrong. The pages already render their own
  /// `ContentUnavailableView` for it.
  private let read: @MainActor () async throws -> Value?

  init(read: @escaping @MainActor () async throws -> Value?) {
    self.read = read
  }

  /// Reads, and records what happened.
  ///
  /// A failure keeps whatever was already loaded. The alternative — dropping to `.failed`
  /// and losing the value — means a refresh that fails once wipes a list the person was
  /// reading, which is a worse answer than a stale list with an error line above it.
  func reload() async {
    if state.value == nil { state = .loading }
    do {
      guard let value = try await read() else {
        state = .idle
        return
      }
      state = .loaded(value)
    } catch {
      // `DiagnosticText.sentence(for:)` rather than `String(describing:)`: the
      // interfaces layer throws `InterfaceError`, whose `body` is written to be read by
      // someone who is not a developer. `String(describing:)` on that enum renders the
      // CASE — `invalidRequest("…")`, escaped quotes and all.
      if let value = state.value {
        state = .loaded(value)
        lastActionError = DiagnosticText.sentence(for: error)
      } else {
        state = .failed(DiagnosticText.sentence(for: error))
      }
    }
  }

  /// Runs an action, then re-reads.
  ///
  /// Re-reading rather than mutating local state is what the screens already did, and it
  /// is right: it keeps the page showing what the service actually holds, including
  /// changes it made for its own reasons — a block that expired while the window was
  /// open, an id the database assigned.
  ///
  /// - Parameter failureMessage: Replaces the error's own sentence. For the handful of
  ///   actions with one overwhelmingly likely cause that the error itself does not name:
  ///   a contacts re-index that fails is almost always a missing Contacts permission, and
  ///   "check Contacts permission" is worth more to the person reading it than the
  ///   underlying `CNError`. Leave it nil everywhere else — a generic sentence supplied
  ///   here would hide a specific one the layer already wrote.
  func perform(
    failureMessage: String? = nil,
    _ action: @MainActor () async throws -> Void
  ) async {
    lastActionError = nil
    isPerforming = true
    defer { isPerforming = false }
    do {
      try await action()
    } catch {
      lastActionError = failureMessage ?? DiagnosticText.sentence(for: error)
      // Still re-read. The action may have partly applied before it threw, and a page
      // that skipped the refresh would show the state from before it ran.
    }
    await reload()
  }

  /// Clears an action failure. For a screen that shows one next to a field it has since
  /// cleared.
  func clearActionError() {
    lastActionError = nil
  }

  /// The one message this screen should be showing, if any.
  ///
  /// Action failures win over read failures because they are the more recent answer to
  /// "what just happened", and because a read failure with a value still on screen is the
  /// less urgent of the two.
  ///
  /// A screen with an empty-state branch must consult this BEFORE deciding it is empty. A
  /// failed read has no value, so `value ?? []` is an empty array — and a page that keys
  /// its empty state off the count alone renders "nothing here yet" over an error, which
  /// is the same class of bug as swallowing the error in the first place.
  var problem: String? {
    lastActionError ?? state.errorMessage
  }
}

// MARK: - Presentation

/// The message a screen shows when a read or an action failed.
///
/// One view rather than the four different spellings the pages had grown — `.caption`
/// red text in two of them, a `SettingsFootnote` in a third, and nothing at all in the
/// two where the state was never assigned.
struct ScreenErrorLine: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.callout)
      .foregroundStyle(.red)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel("Error: \(message)")
  }
}
