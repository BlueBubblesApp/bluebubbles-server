//  SettingRowStateTests
//  What one row of the generated settings screen decides about itself.
//
//  These were `private var`s on `SettingRow`, in a 946-line file with no test on any line of
//  it. The footnote rule in particular is not a list of independent notes: there is at most
//  ONE `.locked` note because `SettingsFootnote` is identified by its kind and two would
//  collide, the override beats the parent switch when both apply, and the order is the order
//  they are read in.
//
//  Real settings from the registry rather than invented ones: `AnySetting` is built by
//  BBSettings and the row's rules key on real properties (`isSecret`, the control kind, the
//  password's own key), so a stand-in would be asserting against a fiction.

import BBSettings
import Testing

@testable import BlueBubblesApp

/// `@MainActor` because `SettingsFootnote` is a `View`, so its stored properties are
/// main-actor isolated and a key path to one cannot be formed anywhere else. The rules
/// themselves are pure; only the note VALUES carry the isolation.
@Suite("Setting row state")
@MainActor
struct SettingRowStateTests {

  private func setting(_ key: String) throws -> AnySetting {
    try #require(Settings.setting(forKey: key), "\(key) is not in the registry")
  }

  private var password: AnySetting { get throws { try setting(Settings.password.key) } }

  /// A number-controlled row, for the numeric half of the unsaved-edit rule.
  private var port: AnySetting { get throws { try setting(Settings.socketPort.key) } }

  // MARK: - Following a value written elsewhere

