//  ListPagePolicy
//  Which of its states a list page is in, decided off the view.
//
//  Five pages (Scheduled Messages, API & Webhooks, Audit Log, Contacts and Firebase's
//  registered devices) each wrote the same decision as an `else if` chain in `body`: no
//  server, the feature switched off, still reading, nothing there, or rows. The chains had
//  drifted. Contacts showed "No contacts indexed" over a read that had FAILED, telling the
//  person to grant a permission that was working; Audit Log's chain had no final `else`, so a
//  failed first read drew nothing at all where the table goes. The rule that keeps both out
//  (`SubscriptionPolicy.Page`) is to decide the state here, as a value, and `switch` on it,
//  so the compiler checks that every state draws something. `ListPage` is the one `switch`.
//
//  Off the view for the usual reason: touching a SwiftUI `View` type from a test process
//  traps, and `ListPagePolicyTests` pins the order of these rules.

import Foundation

enum ListPagePolicy {

  /// The page as a whole.
  enum State: Equatable, Sendable {
    /// No server, so nothing to read. `ServerStoppedNotice` stands in for the page.
    case stopped
    /// The feature the page is a view of is switched off. `FeatureDisabledNotice` stands in
    /// for the page, with the switch on it.
    case disabled
    /// The server is up and the feature is on: the page draws its own frame, and the list
    /// area inside it is in one of `Content`'s states.
    case running(Content)
  }

  /// The list area inside a running page.
  enum Content: Equatable, Sendable {
    /// Asked and not answered, with nothing in hand. `LoadingNotice`.
    case loading
    /// Read, and there is nothing. The page's own empty state, which is usually an
    /// invitation, so it must be an answer the server actually gave.
    case empty
    /// Rows, or a read that failed with none. The rows carry the page's error line, so a
    /// failure is said where the rows would be rather than dressed as an empty list.
    case listing
  }

  /// Total by construction: every input maps to something a page can draw.
  ///
  /// The order is the rule. `stopped` outranks everything, because a stopped server keeps
  /// whatever was last read and showing it would present stale rows as live. `disabled`
  /// outranks the read, because with the feature off the read is refused or describes a
  /// feature that has stopped. Loading is checked before empty, because a collection is
  /// empty before its first result lands; and a `problem` keeps the empty state away, because
  /// a table that could not be read is also empty.
  static func state(
    isRunning: Bool, isDisabled: Bool = false, isLoading: Bool, isEmpty: Bool, problem: String?
  ) -> State {
    guard isRunning else { return .stopped }
    guard !isDisabled else { return .disabled }
    return .running(content(isLoading: isLoading, isEmpty: isEmpty, problem: problem))
  }

  /// The list area alone, for a section whose page decides `stopped` and `disabled` itself.
  static func content(isLoading: Bool, isEmpty: Bool, problem: String?) -> Content {
    guard isEmpty else { return .listing }
    if isLoading { return .loading }
    return problem == nil ? .empty : .listing
  }
}
