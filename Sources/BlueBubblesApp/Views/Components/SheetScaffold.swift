//  SheetScaffold
//  The shape every editing sheet in this app has: a title block, the fields, and a footer that
//  cancels or commits.
//
//  Extracted because two sheets had written it out identically: the same title stack at the
//  same padding, the same divider pair, the same footer with an error label pushed left of a
//  Cancel and a prominent confirm button. They had already drifted in the only way that shows:
//  one was 640pt wide and the other 620, for no reason either file gave.
//
//  What it deliberately does NOT own is the content. A sheet's fields are the part that differs
//  every time, so they are a `@ViewBuilder` and this only supplies the frame, the scrolling and
//  the chrome around them.
//
//  Not used by the connection method's Configure sheet: that one puts Done in its header rather
//  than committing from a footer, because its form saves each field as it is edited. A scaffold
//  that stretched to cover both would have to make the footer optional, which is the point where
//  a shared shape stops being a shape.

import SwiftUI

struct SheetScaffold<Content: View>: View {

  let title: String
  /// One line under the title saying what the sheet does or where the result goes.
  let subtitle: String
  /// The commit button's label: "Schedule", "Add", "Save". Named for the action, so the
  /// button says what happens rather than "OK".
  let confirmTitle: String
  /// False while the form is incomplete or a save is in flight.
  let isConfirmEnabled: Bool
  /// Shown in the footer beside the buttons. Nil when there is nothing wrong.
  let error: String?
  /// The size the sheet opens at. A person can drag it larger; it will not go below
  /// `minimumSize`, which is what keeps the footer reachable at a larger text size.
  let width: CGFloat
  let height: CGFloat

  /// Computed, because a generic type cannot hold a static stored property.
  private static var minimumSize: CGSize { CGSize(width: 520, height: 440) }
  let confirm: () async -> Void
  @ViewBuilder let content: () -> Content

  @Environment(\.dismiss) private var dismiss

  init(
    title: String,
    subtitle: String,
    confirmTitle: String,
    isConfirmEnabled: Bool,
    error: String? = nil,
    width: CGFloat = 640,
    height: CGFloat = 660,
    confirm: @escaping () async -> Void,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.confirmTitle = confirmTitle
    self.isConfirmEnabled = isConfirmEnabled
    self.error = error
    self.width = width
    self.height = height
    self.confirm = confirm
    self.content = content
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
          content()
        }
        .padding(SettingsMetrics.pagePadding)
      }
      Divider()
      footer
    }
    .frame(
      minWidth: Self.minimumSize.width, idealWidth: width,
      minHeight: Self.minimumSize.height, idealHeight: height)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.title3.weight(.semibold))
      Text(subtitle)
        .font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      // Left of the buttons rather than above the field that caused it: a save that was
      // refused by the server has no one field to blame, and this is the place someone is
      // already looking when the button does not close the sheet.
      if let error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Error: \(error)")
      }
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(confirmTitle) { Task { await confirm() } }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!isConfirmEnabled)
    }
    .padding(16)
  }
}
