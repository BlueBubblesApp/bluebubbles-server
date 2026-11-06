//  SettingRowState
//  What one row of the generated settings screen holds, and what it shows about itself.
//
//  Whether the control can be touched, whether it holds something not yet written, what it
//  would write on commit, what a read-only row prints, and which footnotes appear under it.
//  `SettingRow` holds ONE of these in `@State` and asks it, rather than a dozen `@State`
//  values and the rules over them as `private var`s, which no test can reach.
//
//  The footnote rule is the one worth having under test. It is not a list of independent
//  notes: there is at most ONE `.locked` note because `SettingsFootnote` is identified by
//  its kind and two would collide, the override beats the parent switch when both apply,
//  and the order is the order they are read in. Three interacting decisions that a reader
//  of the view has to reconstruct from a run of `if`s.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`: a decision that deserves a test cannot live on
//  the view that uses it.

import BBAuth
import BBSettings

/// The row's inputs, and everything it decides from them.
///
/// A value rather than six free functions, because every rule reads the same handful of
/// fields and threading them through separately is how one call site ends up passing a
/// stale `source`.
struct SettingRowState {

  let setting: AnySetting
  /// The stored value, or nil before the first read lands.
  ///
  /// For a SECRET it stays nil until the user asks for it: the row is built from
  /// `secretPresence` instead, and this being nil is what says the value is unread. See
  /// `SettingRow.revealSecret`.
  var value: SettingBox?
  var source: SettingSource = .declaredDefault
  /// What the text field holds right now, which is not what is stored until it commits.
  var draft: String = ""
  var numberDraft: Int = 0
  /// The switch to tell somebody to turn on, or nil when this row is live.
  ///
  /// WHICH switch is `Settings.blockingRequirement`'s decision, not this type's: over a
  /// chain it is the outermost one that is off, because every switch under that one is
  /// greyed out and naming one of those points at a control nobody can click.
  var blockingRequirement: AnySetting?
  /// The validator's reason, when the last write was refused.
  var error: String?
  /// The value a switch or picker is writing, shown over `value` until the write ends; see
  /// `OptimisticWrite`. A text field never reads it: its draft is what it shows.
  var pending: SettingBox?
  /// What is known about a secret that has not been read. `.absent` for every other row,
  /// which never consults it.
  ///
  /// A secret is read ON DEMAND, so for one of those rows `value` is nil until the person
  /// presses the eye, and this is what the row draws itself from until then: enough to say
  /// something is stored, without the Connection tab costing a Keychain access panel per
  /// secure field and without a value nobody asked for sitting in a SwiftUI `@State` string.
  ///
  /// `value == nil` is therefore "not read yet" for a secret, and there is deliberately no
  /// second flag saying the same thing: two fields that can disagree is one more state than
  /// this type has.
  var secretPresence: SecretPresence = .absent

  /// What the secure field knows, for `SecretField`.
  var secretField: SecretFieldState {
    SecretFieldState(presence: secretPresence, isLoaded: value != nil, fallback: "Not set")
  }

  /// The keys whose writes this row reads its own value again on: its own, when it follows
  /// it, and none otherwise. See `followsOwnValue`.
  var followedKeys: [String] { followsOwnValue ? [setting.key] : [] }

  /// The switches this row hangs off, the whole chain; see `Settings.requirementChain`.
  var requirementKeys: [String] { Settings.requirementChain(for: setting).map(\.key) }

  /// Whether this row has to re-read its own value while it is on screen.
  ///
  /// A row is loaded once when it appears. That is right for a row the person edits: it
  /// holds a draft, and `SettingsStore.changes()` reports the writer's own commits as well
  /// as anybody else's, so following one would re-read the store underneath a half-typed
  /// value.
  ///
  /// It is wrong for a row the person CANNOT edit, which is exactly the row whose value
  /// arrives from somewhere else. `server_address` is written by the connection method on
  /// every connect and reconnect, so switching Tailscale for zrok left the old URL on the
  /// Connection page until you navigated away and back — the address being the one thing on
  /// that page you would have gone there to read.
  ///
  /// Read-only is the whole rule, and keeping it here rather than in the view is also what
  /// bounds the cost: two settings are read-only (`server_address` and `update_feed_url`),
  /// so this is two subscriptions and not one per row.
  var followsOwnValue: Bool {
    if case .readOnly = setting.presentation.control { return true }
    return false
  }

