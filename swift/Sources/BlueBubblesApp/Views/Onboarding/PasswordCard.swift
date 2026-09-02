//  PasswordCard
//  The top of the connection step: the password, and the port a client will use.
//
//  Has no Save button. Its state belongs to `OnboardingView`, which writes it when Continue
//  is pressed — see `saveCredentials`. A card that saved for itself could be walked straight
//  past, and was.
//
//  Not the generated `SettingRow`, deliberately: that row commits on focus loss, and the
//  Continue button both blurs the field and reads the result, which is a race. The gate on
//  this step is the one place in the app that must be certain a password exists.

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
  /// Whether the port row is shown. Off for a setup nothing connects to.
  var showsPort = true

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 14) {
        SettingsRow(
          title: "Password",
          help: "Choose something long. Generate one if you would rather not think of one."
        ) {
          HStack(spacing: 6) {
            SecureField("", text: $password)
              .textFieldStyle(.roundedBorder)
            // Offered rather than imposed. The policy rejects weak passwords, and the
            // fastest way past a rejection is one that passes by construction.
            Button("Generate") { password = PasswordPolicy.generate() }
              .help("Create a strong random password")
          }
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

        // Required, and said so before the Continue button is discovered to be dead. An
        // empty password is not "no authentication" — the server refuses every request
        // with a misconfiguration error, which reads like a bug rather than a missing step.
        if let rejection {
          SettingsFootnote(
            text: rejection.isEmpty
              ? "A password is required. Without one the server rejects every client."
              : rejection,
            symbol: "exclamationmark.triangle.fill",
            tone: rejection.isEmpty ? .neutral : .error
          )
        } else {
          SettingsFootnote(text: "Strong enough.", symbol: "checkmark.circle.fill")
        }

        if let saveError {
          SettingsFootnote(text: saveError, symbol: "xmark.circle", tone: .error)
        }
      }
    }
    .task {
      guard let store = model.settingsStore else { return }
      port = await store.get(Settings.socketPort)
      // A password already on the store means this is a re-run of onboarding, not a fresh
      // install. Reading it back would put a real secret in a plain @State for the rest of
      // the session, so the field stays empty and the user re-enters or regenerates one.
    }
  }
}
