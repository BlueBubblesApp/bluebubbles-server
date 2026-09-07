//  CopyableValue
//  A value someone is going to paste somewhere else.
//
//  Three screens had written this out by hand — the read-only settings row, the API address
//  on the webhooks page, and the address on Guides — and the copies had already drifted:
//  one disabled its button on a sentinel string, one hid it, one showed a `.help` tooltip and
//  the others did not. The address is the single value in this app most likely to be typed in
//  wrong somewhere else, so the control that hands it over should behave the same everywhere
//  it appears.
//
//  Deliberately NOT used for the two bulk "Copy" buttons on Logs and Notifications. Those
//  copy a page's worth of text that is not otherwise displayed as one value, and they belong
//  with that page's actions rather than beside a field.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import SwiftUI

struct CopyableValue: View {

  /// The value. Empty means "there isn't one yet", and renders as `placeholder` with no
  /// button — copying an empty string looks like it worked and pastes nothing.
  let value: String
  /// What to show instead when there is no value. Say what is missing and why, not "none":
  /// "not published yet" tells someone the server has not finished, "Not set" tells them
  /// nobody has filled it in, and those lead to different next steps.
  var placeholder: String = "Not set"

  /// Unlabelled first argument, so a call site reads as the value it is showing —
  /// `CopyableValue(status.address)` rather than `CopyableValue(value: status.address)`.
  init(_ value: String, placeholder: String = "Not set") {
    self.value = value
    self.placeholder = placeholder
  }

  @State private var didCopy = false

  private var isEmpty: Bool { value.isEmpty }

  var body: some View {
    HStack(spacing: 6) {
      Text(isEmpty ? placeholder : value)
        // Monospaced because these are addresses and identifiers, where `l`/`1` and
        // `O`/`0` have to be tellable apart by eye.
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
        // Selectable as well as copyable: someone wanting only the hostname out of a URL
        // cannot get it from a button.
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)

      if !isEmpty {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(value, forType: .string)
          didCopy = true
        } label: {
          // The checkmark is the whole point of the state. A clipboard write produces no
          // visible change anywhere on screen, so without it the honest reading of a
          // click that did nothing is that the click missed.
          Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .foregroundStyle(didCopy ? Color.green : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help("Copy")
        .accessibilityLabel("Copy")
        .task(id: didCopy) {
          guard didCopy else { return }
          try? await Task.sleep(for: .seconds(2))
          didCopy = false
        }
        // A tunnel republishes its address on its own initiative, and a tick still on
        // screen when that happens claims the NEW address was copied. It was not.
        .onChange(of: value) { didCopy = false }
      }
    }
  }
}
