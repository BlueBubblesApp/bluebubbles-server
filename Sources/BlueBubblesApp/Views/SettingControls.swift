//  SettingControls
//  The controls a generated settings row can draw, one view each.
//
//  Each control is handed a binding and a commit and knows nothing else: the row decides WHEN
//  to write (`SettingRowState`), the control only how to ask. Built inline in the row, a
//  change to how a number is edited was a change inside the view that also owns reading,
//  following, committing and the Keychain. The secure field is `SecretField`, shared with
//  the service form.
//
//  Text is edited as a draft and committed on Return or focus loss, never per keystroke;
//  see `SettingRow`. A switch, a picker and a stepper click are finished decisions and
//  commit at once.

import BBSettings
import SwiftUI

/// A checkmark for a moment after a write lands.
///
/// Commit-on-blur has one weakness a per-keystroke write does not: the moment of saving is
/// invisible, so "did that stick?" has no answer. This is that answer.
struct SavedIndicator: View {
  let isVisible: Bool

  var body: some View {
    Image(systemName: "checkmark.circle.fill")
      .foregroundStyle(StatusTone.good.tint)
      .opacity(isVisible ? 1 : 0)
      .animation(.easeInOut(duration: 0.2), value: isVisible)
      .accessibilityHidden(!isVisible)
      .accessibilityLabel("Saved")
  }
}

struct SettingToggleControl: View {
  @Binding var isOn: Bool

  var body: some View {
    Toggle("", isOn: $isOn)
      .toggleStyle(.switch)
  }
}

struct SettingTextControl: View {
  @Binding var text: String
  /// The field's hint while it is empty. A manifest field names one ("ngrok authtoken");
  /// a settings row has none.
  var placeholder = ""
  let focus: FocusState<String?>.Binding
  let focusKey: String
  let onSubmit: () -> Void
  let justSaved: Bool

  var body: some View {
    HStack(spacing: 6) {
      TextField(placeholder, text: $text)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .focused(focus, equals: focusKey)
        .onSubmit(onSubmit)
      SavedIndicator(isVisible: justSaved)
    }
  }
}

struct SettingNumberControl: View {
  @Binding var value: Int
  let range: ClosedRange<Int>?
  let focus: FocusState<String?>.Binding
  let focusKey: String
  let onSubmit: () -> Void
  /// A stepper click, which commits at once: a click is a finished decision, where a
  /// keystroke is a letter of one.
  let onStep: (Int) -> Void
  let justSaved: Bool

  var body: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      TextField("", value: $value, format: .number)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .frame(width: 120)
        .focused(focus, equals: focusKey)
        .onSubmit(onSubmit)
      // Alongside the field, and only when the setting declares a range to bound it.
      if let range {
        Stepper(
          "",
          value: Binding(
            get: { value },
            set: {
              value = $0
              onStep($0)
            }
          ),
          in: range
        )
        .labelsHidden()
      }
      SavedIndicator(isVisible: justSaved)
    }
  }
}

struct SettingPickerControl: View {
  @Binding var selection: String
  let options: [SettingPresentation.Option]

  var body: some View {
    Picker("", selection: $selection) {
      ForEach(options, id: \.value) { option in
        Text(option.label).tag(option.value)
      }
    }
    .labelsHidden()
    .controlSize(.large)
    .frame(maxWidth: 240)
  }
}

/// A control whose options depend on THIS machine, so it cannot be generated from a static
/// declaration.
///
/// Exhaustive over `CustomSettingControl`, so a control added there does not compile until
/// it is drawn here. The `nil` arm is for a setting declared `.custom` with no control
/// written yet: it renders read-only rather than blank, so a setting that lost its view is
/// visible rather than silently gone, and `CustomSettingControlTests` fails so it does not
/// stay that way.
struct SettingCustomControl: View {
  let setting: AnySetting
  /// What the row shows as the value, already rendered.
  let selection: String
  let onChange: (String) -> Void

  var body: some View {
    switch CustomSettingControl(key: setting.key) {
    case .connectionMethod:
      ConnectionMethodRow(setting: setting, selection: selection, onChange: onChange)
    case .bindAddress:
      NetworkAddressPicker(
        label: setting.presentation.label,
        help: setting.presentation.help,
        selection: selection,
        choices: NetworkAddressChoices.bind(),
        onChange: onChange
      )
    case nil:
      SettingsRow(title: setting.presentation.label, help: setting.presentation.help) {
        Text(selection).foregroundStyle(.secondary)
      }
    }
  }
}
