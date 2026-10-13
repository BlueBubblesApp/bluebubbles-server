//  Pager
//  Where in a database-paged list the page sits, and the way to the pages either side.
//
//  Contacts and the Audit Log drew this identically, down to the control size, and differed
//  only in what the two buttons are called: a list in time reads "Newer" and "Older", a list in
//  an order the person picked reads "Previous" and "Next". The rules are `PageCursor`; this is
//  only the row that shows them.
//
//  Shown only when there is more than a page. A pager under a table of nine rows is a control
//  with nothing to do. It is deliberately NOT where the clamp happens: the clamp has to run
//  whether or not there is a pager on screen, because a set that shrank to one page is
//  exactly the case where this row disappears.

import SwiftUI

struct Pager: View {

  @Binding var cursor: PageCursor
  /// How many rows the page on screen holds.
  let showing: Int
  /// How many rows match, across every page.
  let total: Int
  /// The plural noun the summary counts when there is nothing to show: "records".
  let noun: String
  var previousTitle = "Previous"
  var nextTitle = "Next"

  var body: some View {
    if cursor.isPaged(total: total) {
      HStack(spacing: 10) {
        Text(cursor.summary(showing: showing, total: total, noun: noun))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()

        Spacer()

        Button {
          cursor.previous()
        } label: {
          Label(previousTitle, systemImage: "chevron.left")
        }
        .disabled(!cursor.hasPrevious)

        Button {
          cursor.next()
        } label: {
          Label(nextTitle, systemImage: "chevron.right")
        }
        .disabled(!cursor.hasNext(total: total))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }
}