  /// REGRESSION. The Connection page showed a stale server URL.
  ///
  /// A row is loaded once when it appears, and `server_address` is written by the connection
  /// method on every connect and reconnect. Switching Tailscale for zrok therefore left the
  /// old URL on screen until you navigated away and came back, which on that page is the one
  /// value you went there to read.
  @Test("A read-only row follows its own value, because something else writes it")
  func readOnlyRowsFollow() throws {
    let address = SettingRowState(setting: try setting(Settings.serverAddress.key))
    #expect(
      address.followsOwnValue,
      "the published address is written by the tunnel, so the row cannot read it once")
    #expect(SettingRowState(setting: try setting(Settings.updateFeedURL.key)).followsOwnValue)
  }

  /// The other half, and the reason the rule is not "every row follows": an editable row
  /// holds a draft, and `changes()` reports the writer's own commits too, so re-reading
  /// under a half-typed value would eat the edit.
  @Test("An editable row does not follow, so a draft is never read out from under")
  func editableRowsDoNotFollow() throws {
    #expect(!SettingRowState(setting: try password).followsOwnValue)
    #expect(!SettingRowState(setting: try port).followsOwnValue)
    #expect(
      !SettingRowState(setting: try setting(Settings.connectionMethod.key)).followsOwnValue,
      "the picker that CAUSES the address to change is itself edited here")
  }

  /// A floor on the cost. Each following row re-renders on every write to its key, and
  /// `SettingRow.ownVersion` is explicit that following every row is the thing to avoid.
  @Test("Following is confined to the rows that cannot be edited")
  func followingIsRare() {
    let following = Settings.renderable.filter {
      SettingRowState(setting: $0).followsOwnValue
    }
    #expect(
      following.count <= 4,
      "following rows: \(following.map(\.key)) — each one is a settings subscription")
  }

  // MARK: - Locking

  @Test("A row is locked by an override or by a parent switch, and free otherwise")
  func locking() throws {
    var state = SettingRowState(setting: try password, value: .string("x"))
    #expect(!state.isLocked)

    state.source = .commandLine
    #expect(state.isLocked)

    state.source = .persistedStore
    state.blockingRequirement = try port
    #expect(state.isLocked)
  }

  /// `persistedStore` and `declaredDefault` are both editable: the comparison is `>`, and
  /// getting it wrong the other way locks every row that has never been written.
  @Test("A never-written row is editable, not locked")
  func defaultIsEditable() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.source = .declaredDefault
    #expect(!state.isLocked)
  }

  // MARK: - Unsaved edits

  @Test("A text draft differing from the stored value is unsaved")
  func unsavedText() throws {
    var state = SettingRowState(setting: try password, value: .string("stored"))
    state.draft = "stored"
    #expect(!state.hasUnsavedEdit)
    state.draft = "typing"
    #expect(state.hasUnsavedEdit)
  }

  @Test("A number draft differing from the stored value is unsaved")
  func unsavedNumber() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.numberDraft = 1234
    #expect(!state.hasUnsavedEdit)
    state.numberDraft = 1235
    #expect(state.hasUnsavedEdit)
  }

  /// Before the read lands, or when it failed, the field holds the 0 `syncDraft` seeded it
  /// with. Compared against nil, that differed, so clicking into the field and away wrote 0
  /// over the real port.
  @Test("A number field with nothing read commits nothing")
  func unreadNumberCommitsNothing() throws {
    var state = SettingRowState(setting: try port, value: nil)
    state.syncDraft()
    #expect(state.numberDraft == 0)
    #expect(state.draftToCommit == nil)
    #expect(!state.hasUnsavedEdit)
    // Once the value is read, the same field commits a real edit.
    state.value = .int(1234)
    state.syncDraft()
    state.numberDraft = 1235
    #expect(state.draftToCommit == .int(1235))
  }

  /// A value set on the command line is not "unsaved" — it is not the person's to save, and
  /// marking it so would put a permanent pencil beside a row they cannot commit.
  @Test("An overridden row is never unsaved, however different the draft")
  func overriddenIsNeverUnsaved() throws {
    var state = SettingRowState(setting: try password, value: .string("stored"))
    state.draft = "totally different"
    state.source = .commandLine
    #expect(!state.hasUnsavedEdit)
    state.source = .configFile
    #expect(!state.hasUnsavedEdit)
  }

  /// An unwritten value reads as empty, so an empty field over it is not an edit. Otherwise
  /// every untouched text row on a fresh install opens showing "Not saved yet".
  @Test("An empty draft over an absent value is not an edit")
  func emptyOverNothing() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.draft = ""
    #expect(!state.hasUnsavedEdit)
  }

  // MARK: - The read-only value

  @Test("A secret is never printed, even in the read-only fallback")
  func secretsAreNeverPrinted() throws {
    let state = SettingRowState(setting: try password, value: .string("hunter2"))
    #expect(try password.isSecret, "the password must be a secret for this to mean anything")
    #expect(state.displayValue == "••••••••")
    #expect(!state.displayValue.contains("hunter2"))
  }

  @Test("An unread value prints as a dash, not as an empty string")
  func absentValuePrintsADash() throws {
    #expect(SettingRowState(setting: try password, value: nil).displayValue == "-")
  }

  @Test("A boolean prints as On or Off, and a number as itself")
  func valueShapes() throws {
    let port = try port
    #expect(SettingRowState(setting: port, value: .bool(true)).displayValue == "On")
    #expect(SettingRowState(setting: port, value: .bool(false)).displayValue == "Off")
    #expect(SettingRowState(setting: port, value: .int(1234)).displayValue == "1234")
    #expect(SettingRowState(setting: port, value: .string("text")).displayValue == "text")
  }

  // MARK: - How much of the row the control claims

  /// The search index's help is five sentences, and in a 320-point strip beside a switch
  /// that uses fifty of them it wrapped to a dozen lines.
  @Test("A switch does not reserve the control column; every other control does")
  func switchesDoNotReserveTheControlColumn() throws {
    let toggle = try setting(Settings.searchIndexEnabled.key)
    #expect(!SettingRowState(setting: toggle).reservesControlColumn)
    #expect(SettingRowState(setting: try port).reservesControlColumn)
    #expect(SettingRowState(setting: try password).reservesControlColumn)
  }

  // MARK: - Password advice

  /// Keyed on the password's own key, not on the control being a secure field: the ngrok and
  /// zrok tokens are secure fields too and are not passwords anyone chose, so scoring them
  /// would attach noise to a value the user cannot make stronger.
  @Test("Only the server password is assessed for strength")
  func adviceIsOnlyForThePassword() throws {
    #expect(SettingRowState(setting: try password, value: .string("a")).passwordAdvice != nil)
    #expect(SettingRowState(setting: try port, value: .string("a")).passwordAdvice == nil)
  }

  @Test("A strong password draws no advice")
  func strongPasswordIsQuiet() throws {
    let strong = SettingRowState(
      setting: try password, value: .string("bR8!kx2Qw#7zLp4v"))
    #expect(strong.passwordAdvice == nil)
  }

  // MARK: - A secret nobody has read

  /// The bug these exist for: the Connection page showed an empty password field with
  /// nothing under it, and the only control offering to do anything about it was Generate,
  /// which is irreversible. A row that has not read its secret has to SAY that, and it has
  /// to be able to say it without reading — the read is what the eye is for.

  @Test("An unread secret that is stored says so, and says how to see it")
  func unreadSecretIsAnnounced() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .stored(.persistedStore)

    let note = try #require(state.secretFootnote)
    #expect(note.kind == .secret)
    #expect(note.text.contains("Keychain"))
    #expect(state.footnotes.contains { $0.kind == .secret })
  }

  /// The regression in the other direction. Before the row knew the difference, an unread
  /// password scored the empty stand-in and put "No server password is set. Anyone who can
  /// reach this server can read your messages." under a password that was set, readable and
  /// strong.
  @Test("An unread password is not scored as if it were missing")
  func unreadPasswordIsNotScored() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .stored(.persistedStore)
    #expect(state.passwordAdvice == nil)
  }

  /// `.absent` is the one verdict presence reaches without reading, and the one warning
  /// still worth making unseen: there is genuinely no password.
  @Test("A password that is genuinely absent is still warned about")
  func absentPasswordIsWarned() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .absent
    #expect(state.passwordAdvice != nil)
    // And no "stored in the Keychain" note, which would contradict it.
    #expect(state.secretFootnote == nil)
  }

  /// A Keychain that refuses is not a Keychain with nothing in it. This note exists to stop
  /// the user replacing a value that was never lost.
  @Test("An unreadable secret warns against replacing it")
  func unreadableSecretWarns() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .unreadable

    let note = try #require(state.secretFootnote)
    #expect(note.tone == .problem)
    #expect(note.text.contains("may still be there"))
    // Not scored either: nothing is known about the value.
    #expect(state.passwordAdvice == nil)
  }

  /// Once the value is in hand the row goes back to behaving like any other: the note is
  /// about an unread secret, and it has been read.
  @Test("A revealed secret drops the note and is scored normally")
  func revealedSecretIsOrdinary() throws {
    var state = SettingRowState(setting: try password, value: .string("bR8!kx2Qw#7zLp4v"))
    state.secretPresence = .stored(.persistedStore)
    #expect(state.secretFootnote == nil)
    #expect(state.passwordAdvice == nil)
  }

  /// An override already has a `.locked` note saying the row cannot be edited here. A
  /// second line telling the person to click an eye on a greyed-out field would be worse
  /// than silence.
  @Test("An overridden secret gets the locked note and no reveal note")
  func overriddenSecretIsQuiet() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.source = .commandLine
    state.secretPresence = .stored(.commandLine)

    #expect(state.secretFootnote == nil)
    #expect(state.footnotes.contains { $0.kind == .locked })
  }

  /// The kinds are the identity of a footnote, so two notes a row can show AT THE SAME TIME
  /// must not share one. A rejected write and an unread secret is that pair: the row has to
  /// say both why the save failed and that the bullets behind it are real.
  @Test("A rejected write and an unread secret are two separate notes")
  func errorAndSecretNoteCoexist() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .stored(.persistedStore)
    state.error = "Too short; use at least 8 characters"

    let kinds = state.footnotes.map(\.kind)
    #expect(kinds.contains(.error))
    #expect(kinds.contains(.secret))
    #expect(Set(kinds).count == kinds.count, "a row must not show two notes of one kind")
  }

  /// Typing into a field whose secret was never read is still an unsaved edit: the
  /// comparison is against what the row HAS, and it has nothing.
  @Test("Typing over an unread secret is an unsaved edit; leaving it alone is not")
  func unreadSecretEditing() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .stored(.persistedStore)
    #expect(!state.hasUnsavedEdit)

    state.draft = "a-new-password"
    #expect(state.hasUnsavedEdit)
  }

  // MARK: - Footnotes

  @Test("A quiet row has no notes under it")
  func noNotes() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.numberDraft = 1234
    #expect(state.footnotes.isEmpty)
  }

  /// **At most one `.locked` note.** `SettingsFootnote` is identified by its kind, so two
  /// would collide: SwiftUI reports a duplicate id and renders one of them unpredictably.
  @Test("An override and a blocking switch together still give exactly one locked note")
  func oneLockedNote() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.source = .commandLine
    state.blockingRequirement = try password
    let locked = state.footnotes.filter { $0.kind == .locked }
    #expect(locked.count == 1)
    // The OVERRIDE wins: it is the reason the row cannot be edited even if the parent
    // switch were on.
    #expect(locked.first?.text == "Set on the command line; not editable here.")
  }

  @Test("The override note names which override it was")
  func overrideNoteNamesTheSource() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.source = .configFile
    #expect(
      state.footnotes.first { $0.kind == .locked }?.text
        == "Set in the configuration file; not editable here.")
  }

  @Test("A blocking switch is named by its label, so the person knows what to go and find")
  func blockingNoteNamesTheSwitch() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    let parent = try password
    state.blockingRequirement = parent
    #expect(
      state.footnotes.first { $0.kind == .locked }?.text
        == "Turn on \(parent.presentation.label) to use this.")
  }

  /// The unsaved note is NEUTRAL, not a warning: it appears on the first keystroke of a
  /// perfectly ordinary edit, and colouring it as a problem makes typing look like a fault.
  @Test("The unsaved note is neutral in tone")
  func unsavedNoteIsNeutral() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.numberDraft = 9999
    let note = try #require(state.footnotes.first { $0.kind == .unsaved })
    #expect(note.tone == .informational)
  }

  @Test("A refused write shows the validator's own reason, as an error")
  func errorNote() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.error = "port must be between 1 and 65535"
    let note = try #require(state.footnotes.first { $0.kind == .error })
    #expect(note.text == "port must be between 1 and 65535")
    #expect(note.tone == .problem)
  }

  /// Advisory, never a gate: a password migrated from the Electron server is deliberately
  /// accepted however weak it is, so the only thing left is to say so where it can be fixed.
  @Test("Weak-password advice is a warning, not an error, and never blocks")
  func adviceIsAdvisory() throws {
    let state = SettingRowState(setting: try password, value: .string("a"))
    let note = try #require(state.footnotes.first { $0.kind == .advice })
    #expect(note.tone == .attention)
    #expect(!state.isLocked)
  }

  /// Every note in a row must have a distinct kind, because the kind IS the identity a
  /// `ForEach` keys on. Asserted with everything turned on at once.
  @Test("Notes are unique by kind even when everything applies at once")
  func kindsAreUnique() throws {
    var state = SettingRowState(setting: try password, value: .string("a"))
    state.draft = "b"
    state.source = .commandLine
    state.blockingRequirement = try port
    state.error = "refused"
    let kinds = state.footnotes.map(\.kind)
    #expect(Set(kinds).count == kinds.count, "two notes share a kind: \(kinds)")
  }

  // MARK: - Committing

  private var origins: AnySetting { get throws { try setting(Settings.corsAllowedOrigin.key) } }

  /// Commit-on-blur is quiet because of this: tabbing through a page must not rewrite every
  /// field, and a no-op write of the password still disconnects every client.
  @Test("A draft that is what is stored commits nothing")
  func unchangedDraftCommitsNothing() throws {
    var state = SettingRowState(setting: try origins, value: .string("*"))
    state.draft = "*"
    #expect(state.draftToCommit == nil)
    state.draft = "https://app.example.com"
    #expect(state.draftToCommit == .string("https://app.example.com"))
  }

  @Test("A number commits as a number")
  func numberCommitsAsNumber() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.numberDraft = 1234
    #expect(state.draftToCommit == nil)
    state.numberDraft = 4321
    #expect(state.draftToCommit == .int(4321))
  }

  /// An unread secret holds nothing, and nothing is not an edit: blurring an untouched
  /// password field must never write the empty string over the stored password.
  @Test("An untouched, unread secret commits nothing")
  func unreadSecretCommitsNothing() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .stored(.persistedStore)
    #expect(state.draftToCommit == nil)
    state.draft = "typed over it"
    #expect(state.draftToCommit == .string("typed over it"))
  }

  /// Switches and pickers commit on the click; they have no draft to commit later.
  @Test("A switch has no draft to commit")
  func switchHasNoDraft() throws {
    let state = SettingRowState(
      setting: try setting(Settings.enablePrivateAPI.key), value: .bool(true))
    #expect(state.draftToCommit == nil)
    #expect(state.uncommittedText == nil)
  }

  @Test("Syncing puts the stored value back into both drafts")
  func syncDraft() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.numberDraft = 9
    state.syncDraft()
    #expect(state.numberDraft == 1234)
    #expect(!state.hasUnsavedEdit)
  }

  // MARK: - Keeping an edit across a teardown

  @Test("An uncommitted edit is kept as text, over the value it was typed over")
  func uncommittedEditIsKept() throws {
    var state = SettingRowState(setting: try origins, value: .string("*"))
    state.draft = "*"
    #expect(state.uncommittedText == nil, "nothing typed, nothing to keep")
    state.draft = "https://app.example.com"
    #expect(state.uncommittedText == "https://app.example.com")
    #expect(state.draftBase == "*")
  }

  @Test("A kept number comes back as a number")
  func keptNumberRoundTrips() throws {
    var state = SettingRowState(setting: try port, value: .int(1234))
    state.numberDraft = 4321
    let kept = try #require(state.uncommittedText)
    #expect(state.draftBase == "1234")

    var fresh = SettingRowState(setting: try port, value: .int(1234))
    fresh.syncDraft()
    fresh.restoreDraft(kept)
    #expect(fresh.numberDraft == 4321)
    #expect(fresh.hasUnsavedEdit, "a restored edit must still say it is not saved")
  }

  /// A secret is never read to be compared, so its base cannot be its value: an edit kept
  /// over a revealed password would otherwise be dropped when the row comes back unread.
  @Test("A secret's edit is kept over nothing, so it survives the row coming back unread")
  func secretBaseIsEmpty() throws {
    let revealed = SettingRowState(setting: try password, value: .string("stored"))
    let unread = SettingRowState(setting: try password, value: nil)
    #expect(revealed.draftBase == "")
    #expect(unread.draftBase == "")
  }

  // MARK: - Following, and the secret field

  @Test("Only a following row names its own key; a dependent row names its whole chain")
  func followedKeys() throws {
    #expect(SettingRowState(setting: try port).followedKeys.isEmpty)
    let address = SettingRowState(setting: try setting(Settings.serverAddress.key))
    #expect(address.followedKeys == [Settings.serverAddress.key])

    let calls = SettingRowState(setting: try setting(Settings.faceTimeOutgoingCalls.key))
    #expect(calls.requirementKeys.contains(Settings.enableFaceTimePrivateAPI.key))
    #expect(SettingRowState(setting: try port).requirementKeys.isEmpty)
  }

  @Test("The secret field is unread until the row holds a value")
  func secretFieldState() throws {
    var state = SettingRowState(setting: try password, value: nil)
    state.secretPresence = .stored(.persistedStore)
    #expect(!state.secretField.isLoaded)
    #expect(state.secretField.presence == .stored(.persistedStore))
    state.value = .string("read")
    #expect(state.secretField.isLoaded)
  }

  @Test("A switch and a picker read and write a stored value through their projections")
  func settingBoxProjections() {
    var box = SettingBox.bool(false)
    box.switchPosition = true
    #expect(box == .bool(true))
    #expect(SettingBox.string("x").switchPosition == false)

    var choice = SettingBox.string("lan")
    #expect(choice.choice == "lan")
    choice.choice = "ngrok"
    #expect(choice == .string("ngrok"))
  }
}

