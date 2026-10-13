//  SecretField
//  A secure field whose eye READS the secret, and whose hiding forgets it.
//
//  One control, where there were two that had already drifted: the settings row's had a
//  Generate button and a saved tick, the service form's had neither, and their disabled rules
//  and prompts were each spelled out by hand. Both now build this.
//
//  The rule it keeps is `Sources/BlueBubblesApp/CLAUDE.md`'s: a secret is read when somebody
//  asks for it, never when the screen appears. So the field rests on bullets it did NOT read
//  (`SecretFieldPolicy.prompt` says which of stored, absent or unreadable it is), the eye is a
//  LOAD rather than a mask toggle (`reveal`, supplied by the caller, who knows which store key
//  to read and how to say a refusal), and hiding hands the value back to the caller to forget
//  (`forget`), so the plaintext does not sit in view state for the rest of the session. A
//  mask toggle over a value already read is what this replaced: on a build whose Keychain read
//  came back empty, revealing an empty field revealed nothing and there was no other way to
//  ask for the value. The footnote saying the value is unread or unreadable is the caller's,
//  because a settings row and a service form word it differently.

import SwiftUI

/// The optional Generate action: a button above the field that replaces the secret with a
/// fresh one, after asking.
struct SecretGenerator {
  let title: String
  let help: String
  let confirmationTitle: String
  let confirmationAction: String
  let confirmationMessage: String
  /// The new secret.
  let make: () -> String
  /// Called once the new secret is in the field, revealed: the caller commits it.
  let onGenerated: () -> Void
}

struct SecretField<Accessory: View>: View {

  /// What is known about the stored value without reading it, and whether it has been read.
  let presence: SecretFieldState
  @Binding var text: String
  let focus: FocusState<String?>.Binding
  /// The value `focus` holds while this field is being edited.
  let focusKey: String
  let onSubmit: () -> Void
  /// Reads the stored value into `text`. Answers whether there is now something to show:
  /// false when the read was refused, which the caller reports in its own footnote.
  let reveal: () async -> Bool
  /// Called on hiding. The caller drops the value it read, unless it is the person's own
  /// uncommitted text.
  let forget: () -> Void
  var generator: SecretGenerator?
  private let accessory: Accessory

  @State private var isRevealed = false
  /// While the Keychain is being asked, which on the legacy store can be a modal panel.
  @State private var isRevealing = false
  @State private var isConfirmingGenerate = false

  init(
    presence: SecretFieldState,
    text: Binding<String>,
    focus: FocusState<String?>.Binding,
    focusKey: String,
    onSubmit: @escaping () -> Void,
    reveal: @escaping () async -> Bool,
    forget: @escaping () -> Void,
    generator: SecretGenerator? = nil,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.presence = presence
    self._text = text
    self.focus = focus
    self.focusKey = focusKey
    self.onSubmit = onSubmit
    self.reveal = reveal
    self.forget = forget
    self.generator = generator
    self.accessory = accessory()
  }

  var body: some View {
    if let generator {
      // Generate sits ABOVE the field rather than beside it. A settings row's control column
      // is 320 points, and a text field, a reveal button, a word-width button and the saved
      // tick do not share that without the field itself becoming unusable, for the one value
      // in the app most likely to be read character by character.
      VStack(alignment: .trailing, spacing: 6) {
        generateButton(generator)
        field
      }
    } else {
      field
    }
  }

