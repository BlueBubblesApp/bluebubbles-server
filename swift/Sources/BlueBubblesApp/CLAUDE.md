# BlueBubblesApp

The SwiftUI application: the settings window, onboarding, and the menu bar. It hosts the
server; it does not reach into it.

Full context: [`../../.claude/docs/architecture.md`](../../.claude/docs/architecture.md).

## Reach the server through a facade, never `AppContext`

`AppContext` is private to the composition root and stays that way. A view reads state off
`AppModel`, and the model reaches server capabilities through three grouped facades in
`ServerAccess.swift` (`model.security`, `model.messaging`, `model.delivery`) each a struct
built fresh per access over one optional reference. Only `settings`, `alertCenter`, `tools`
and `serverAdmin` sit flat on the model. A new capability goes in a group; a fourth flat
member on `AppModel` is the wrong answer.

State with its own lifetime lives on a child model in `Models/` (`PermissionsModel`,
`AlertsModel`, `UpdatesModel`, `IntegrationsModel`, `OnboardingModel`, `MigrationModel`)
that attaches in `start` and detaches in `stop`. `AppModel` is the root that owns phase,
navigation and lifetime, and nothing else that could live elsewhere.

## Live state is followed, never polled

`serviceHealths`, `toolStatuses`, `privateAPIState`, `webhookDeliveries`,
`webhookRegistrationsVersion` and `accessControl` are followed from the server's streams for
the life of the server (`ServiceHealthObservation`, `ToolActions`, `PrivateAPIObservation`,
`WebhookObservation`, `AccessControlObservation`) and read off the model. Each follow subscribes BEFORE its seed read so
no transition falls between them, and `stopFollowingServer` cancels all of them and clears
what they held, so a stopped server shows nothing stale.

A view never polls and never subscribes on its own. There are no `.task`/`.onDisappear` pairs
with reference counters (there were two, and a row that scrolled off screen could unsubscribe
the row still on it) and no timers: the log page reads `logLines`, which `LogObservation`
follows from `FileSink.follow(tail:)`, the last loop this app had. Those arrive as `LogLine`,
carrying the level the handler logged them at. A viewer never decides what a line is by
looking at its text: that is work per line forever on a sink every actor writes to, and it
breaks silently the day the format moves. The one parse left is the historical tail read back
from the file, where the text is the only record.

If something the app needs moves on the server without a stream, add the stream on the
server: `ServiceRegistry.healthChanges()`, `PrivateAPIRuntime.states()`,
`WebhookDeliveryTracker.changes()` and `AccessControlService.changes()` are the pattern, and
`AppDatabase.observe` follows a table whichever process path writes it; and follow it here.
Do not add a timer. The webhooks page had one, a ten-second sleep, and it was the app's last;
the access-control page had none and showed "expires in 0 seconds" instead. A value that
lapses on the clock is the server's to announce (`AccessControlService.scheduleExpiry`), not
the page's to re-read.

## A read that can fail shows that it failed

A page whose content IS a server read composes a `ScreenModel` (`ScreenModel.swift`) and
switches on its state. `(try? await …) ?? []` makes "the server refused" and "there are none"
the same value, which is how a failing read looks like an empty list for months.

`try?` is allowed in exactly three shapes, and each says which one it is in a comment:

- the failure is reported on another path, named in the comment: `ToolActions` after
  `ToolManager` has already raised the alert and set `.failed` on the status;
- the value is a glance, not the content: Home's count tiles render `-` and want no banner;
- `try? await Task.sleep`, whose only error is cancellation.

A settings write is never `try?`; see `.claude/docs/database.md`.

**A read is keyed on the server phase, never a bare `.task`.** Every list page is a `Group`
that switches between `ServerStoppedNotice` and its content, and the notice carries a Start
button, so a `.task { await screen.reload() }` on that group ran once against no server and
never again, and pressing Start showed "No devices" over a read that had not happened. A page
with a `ScreenModel` writes `.reloads(screen, following: model)`; a page whose rows are written
by something other than the page adds `alsoOn:` with a version the model follows from a
stream (Webhooks); a page with its own read writes `.task(id: model.phase.isRunning)`.
`ScreenReloadPolicyTests` refuses the bare form.

