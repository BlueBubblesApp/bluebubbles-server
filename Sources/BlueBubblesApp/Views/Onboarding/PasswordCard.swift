//  PasswordCard
//  The top of the connection step: the password, and the port a client will use.
//
//  Has no Save button. Its state belongs to `OnboardingView`, which writes it when Continue
//  is pressed; see `saveCredentials`. A card that saved for itself could be walked straight
//  past, and was.
//
//  Not the generated `SettingRow`, deliberately: that row commits on focus loss, and the
//  Continue button both blurs the field and reads the result, which is a race. The gate on
//  this step is the one place in the app that must be certain a password exists.
//
//  **An existing password is kept, not re-asked.** The field stays empty either way (see the
//  `.task`), so "there is already one" has to be stated, or the step is indistinguishable
//  from a fresh install: a person who had just adopted an Electron install was shown a blank
//  Password field, concluded the migration had lost it, and would have replaced a working
//  password with a new one and disconnected every client they had already paired.

import BBSettings
import SwiftUI

struct PasswordCard: View {

  @Bindable var model: AppModel
  @Binding var password: String
  @Binding var port: Int
  /// Why the password is unacceptable. Empty string means "nothing typed yet", which is
  /// still unacceptable but should not be shouted at someone who has not started.
  let rejection: String?
  let saveError: String?
  /// Whether the store already holds a password: a re-run of setup, or a migrated Electron
  /// install. Owned by `OnboardingView`, because the gate and the save both turn on it.
  var hasStoredPassword = false
  /// Whether the port row is shown. Off for a setup nothing connects to.
  var showsPort = true

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 14) {
        SettingsRow(
          title: "Password",
          help: hasStoredPassword
            ? "This server already has one, and it is kept unless you type a new one here."
            : "Choose something long. Generate one if you would rather not think of one."
        ) {
          // Above the field, not beside it, matching the settings row this card stands in
          // for. Sharing one line, the button takes the width the password needs to be
          // readable in, on the screen where the password is first chosen.
          VStack(alignment: .trailing, spacing: 6) {
            // Offered rather than imposed. The policy rejects weak passwords, and the
            // fastest way past a rejection is one that passes by construction.
            Button("Generate") { password = PasswordPolicy.generate() }
              .help("Create a strong random password")
              .controlSize(.small)
            // The prompt carries the state, because the field cannot: the stored value is
            // never read back into it (see the `.task`), so an empty field means either
            // "nothing set" or "set, and not shown", and those are opposite situations.
            SecureField(
              hasStoredPassword ? "Unchanged" : "", text: $password
            )
            .textFieldStyle(.roundedBorder)
          }
        }

        // Directly under the field it judges, and above the port row rather than below it.
        // Trailing the whole card, "Strong enough." sat under Port and read as a verdict on
        // the port number, which it never was, and which is nonsense for a value that is
        // either free or taken.
        //
        // Required, and said so before the Continue button is discovered to be dead. An
        // empty password is not "no authentication": the server refuses every request
        // with a misconfiguration error, which reads like a bug rather than a missing step.
        if let rejection {
          SettingsFootnote(
            text: rejection.isEmpty
              ? "A password is required. Without one the server rejects every client."
              : rejection,
            symbol: "exclamationmark.triangle.fill",
            tone: rejection.isEmpty ? .neutral : .error
          )
        } else if hasStoredPassword, password.isEmpty {
          // NOT "Strong enough.", which is a verdict on something this card has not seen.
          // The stored password is never read back, so nothing here can judge it; what can
          // be said, and is the thing the person needs, is that it is still there.
          SettingsFootnote(
            text: "A password is already set. Leave this blank to keep it.",
            symbol: "checkmark.circle.fill"
          )
        } else {
          SettingsFootnote(text: "Strong enough.", symbol: "checkmark.circle.fill")
        }

        if showsPort {
          SettingsDivider()
          SettingsRow(
            title: "Port",
            help: "Clients connect here. Leave it unless something else on this Mac uses it."
          ) {
            // A port is an identifier, not a quantity: no thousands separator.
            TextField("", value: $port, format: .number.grouping(.never))
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 100)
          }
        }

        if let saveError {
          SettingsFootnote(text: saveError, symbol: "xmark.circle", tone: .error)
        }
      }
    }
    .task {
      guard let store = model.settingsStore else { return }
      port = await store.get(Settings.socketPort)
      // The password is deliberately NOT read back into the field: that would put a real
      // secret in a plain `@State` for the rest of the session, and nothing here needs its
      // value. Whether one EXISTS is a different question, and it is the one that decides
      // the gate and the save; `OnboardingView` asks it. See `hasStoredPassword`.
    }
  }
}
