//  ErrorLine
//  A failure, said in one line where it happened.
//
//  A read that failed, a write that was refused, an entry the server would not take: each
//  is one sentence (from `DiagnosticText`) under or beside the thing that failed, and it is
//  drawn here so it reads the same on every page. Nine spellings had grown up (a red `Text`,
//  a red caption, an orange `Label`, a red footnote, two copies of this view) and a person
//  meeting two of them on one screen could not tell whether they meant the same thing.
//
//  NOT for a footnote in a settings row's list, which is `SettingsFootnote` keyed by its
//  `Kind` so a row shows one of each; and not for a state a page is IN rather than an attempt
//  that failed, which is a `NoticeCard` or a `ServiceStatusLine`.

import SwiftUI

struct ErrorLine: View {

  /// How much room the line takes.
  enum Size {
    /// Under a page's or a section's content, or in a sheet's footer.
    case regular
    /// Inside a row, beside the row's own caption-sized detail.
    case compact
  }

  let message: String
  var size: Size = .regular

  /// Unlabelled first argument, so a call site reads as the message it is showing.
  init(_ message: String, size: Size = .regular) {
    self.message = message
    self.size = size
  }

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(size == .regular ? .callout : .caption)
      .foregroundStyle(StatusTone.problem.tint)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel("Error: \(message)")
  }
}