  var isCustom: Bool {
    if case .custom = setting.presentation.control { return true }
    return false
  }

  /// Whether the control can be touched at all.
  var isLocked: Bool { source > .persistedStore || blockingRequirement != nil }

  /// Whether the field holds something not yet written.
  ///
  /// Needed because focus loss is NOT dependable on macOS: clicking empty space does not
  /// resign first responder, so a field can sit holding an uncommitted value indefinitely
  /// while looking exactly like a saved one. Rather than guess with a timer (which for the
  /// password would write whatever prefix existed when the user paused) the pending state
  /// is shown and the way to resolve it is named.
  ///
  /// Only for a row the person can actually edit: a value set on the command line is not
  /// "unsaved", it is not theirs to save.
  var hasUnsavedEdit: Bool {
    guard source <= .persistedStore else { return false }
    switch setting.presentation.control {
    // A number with nothing read is not an edit: the field shows the 0 `syncDraft` put
    // there, and nobody typed it. See `draftToCommit`.
    case .number: return value.map { numberDraft != $0.intValue } ?? false
    case .textField, .path, .secureField: return draft != (value?.stringValue ?? "")
    default: return false
    }
  }

  /// Whether the control needs the row's control column, or has a size of its own.
  ///
  /// A switch is the whole of the second case, and the width it does not use comes off the
  /// explanation beside it — which for a setting like the search index is several sentences
  /// wrapping in a strip a third of the card. Every other control here is a field, a picker
  /// or a stepper that fills what it is given.
  var reservesControlColumn: Bool {
    if case .toggle = setting.presentation.control { return false }
    return true
  }

  /// What a commit would write, or nil when the draft is what is already stored.
  ///
  /// The equality check is what makes commit-on-blur quiet: tabbing through a page of
  /// settings must not rewrite every one of them, and a no-op write of the password would
  /// still disconnect clients.
  var draftToCommit: SettingBox? {
    switch setting.presentation.control {
    case .number:
      // Nothing to compare against until the value has been read (still loading, or the
      // read failed), and then the draft is the 0 the field was seeded with, not a number
      // anybody typed. Compared against nil it always differed, so clicking into the field
      // and away wrote 0 over the real setting. A text field has no such case: its unread
      // draft is the empty string, and so is what it compares against.
      guard let value else { return nil }
      return numberDraft != value.intValue ? .int(numberDraft) : nil
    case .textField, .path, .secureField:
      return draft != (value?.stringValue ?? "") ? .string(draft) : nil
    default:
      return nil
    }
  }

  /// Mirrors the stored value into the drafts. The caller skips this while the field has
  /// focus, so a reload triggered by something else does not yank half-typed text out from
  /// under the person typing it.
  mutating func syncDraft() {
    draft = value?.stringValue ?? ""
    numberDraft = value?.intValue ?? 0
  }

  /// The stored value, as the text an edit was typed over. What a kept draft is checked
  /// against before it is put back; see `SettingsModel.takeDraft`.
  ///
  /// The empty string for a secret, which is never read to be compared: a kept edit of the
  /// password is the person's own text, and it comes back whatever the Keychain now holds.
  var draftBase: String {
    if setting.isSecret { return "" }
    if case .number = setting.presentation.control { return String(value?.intValue ?? 0) }
    return value?.stringValue ?? ""
  }

  /// The uncommitted edit, as text to keep while the row is off screen. Nil when there is
  /// none.
  var uncommittedText: String? {
    guard hasUnsavedEdit else { return nil }
    if case .number = setting.presentation.control { return String(numberDraft) }
    return draft
  }

  /// Puts a kept edit back into the field it was typed in.
  mutating func restoreDraft(_ text: String) {
    if case .number = setting.presentation.control {
      if let number = Int(text) { numberDraft = number }
    } else {
      draft = text
    }
  }

