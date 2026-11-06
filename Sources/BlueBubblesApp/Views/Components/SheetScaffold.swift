//  SheetScaffold
//  The shape every sheet in this app has: a title block, the content, and a footer that
//  commits or closes it, with a Cancel beside it when there is something to cancel.
//
//  Extracted because the sheets had each written it out, and the copies had drifted in the
//  only way that shows: titles in `.headline` on some and `.title3` on others, the commit
//  button in the header on two and the footer on the rest, Cancel to the left of the footer
//  on one and beside the commit on the others, and widths of 520, 540, 620 and 640 for no
//  reason any file gave.
//
//  Two footers, because there are two kinds of sheet. An EDITING sheet cancels or commits; a
//  READ-ONLY one (the audit record inspector) has nothing to commit, and a Cancel beside a
//  Done there would offer to undo a change nobody made. The footer is a closed choice between
//  the two, not an optional, so neither kind can end up with no way out.
//
//  What it deliberately does NOT own is the content. A sheet's fields are the part that differs
//  every time, so they are a `@ViewBuilder` and this only supplies the frame, the scrolling and
//  the chrome around them.
//
//  The other things that differ between sheets are parameters, and each is a decision about
//  the sheet rather than a styling choice:
//
//  - `cancel`, because a sheet whose fields save as they are edited (a service's Configure
//    form, the HTTP listener) holds nothing back, so a Cancel there would promise an undo that
//    does not exist. It has one button, Done, in the same place every other sheet commits.
//  - `scrollsContent`, because a `List` inside the scaffold's scroll view has no height of its
//    own and collapses: the same reason `TablePage` exists beside `SettingsPage`. The project
//    picker is a selectable list and scrolls itself.
//
//  The footer is never optional. Every sheet ends with a button that closes it, and a sheet
//  whose way out moves depending on which one it is teaches people to hunt for it.

import SwiftUI

/// What a sheet offers beside its commit button.
enum SheetCancel {
  /// "Cancel", which dismisses the sheet. What nearly every sheet wants.
  case dismiss
  /// A cancel with its own name and action, for a sheet whose presentation is held on a
  /// model: closing the sheet is not the whole of cancelling there, the model has to be told.
  case action(title: String, perform: () -> Void)
  /// No cancel at all, for a sheet whose fields save as they are edited. The commit button is
  /// "Done": there is nothing held back to discard.
  case none
}

struct SheetScaffold<Content: View>: View {

  /// How the sheet closes.
  enum Footer {
    /// A cancel (see `SheetCancel`) and a prominent button that commits. `confirmTitle` is
    /// named for the action ("Schedule", "Add", "Save", "Done") so the button says what
    /// happens rather than "OK"; `isEnabled` is false while the form is incomplete or a save
    /// is in flight; `error` is shown beside the buttons, nil when there is nothing wrong.
    case commit(
      confirmTitle: String, isEnabled: Bool, error: String?, cancel: SheetCancel,
      confirm: () async -> Void)
    /// A single Done, for a sheet that only shows something.
    case done
  }

  let title: String
  /// One line under the title saying what the sheet does or where the result goes.
  let subtitle: String
  let footer: Footer
  /// False for content that scrolls itself, a `List`; see the header.
  let scrollsContent: Bool
  /// The size the sheet opens at, named for what it holds (`SheetSize`). A person can drag
  /// it larger; it will not go below the size's minimum, which is what keeps the footer
  /// reachable at a larger text size.
  let size: SheetSize
  @ViewBuilder let content: () -> Content

  @Environment(\.dismiss) private var dismiss

  /// An editing sheet: Cancel, and a button that commits.
  init(
    title: String,
    subtitle: String,
    confirmTitle: String,
    isConfirmEnabled: Bool = true,
    error: String? = nil,
    cancel: SheetCancel = .dismiss,
    scrollsContent: Bool = true,
    size: SheetSize = .form,
    confirm: @escaping () async -> Void,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.footer = .commit(
      confirmTitle: confirmTitle, isEnabled: isConfirmEnabled, error: error, cancel: cancel,
      confirm: confirm)
    self.scrollsContent = scrollsContent
    self.size = size
    self.content = content
  }

  /// A read-only sheet: Done, and nothing to commit.
  init(
    title: String,
    subtitle: String,
    scrollsContent: Bool = true,
    size: SheetSize = .form,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.footer = .done
    self.scrollsContent = scrollsContent
    self.size = size
    self.content = content
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if scrollsContent {
        ScrollView {
          VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            content()
          }
          .padding(SettingsMetrics.pagePadding)
        }
      } else {
        content()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      footerBar
    }
    .sheetFrame(size)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.title3.weight(.semibold))
      Text(subtitle)
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
  }

  private var footerBar: some View {
    HStack(spacing: 12) {
      switch footer {
      case .commit(let confirmTitle, let isEnabled, let error, let cancel, let confirm):
        // Left of the buttons rather than above the field that caused it: a save that was
        // refused by the server has no one field to blame, and this is the place someone is
        // already looking when the button does not close the sheet.
        if let error {
          ErrorLine(error)
        }
        Spacer()
        switch cancel {
        case .dismiss:
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        case .action(let title, let perform):
          Button(title, action: perform)
            .keyboardShortcut(.cancelAction)
        case .none:
          EmptyView()
        }
        Button(confirmTitle) { Task { await confirm() } }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!isEnabled)
      case .done:
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
  }
}