## Views

- **No `AnyView`.** A slot that takes a view takes a generic parameter with a `@ViewBuilder`
  initialiser and an `EmptyView` default (`SettingsSection(_:subtitle:content:trailing:)` in
  `SettingsLayout.swift`). Erasure defeats SwiftUI's diffing and hides which views a section
  can hold.
- **Rows are identified by the model's id, never by offset.** `ForEach(…, id: \.offset)`
  re-animates every row below an insertion and moves state between rows on deletion. The one
  offset id left is the log viewer, whose lines have no identity, and it says so.
- **A bespoke settings control is a `CustomSettingControl` case, not a key comparison.**
  `SettingRow.custom` switches over it exhaustively, so a control cannot be added without
  being drawn; `CustomSettingControlTests` proves the cases and the `.custom` declarations
  in the registry are the same set, in both directions.
- **A setting drawn by a bespoke screen is marked `isInternal`, and the screen declares
  its list off the view.** `bind_address` and `use_custom_certificate` configure the HTTP
  listener, so they sit behind Configure HTTP Settings on the Connection page rather than
  loose in the Connection form; `HTTPSettingsPanel` names them and `HTTPSettingsPanelTests`
  proves the generated page does not draw them too. The rows are `SettingRow`, the same
  view the generated page uses: a second copy of a field drifts, and the copy nobody
  looks at is the one that is wrong.
- **A symbol over an explanation is `NoticeCard`, and its colour is a `NoticeTone`, not a
  `foregroundStyle`.** Four screens had drawn this shape and no two agreed on where the
  symbol sat, how far apart, or whether the explanation was `.callout` or `.subheadline`.
  Tone is a separate argument on purpose: a notice explaining how a feature works must not
  borrow the colour of one reporting a problem, and `.informational` is the default because
  a page of coloured symbols teaches people to ignore the coloured one that matters. Use
  `NoticeBody` where the caller owns the container, as `FeatureDisabledNotice` does.
- **Shared views live in `Views/Components/`.** `Tag`, `StatCard`, `StatusDot`, `GlassCard`,
  `CopyableValue`, `SheetScaffold`, `FloatingBar`, `NoticeCard`, `LoadingNotice`, the two
  notices and the settings layout.
  A capsule with a word in it is `Tag`, tinted when the word is a judgement ("Required") and
  plain when it describes ("built-in"); five pages had drawn their own at three paddings.
- **A case is identity; its title is a computed property.** `Destination`, `SettingsTab`,
  `SettingSection`, `ScheduleRecurrence`, `LogLevelFilter` and `Recipient` have no raw
  display string. A status read off a record goes through the declared enum:
  `ScheduledMessageStatus(rawValue:)`, never `case "sent"`, so a renamed case is a compile
  error rather than a silent fallback. A settings
  section is a `SettingSection` case from `BBSettings`, placed on a tab in
  `SettingsTab.sections`; `SettingsTabTests` proves every case is placed exactly once, and
  `SettingSection.summary` is the sentence under its header. A wire value a case maps to
  (`Repeats.intervalType`) lives on its own property with a comment naming the contract, so
  renaming what a person sees cannot change what a client receives.
- **A destructive action confirms when it destroys something a person made; it is one
  click when it undoes the server's own bookkeeping.** Revoke a device (they enrolled it),
  Remove a webhook (they typed its URL and chose its events), Cancel a scheduled message
  (their words), Disconnect Firebase, Turn Off or Reset an integration: a
  `confirmationDialog` naming the thing, with the destructive button first. Clear All
  blocks and Unblock are one click: the server made those entries, they expire on their
  own, and a wrong one is re-made by the next failed login. Four of the first kind were
  one click and four were confirmed, and a person learns from the confirmed ones that a
  red button is safe to tap. While a mutation is in flight the button is disabled
  (`screen.isPerforming`), so a double-click cannot run it twice.
