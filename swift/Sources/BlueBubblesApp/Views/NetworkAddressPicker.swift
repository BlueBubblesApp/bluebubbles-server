//  NetworkAddressPicker
//  Choosing a network address from what this Mac actually has.
//
//  The generated settings screen renders a `.picker` from options declared statically in
//  `BBSettings`, which cannot work here: the options are this machine's live interfaces, and
//  they change when a cable is plugged in or a VPN connects. `.custom` exists for exactly
//  this case — the handful of bespoke screens the generated form cannot produce.
//
//  Both pickers show the INTERFACE NAME alongside the address, which is the whole reason a
//  user needs this control. "192.168.1.42" and "10.211.55.2" tell you nothing; "en0" and
//  "bridge100" tell you which one is your actual network and which one is Parallels.
//
//  See `.claude/docs/architecture.md`.

import BBSettings
import BBSystem
import SwiftUI

struct NetworkAddressPicker: View {

  typealias Choice = NetworkAddressChoices.Choice

  let label: String
  let help: String?
  let selection: String
  let choices: [Choice]
  let onChange: (String) -> Void

  var body: some View {
    // The same two-column shape the generated rows use, so a bespoke control does not
    // announce itself as different from the ones around it.
    SettingsRow(title: label, help: help) {
      Picker("", selection: binding) {
        ForEach(NetworkAddressChoices.including(selection: selection, in: choices)) { choice in
          Text(choice.label).tag(choice.value)
        }
      }
      .labelsHidden()
      .controlSize(.large)
      .frame(maxWidth: 280)
    }
  }

  private var binding: Binding<String> {
    Binding(get: { selection }, set: { onChange($0) })
  }

  /// The live choices, plus the current value if it is not among them.
  ///
  /// Without that fallback a saved address whose interface has since gone away would not
  /// appear in its own picker, so SwiftUI would render an empty selection and the first
  /// interaction would silently change the setting. Showing it as unavailable is honest and
  /// keeps the control from lying about what is stored.
}