  var displayValue: String {
    guard let value else { return "-" }
    // A secret is never rendered, even in the read-only fallback.
    if setting.isSecret { return "••••••••" }
    switch value {
    case .bool(let flag): return flag ? "On" : "Off"
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    case .string(let text): return text
    }
  }

  /// The strength note for the server password, and only for it.
  ///
  /// Keyed on the setting's own key rather than on `.secureField`, because the ngrok and
  /// zrok tokens are secure fields too and are not passwords anyone chose: scoring them
  /// would be noise attached to a value the user cannot make stronger.
  var passwordAdvice: String? {
    guard setting.key == Settings.password.key else { return nil }
    if let value { return PasswordPolicy().assess(value.stringValue ?? "").advice }
    // Nothing read, so there is nothing to score, and scoring the empty stand-in would put
    // "No server password is set. Anyone who can reach this server can read your messages."
    // under a row whose password is set, readable and strong.
    //
    // `.absent` is the exception because it is the one verdict presence reaches WITHOUT
    // reading, and it is the one piece of advice that is still true unseen — it is also the
    // only one here that is a security warning rather than a suggestion, so suppressing it
    // to be safe would suppress the wrong one.
    guard secretPresence == .absent else { return nil }
    return PasswordPolicy().assess("").advice
  }

  /// The line that tells someone a secret is there and how to see it; the wording is
  /// `SecretFieldPolicy.note`'s, shared with the service form.
  var secretFootnote: SettingsFootnote? {
    guard setting.isSecret else { return nil }
    return SecretFieldPolicy.note(for: secretPresence, isLoaded: value != nil, revealable: true)
  }

  /// The lines that appear under a row when there is something to say.
  var footnotes: [SettingsFootnote] {
    var notes: [SettingsFootnote] = []
    if hasUnsavedEdit {
      notes.append(
        SettingsFootnote(
          text: "Not saved yet; press Return, or click another field.",
          kind: .unsaved,
          // Neutral, not warning. This appears on the first keystroke of a perfectly normal
          // edit; colouring it as a problem would make ordinary typing look like a fault.
          symbol: "pencil.circle", tone: .informational
        ))
    }
    // ONE `.locked` note, because `SettingsFootnote` is identified by its kind and two
    // would collide. The override wins when both are true: it is the reason the row cannot
    // be edited even if the parent switch were on.
    if source > .persistedStore {
      notes.append(
        SettingsFootnote(
          text: source == .commandLine
            ? "Set on the command line; not editable here."
            : "Set in the configuration file; not editable here.",
          kind: .locked,
          symbol: "lock"
        ))
    } else if let blocking = blockingRequirement {
      notes.append(
        SettingsFootnote(
          // Names the switch rather than the feature, because the switch is what the
          // person has to go and find, and it is a row on this same page.
          text: "Turn on \(blocking.presentation.label) to use this.",
          kind: .locked,
          symbol: "lock"
        ))
    }
    if let error {
      notes.append(
        SettingsFootnote(text: error, kind: .error, symbol: "xmark.circle", tone: .problem))
    }
    if let secretFootnote {
      notes.append(secretFootnote)
    }
    // Advisory, never a gate. A password migrated from the Electron server is deliberately
    // accepted however weak it is (rejecting it at upgrade time would lock the install out
    // of its own clients) so the only thing left is to say so where it can be fixed.
    if let advice = passwordAdvice {
      notes.append(
        SettingsFootnote(
          text: advice, kind: .advice, symbol: "exclamationmark.triangle", tone: .attention
        ))
    }
    return notes
  }
}

extension SettingBox {
  /// A stored value as a switch position, for a `Toggle` over `Binding.optimistic`. A value
  /// that is not a Bool reads as off, which cannot happen for a `.toggle` row.
  var switchPosition: Bool {
    get { boolValue ?? false }
    set { self = .bool(newValue) }
  }

  /// A stored value as a picker's selection.
  var choice: String {
    get { stringValue ?? "" }
    set { self = .string(newValue) }
  }
}
