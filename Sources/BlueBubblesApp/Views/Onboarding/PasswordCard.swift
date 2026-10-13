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
//  **An existing password is kept, not re-asked.** The field stays empty either way (it is
//  never read back), so "there is already one" has to be stated, or the step is indistinguishable
//  from a fresh install: a person who had just adopted an Electron install was shown a blank
//  Password field, concluded the migration had lost it, and would have replaced a working
//  password with a new one and disconnected every client they had already paired.

import BBSettings
import SwiftUI

struct PasswordCard: View {

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

  @FocusState private var focus: String?

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 14) {
        SettingsRow(
          title: "Password",
          help: hasStoredPassword
            ? "This server already has one, and it is kept unless you type a new one here."
            : "Choose something long. Generate one if you would rather not think of one."
        ) {
          // `SecretField`, the control the settings row uses, for the reason it has a
          // reveal: a generated password nobody can read is one nobody can type into their
          // phone, and the plain `SecureField` this was offered no way to see it. Generate
          // shows what it made.
          //
          // `.absent` whatever is stored: the stored password is never read back here (see
          // the `.task`), so the eye only ever shows what is in the field, which is the
          // person's own text or the one just generated.
          SecretField(
            presence: SecretFieldState(
              presence: .absent, isLoaded: false,
              // The prompt carries the state, because the field cannot: an empty field
              // means either "nothing set" or "set, and not shown".
              fallback: hasStoredPassword ? "Unchanged" : ""),
            text: $password,
            focus: $focus,
            focusKey: "password",
            onSubmit: {},
            reveal: { !password.isEmpty },
            // The person's own text, and nothing was read to be forgotten.
            forget: {},
            generator: .onboardingPassword { PasswordPolicy.generate() }
          )
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
            tone: rejection.isEmpty ? .informational : .problem
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
          ErrorLine(saveError)
        }
      }
    }
    // Reads nothing. The port is seeded once by `OnboardingView`, which outlives this card:
    // a read here ran on every appearance, so going Back past this step and returning put
    // the stored port over the one the person had typed. The password is never read back
    // at all; whether one EXISTS is `OnboardingView.hasStoredPassword`.
  }
}