  private var field: some View {
    HStack(spacing: 6) {
      // On macOS a field's title IS its placeholder, so the prompt carries the difference
      // between "stored, not read" and "nothing here", which an unread field cannot show any
      // other way.
      let prompt = SecretFieldPolicy.prompt(
        for: presence.presence, isLoaded: presence.isLoaded, fallback: presence.fallback)
      SwiftUI.Group {
        if isRevealed {
          TextField(prompt, text: $text)
        } else {
          SecureField(prompt, text: $text)
        }
      }
      .textFieldStyle(.roundedBorder)
      .controlSize(.large)
      // The same commit wiring every other field gets. A draft binding without it leaves
      // the secret unable to save at all, silently.
      .focused(focus, equals: focusKey)
      .onSubmit(onSubmit)

      Button {
        if isRevealed {
          isRevealed = false
          forget()
        } else {
          Task {
            isRevealing = true
            let shown = await reveal()
            isRevealing = false
            if shown { isRevealed = true }
          }
        }
      } label: {
        if isRevealing {
          // The legacy Keychain can put a system panel in front of this, so the button has
          // to show that the click landed rather than looking inert behind it.
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
      }
      .buttonStyle(.borderless)
      .disabled(
        !SecretFieldPolicy.canReveal(
          presence: presence.presence, text: text, isRevealing: isRevealing)
      )
      .help(
        isRevealed ? "Hide this again and forget it" : "Read this from the Keychain and show it"
      )
      .accessibilityLabel(isRevealed ? "Hide" : "Reveal")

      accessory
    }
  }

  /// Still a word, not an icon: `PasswordPolicy.Rejection.tooPredictable` tells the reader to
  /// "use Generate", and that sentence is shown beside this very field when a password is
  /// refused. An icon would leave the advice naming a control that is not there.
  private func generateButton(_ generator: SecretGenerator) -> some View {
    Button(generator.title) { isConfirmingGenerate = true }
      .help(generator.help)
      .controlSize(.small)
      // CONFIRMED, because replacing a credential cannot be undone and every other
      // destructive control in the app asks first, which teaches a person that a button here
      // is safe to press and find out.
      .confirmationDialog(
        generator.confirmationTitle,
        isPresented: $isConfirmingGenerate,
        titleVisibility: .visible
      ) {
        Button(generator.confirmationAction, role: .destructive) {
          text = generator.make()
          // REVEALED, because a secret you cannot read is one you cannot put into a client.
          // Generating while masked produces a value the user then has to reset in order to
          // find out what it is.
          isRevealed = true
          // The dialog was the decision, so the caller commits now, and its saved tick then
          // confirms the new value is live before the user copies it.
          generator.onGenerated()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(generator.confirmationMessage)
      }
  }
}

extension SecretField where Accessory == EmptyView {
  init(
    presence: SecretFieldState,
    text: Binding<String>,
    focus: FocusState<String?>.Binding,
    focusKey: String,
    onSubmit: @escaping () -> Void,
    reveal: @escaping () async -> Bool,
    forget: @escaping () -> Void,
    generator: SecretGenerator? = nil
  ) {
    self.init(
      presence: presence, text: text, focus: focus, focusKey: focusKey, onSubmit: onSubmit,
      reveal: reveal, forget: forget, generator: generator
    ) { EmptyView() }
  }
}

extension SecretGenerator {
  /// The server password's Generate: a strong random password, after a warning that states
  /// the consequence rather than implying it. Even a no-op write of the password disconnects
  /// every connected client, so there is no version of this that is quietly recoverable.
  static func serverPassword(make: @escaping () -> String, onGenerated: @escaping () -> Void)
    -> SecretGenerator
  {
    SecretGenerator(
      title: "Generate",
      help: "Replace this with a strong random password",
      confirmationTitle: "Replace the server password?",
      confirmationAction: "Replace Password",
      confirmationMessage:
        "Every connected client will stop working until it is given the new password. The "
        + "current one cannot be recovered afterwards.",
      make: make,
      onGenerated: onGenerated)
  }
}

extension SecretGenerator {
  /// Setup's Generate: the same strong password, into a field that saves nothing until the
  /// step continues. So the question is whether to replace what was TYPED, and the only
  /// thing to warn about is a password the server already has.
  static func onboardingPassword(make: @escaping () -> String) -> SecretGenerator {
    SecretGenerator(
      title: "Generate",
      help: "Create a strong random password",
      confirmationTitle: "Generate a password?",
      confirmationAction: "Generate",
      confirmationMessage:
        "A strong random password goes in the field, shown so you can copy it into your "
        + "clients. Nothing is saved until you continue, and a password this server already "
        + "has is replaced only then.",
      make: make,
      onGenerated: {})
  }
}
