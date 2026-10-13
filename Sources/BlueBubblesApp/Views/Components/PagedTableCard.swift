//  PagedTableCard
//  A page built around a database-paged `Table`: one card holding the controls that narrow
//  it, a line for what went wrong or what the last action did, the list, and the pager.
//
//  Contacts and the Audit Log were near-copies of this, and the parts that have to be the
//  same are the ones that are easy to get wrong. The controls and the pager stay where they
//  are while a read is in flight, because `list` is whatever `ListPage` decided (the loading
//  notice, the empty state or the table). The page is pulled back into range when the set
//  shrinks under it, which has to happen HERE rather than on the `Pager`: the pager is not on
//  screen once the set fits one page, and that is exactly when the clamp is needed.
//
//  `TablePage` and `ContentCard` for the reasons they give: a `Table` in a scroll view has no
//  height of its own, and glass the size of a page samples a page of desktop.
//
//  The controls are stacked in the card rather than floated with `.safeAreaInset`. That inset
//  existed because a `Table` placed as the root of a `NavigationSplitView` detail column
//  insets itself for the title bar, and anything above it in a `VStack` took that away: the
//  first rows drew behind the header. The card's own padding plus the page padding puts about
//  fifty points of chrome above the first row, which is the space that inset was reserving.
//  If a row ever hides under the title bar again, THIS is the paragraph that was wrong.

import SwiftUI

struct PagedTableCard<Value: Sendable, Controls: View, Notes: View, List: View>: View {

  let screen: ScreenModel<Value>
  @Binding var cursor: PageCursor
  /// How many rows are on this page.
  let showing: Int
  /// How many match, from the same read as the rows.
  let total: Int
  /// What a row is: "contact", "record".
  let noun: String
  var previousTitle = "Previous"
  var nextTitle = "Next"
  /// What the last action did, when it is a count rather than a failure ("Indexed 412").
  /// Shown only while there is no failure to report.
  let status: String?
  private let controls: Controls
  private let notes: Notes
  private let list: List

  init(
    screen: ScreenModel<Value>, cursor: Binding<PageCursor>, showing: Int, total: Int,
    noun: String, previousTitle: String = "Previous", nextTitle: String = "Next",
    status: String?, list: List,
    @ViewBuilder controls: () -> Controls,
    @ViewBuilder notes: () -> Notes = { EmptyView() }
  ) {
    self.screen = screen
    self._cursor = cursor
    self.showing = showing
    self.total = total
    self.noun = noun
    self.previousTitle = previousTitle
    self.nextTitle = nextTitle
    self.status = status
    self.list = list
    self.controls = controls()
    self.notes = notes()
  }

  var body: some View {
    TablePage {
      ContentCard {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardStackSpacing) {
          controls

          if let message = screen.problem {
            ErrorLine(message)
          } else if let status {
            Text(status).font(.caption).foregroundStyle(.secondary)
          }
          notes

          list

          Pager(
            cursor: $cursor, showing: showing, total: total, noun: noun,
            previousTitle: previousTitle, nextTitle: nextTitle)
        }
      }
    }
    // Rows can disappear while the page is open (a sweep, an account unlinked), and an
    // offset past the end answers with no rows: an empty table that reads as a failed read.
    // Pulled back into range, and read again only if it actually moved.
    .onChange(of: total) { _, newTotal in
      guard cursor.clamp(toTotal: newTotal) else { return }
      Task { await screen.reload() }
    }
  }
}
