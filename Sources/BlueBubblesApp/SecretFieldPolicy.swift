//  SecretFieldPolicy
//  What a secret field says about a value it has not read, and when its eye can be pressed.
//
//  A secret is read when somebody asks for it, never when the screen appears (see
//  `Sources/BlueBubblesApp/CLAUDE.md`), so a secure field's resting state is a value it does
//  NOT hold. Bullets it did not read look exactly like an empty field, so the prompt is the
//  only thing on the field itself telling "stored, not read" from "nothing here" from "the
//  Keychain would not answer". The settings row and the service form drew this separately and
//  had already drifted; `SecretField` draws it once, from these rules, off the view so a test
//  can state them.

import BBSettings

/// What a secret field knows about the value behind it, as its caller last read it.
struct SecretFieldState: Equatable {
  /// What is stored, known without reading it.
  var presence: SecretPresence
  /// Whether the field's text IS the stored value, read on request.
  var isLoaded: Bool
  /// The field's own hint; see `SecretFieldPolicy.prompt`.
  var fallback: String
}

enum SecretFieldPolicy {

  /// The field's placeholder.
  ///
  /// - Parameters:
  ///   - presence: What is known without reading.
  ///   - isLoaded: Whether the field holds the stored value, in which case the prompt only
  ///     shows when that value is empty and there is nothing to say about it but `fallback`.
  ///   - fallback: The field's own hint, for nothing stored or a loaded empty value: "Not
  ///     set" on a settings row, the manifest's placeholder on a service form, which is the
  ///     field-specific hint and says more.
  static func prompt(for presence: SecretPresence, isLoaded: Bool, fallback: String) -> String {
    guard !isLoaded else { return fallback }
    switch presence {
    case .stored: return "••••••••"
    case .unreadable: return "Keychain unavailable"
    case .absent: return fallback
    }
  }

  /// Whether the eye does anything.
  ///
  /// Not while a read is in flight, which on the legacy Keychain can be a system panel. And
  /// not with nothing stored AND nothing typed. Live while the person is typing, because
  /// checking what you are entering is half of why the eye is there.
  static func canReveal(presence: SecretPresence, text: String, isRevealing: Bool) -> Bool {
    !isRevealing && !(presence == .absent && text.isEmpty)
  }

  /// The line under a secret field that has not been read: that something is stored and how
  /// to see it, or that the Keychain would not answer. Nil when there is nothing to say.
  ///
  /// Discoverability is the whole job. A secure field holding a value nobody has loaded looks
  /// exactly like an empty one, and the bullets in its prompt are a hint, not a sentence.
  /// Without this the honest reading of the field is "my token is gone". One wording for the
  /// settings row and the service form, which had each written their own.
  ///
  /// - Parameters:
  ///   - presence: What is known without reading.
  ///   - isLoaded: Whether the field holds the stored value (or the person's replacement for
  ///     it), in which case there is nothing unread to explain.
  ///   - revealable: Whether the field has an eye. A multi-line secret (PEM text) does not,
  ///     so its line says what typing does instead.
  static func note(
    for presence: SecretPresence, isLoaded: Bool, revealable: Bool
  ) -> SettingsFootnote? {
    guard !isLoaded else { return nil }
    switch presence {
    case .stored(.persistedStore):
      return SettingsFootnote(
        text: revealable
          ? "Stored in the Keychain. Use the eye to read it."
          : "Stored in the Keychain. Text entered here replaces it.",
        kind: .secret, symbol: "key", tone: .informational)
    // An override says what is in effect without a Keychain read, and the `.locked` note
    // already explains why the field cannot be edited. A second line saying where to click
    // on a control that is greyed out would be worse than silence.
    case .stored: return nil
    case .absent: return nil
    case .unreadable:
      return SettingsFootnote(
        text: "The Keychain would not answer. The value may still be there; do not "
          + "replace it until the Keychain is reachable.",
        kind: .secret, symbol: "exclamationmark.triangle", tone: .problem)
    }
  }
}