- **A switch shows its new position while the write is in flight.** A toggle or picker bound
  straight to server state flips, snaps back on the next render, and flips again when the
  reload lands, and one that asks for confirmation first snapped back instantly, which reads
  as a control that refused to move. Hold the value being written (`SettingRow.pending`,
  `IntegrationDetailView.enabledSwitch`) and clear it on success AND on failure, so a refused
  write snaps back beside the error that says why. Text fields are the exception, on purpose:
  a rejected password must not sit in the field looking saved.
- **Sheets declare a minimum and an ideal size, never a fixed one**, so a person can resize
  one under a larger text size. The main window's minimum height is set by the tallest sheet
  (onboarding, 640 points at its ideal), because a sheet taller than its window draws its
  footer off the bottom, out of reach.
- **⌘, opens Settings and ⌘1 to ⌘9 walk the sidebar** (`NavigationMenuItem` in
  `BlueBubblesApp.swift`). A menu item that navigates opens the main window first, so a
  shortcut pressed with the window closed brings the page up rather than moving a selection
  nobody can see.
- **An empty state is not shown while the read is still running.** A collection is empty
  before its first result lands, so a page that branches on `isEmpty` alone announces "No
  devices" or "Nothing scheduled" for the whole of the read. `ScreenState` keeps `idle` and
  `loading` apart for this; branch on `screen.state.isLoading` ahead of the empty case and
  show `LoadingNotice`. It is the same rule as the `problem == nil` guard those pages
  already carry, one moment earlier: a read that has not finished is as bad an answer as one
  that failed. `ScreenLoadingStatePolicyTests` scans for a screen that does not say.
- **A page does not write its own "server not running" state.** `ServerStoppedNotice` is the
  one place that sentence lives and the one place the Start button sits beside it; nine pages
  each wrote the sentence and none offered the button. `ServerStoppedNoticeTests` scans for
  the literal. `FeatureDisabledNotice` is the sibling for a switched-off feature.
- **A control a person can press has a name.** `AccessibilityPolicyTests` refuses an
  image-only label; see the non-negotiables in the root `CLAUDE.md`.
- **A count and its noun go through `Int.counted(_:)`.** Never `"\(n) thing(s)"`, which
  reads as unfinished copy, and never a hand-written `n == 1 ? "" : "s"`, which was at nine
  call sites. Phrase around the verb rather than agreeing with it: "Missing 1 required
  permission" needs no `is`/`are`.
- **A footnote's identity is its `Kind`, not its text.** `SettingsFootnote` is
  `Identifiable` by kind, and a row shows at most one of each; keyed by text, two notes
  reading the same collided.
- **Error text goes through `DiagnosticText.sentence(for:)`.** Never `String(describing:)`.

## Manifests come from the catalog

Every manifest lookup goes through `IntegrationCatalog` (`manifest(_:)`,
`connectionMethods`, `manifests(in:)`, `manifestDeclaring(tool:)`) and the catalog reads the
built-in list on ONE private line. That is what lets a connection method loaded from
somewhere else reach Home, the connection row, the health strip and onboarding by changing
one line; seven screens keeping their own `BuiltInManifests.all.first { … }` is how a plugin
would be run by the registry and shown by nothing. A glyph is `manifest.symbol`, not a switch
over built-in ids. `IntegrationCatalogTests` refuses a second lookup.

## Policy lives off the view

`IntegrationCatalog`, `ConnectionMethodChoices`, `NetworkAddressChoices`,
`AlertActionRouting`, `WebhookEventCatalog` and `OnboardingFlow` are enums and structs, not
statics on a `View`. Touching a SwiftUI `View` type from a test process traps, so a decision
that deserves a test cannot live on the view that uses it. If you find yourself writing a
`static func` on a view that decides something, move it.

## Tests that will catch you

`Tests/BlueBubblesAppTests/`: `AccessibilityPolicyTests`, `IntegrationCatalogTests`,
`ConnectionMethodChoicesTests`, `OnboardingFlowTests`, `PushSelfHealTests`.