@Suite("Secret field policy")
struct SecretFieldPolicyTests {

  /// Bullets it did not read look exactly like an empty field, so the prompt is the only
  /// thing on the field itself that tells the three apart.
  @Test("An unread field says which of stored, absent or unreadable it is")
  func unreadPrompts() {
    #expect(
      SecretFieldPolicy.prompt(for: .stored(.persistedStore), isLoaded: false, fallback: "Not set")
        == "••••••••")
    #expect(
      SecretFieldPolicy.prompt(for: .unreadable, isLoaded: false, fallback: "Not set")
        == "Keychain unavailable")
    #expect(
      SecretFieldPolicy.prompt(for: .absent, isLoaded: false, fallback: "ngrok authtoken")
        == "ngrok authtoken")
  }

  @Test("A loaded field falls back to its own hint, whatever was stored")
  func loadedPrompt() {
    #expect(
      SecretFieldPolicy.prompt(for: .stored(.persistedStore), isLoaded: true, fallback: "hint")
        == "hint")
  }

  @Test("The eye is live with something stored or something typed, and not mid-read")
  func revealAvailability() {
    #expect(
      SecretFieldPolicy.canReveal(presence: .stored(.persistedStore), text: "", isRevealing: false)
    )
    #expect(SecretFieldPolicy.canReveal(presence: .absent, text: "typed", isRevealing: false))
    #expect(!SecretFieldPolicy.canReveal(presence: .absent, text: "", isRevealing: false))
    #expect(
      !SecretFieldPolicy.canReveal(presence: .stored(.persistedStore), text: "", isRevealing: true)
    )
  }
}
