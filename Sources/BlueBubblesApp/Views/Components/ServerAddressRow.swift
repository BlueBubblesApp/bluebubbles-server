//  ServerAddressRow
//  The address a person types into a client, wherever the app shows it.
//
//  Six screens derived and drew this themselves and no two agreed: two read it once and went
//  stale when a tunnel republished, two fell back to `http://localhost:<port>` (which on a
//  phone is the phone), one showed a `"-"` sentinel, one started from a hard-coded port and
//  drew plain text with no copy button, and only two blanked it when nothing was listening
//  behind it. It is the single value in this app most likely to be typed in wrong somewhere
//  else, so it has one row.
//
//  The value is the model's followed `addressToShare`, so it moves while the person watches;
//  the placeholder and the note are `APIReachability`'s, so a stored address is never shown
//  as the thing to type while the listener is off or failed.

import SwiftUI

struct ServerAddressRow: View {

  let model: AppModel
  /// The label beside the value, or nil for a row whose section header already names it.
  var label: String? = "Server URL"

  private var reachability: APIReachability { model.apiReachability }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let label {
        LabeledContent(label) { value }
      } else {
        value
      }
      if let note = reachability.note {
        Text(note)
          .font(.caption)
          .foregroundStyle(StatusTone.attention.tint)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var value: some View {
    CopyableValue(model.addressToShare, placeholder: reachability.addressPlaceholder)
  }
}
