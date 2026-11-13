//  ListPage
//  A page whose content is a list the server reads: stopped, switched off, loading, empty, or
//  rows, as one closed `switch`.
//
//  Five pages wrote this as an `else if` chain each, and the chains had drifted apart: one
//  forgot the failed-read guard on its empty state, one had no final `else` and drew nothing
//  in the state it forgot. The decision is `ListPagePolicy.state`, a value with no view in
//  it, and this is the one `switch` over it, so the compiler checks that every state draws
//  something and a page cannot forget one. `ScreenLoadingStatePolicyTests` refuses a page
//  that composes a `ScreenModel` and draws the whole-page stopped notice itself.
//
//  What a page still owns is what differs between them: the empty state (an invitation, a
//  sentence, a placeholder in a card), the rows, and the FRAME the list area sits in. Audit
//  Log and Contacts keep their filters and pager on screen while the table loads, so the
//  loading notice belongs inside their card; Firebase's devices list has nothing around it,
//  so the notice is the page. The frame is a `@ViewBuilder` handed the list area as a
//  concrete view (`ListContent`), the same generic-slot shape `SettingsSection` and
//  `ConfigureSheet` use, never an `AnyView`.
//
//  Stopped and switched off are NOT drawn inside the frame. With no server, or the feature
//  off, the filters and toolbar counts describe a read that cannot happen; the notice stands
//  in for the whole page, with the button that ends the state on it.

import BBServiceKit
import SwiftUI

/// The integration a list page is a view of, and what is not happening while it is off.
///
/// Not nested in `ListPage`: a type inside a generic view can only be named with all four of
/// its parameters spelled out.
struct ListPageFeature {
  let manifest: ServiceManifest
  /// See `FeatureDisabledNotice.consequence`.
  let consequence: String
}

struct ListPage<Value: Sendable, Frame: View, Empty: View, Rows: View>: View {

  @Bindable var model: AppModel
  let screen: ScreenModel<Value>
  /// The page's own symbol, for the stopped notice: see `ServerStoppedNotice.Placement.page`.
  let symbol: String
  /// What starting the server would let the person do; see `ServerStoppedNotice.purpose`.
  let purpose: String
  /// What is being read, completing "Loading …"; see `LoadingNotice.subject`.
  let subject: String
  /// Nil for a page that is not one integration's view.
  let feature: ListPageFeature?
  /// Whether there are no rows in hand. A Bool rather than a rule over `Value`, because what
  /// counts as a row differs: a page of records carries a total and a note beside them.
  let isEmpty: Bool
  private let frame: (ListContent<Empty, Rows>) -> Frame
  private let empty: () -> Empty
  private let rows: () -> Rows

  init(
    model: AppModel,
    screen: ScreenModel<Value>,
    symbol: String,
    purpose: String,
    subject: String,
    feature: ListPageFeature? = nil,
    isEmpty: Bool,
    @ViewBuilder empty: @escaping () -> Empty,
    @ViewBuilder rows: @escaping () -> Rows,
    // LAST, after the two closures that fix `Empty` and `Rows`: its parameter is built from
    // both, and in a `body` the type checker meets the closures in order, so a frame written
    // first could not say what it was being handed.
    @ViewBuilder frame: @escaping (ListContent<Empty, Rows>) -> Frame
  ) {
    self.model = model
    self.screen = screen
    self.symbol = symbol
    self.purpose = purpose
    self.subject = subject
    self.feature = feature
    self.isEmpty = isEmpty
    self.frame = frame
    self.empty = empty
    self.rows = rows
  }

  /// A page with nothing around its list: each state stands in for the whole page.
  init(
    model: AppModel,
    screen: ScreenModel<Value>,
    symbol: String,
    purpose: String,
    subject: String,
    feature: ListPageFeature? = nil,
    isEmpty: Bool,
    @ViewBuilder empty: @escaping () -> Empty,
    @ViewBuilder rows: @escaping () -> Rows
  ) where Frame == ListContent<Empty, Rows> {
    self.init(
      model: model, screen: screen, symbol: symbol, purpose: purpose, subject: subject,
      feature: feature, isEmpty: isEmpty, empty: empty, rows: rows, frame: { $0 })
  }

  private var isDisabled: Bool {
    guard let feature else { return false }
    return !model.integrations.isEnabled(feature.manifest)
  }

  var body: some View {
    switch ListPagePolicy.state(
      isRunning: model.phase.isRunning, isDisabled: isDisabled,
      isLoading: screen.state.isLoading, isEmpty: isEmpty, problem: screen.problem)
    {
    case .stopped:
      ServerStoppedNotice(model: model, placement: .page(symbol: symbol), purpose: purpose)
    case .disabled:
      // `isDisabled` is true only with a feature, so this is never the fallback; the
      // `if let` is the unwrap, and the empty `else` is unreachable rather than a state.
      if let feature {
        FeatureDisabledNotice(
          manifest: feature.manifest, model: model, placement: .page,
          consequence: feature.consequence)
      } else {
        EmptyView()
      }
    case .running(let content):
      frame(ListContent(content: content, subject: subject, empty: empty, rows: rows))
    }
  }
}

/// The list area of a running `ListPage`: loading, empty or rows.
///
/// Its own type so a page's frame can place it, and public to the module for that reason
/// only. A section whose page decides `stopped` and `disabled` for itself (the webhook list,
/// on a page that also shows the API address) builds one from `ListPagePolicy.content`.
struct ListContent<Empty: View, Rows: View>: View {
  let content: ListPagePolicy.Content
  let subject: String
  let empty: () -> Empty
  let rows: () -> Rows

  var body: some View {
    switch content {
    case .loading:
      // Ahead of the empty state: a list that has not been read yet also has no rows, and
      // its empty state is an answer nobody has established.
      LoadingNotice(subject: subject)
    case .empty:
      empty()
    case .listing:
      rows()
    }
  }
}
