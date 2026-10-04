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
`AlertsModel`, `UpdatesModel`, `SparkleUpdater`, `IntegrationsModel`, `OnboardingModel`,
`MigrationModel`) that attaches in `start` and detaches in `stop`. `SparkleUpdater` is the
one that outlives the server: detaching stops it following settings, not offering updates,
and `UpdaterPolicy` (off the object, so it can be tested) decides from the bundle's
`SUPublicEDKey` whether it starts at all. A dev bundle has no key and gets the plain feed
check `UpdatesModel` does instead. Both report through the alert centre, never through a
window of their own: a found release is an alert (with `.installUpdate` on a build that can
install, the download link on one that cannot), a remote install is a durable one so the
relaunch explains itself, and Home draws `updater.availableVersion`. `SparkleUpdater` is
also the app's `UNUserNotificationCenter` delegate, because it is the only thing that posts
a local notification; a second poster has to share that. `AppModel` is the root that owns phase,
navigation and lifetime, and nothing else that could live elsewhere.

## The server starts from the delegate, because a window is not guaranteed

`AppDelegate.applicationDidFinishLaunching` owns startup, and `AppModel.beginStart` owns the
attempt once it is running. Neither used to be true: the main window's `.task` did both, and
both assumptions it rests on are false.

**A `Window` scene does not always open.** AppKit pairs `-key value` arguments into
`NSArgumentDomain` and treats whatever is left over as a file to open, and a launch that is
opening a file opens no window of its own. `--headless --set k=v` leaves a leftover every
time: `--headless` takes no value, so AppKit pairs it with `--set`, and `k=v` is the
remainder. Measured — `--headless` alone starts normally, `--headless --set
socket_port=15879` never runs the window's `.task` at all, and so does a bare `BlueBubbles
hello`. With startup in that task the server never came up and said NOTHING about it, because
`start`'s only report of a failure is `phase` and headless has no window to show a phase in.
`LaunchStartupOwnershipTests` refuses a scene that starts the server.

**And a `.task` belongs to its view.** Headless closes the main window deliberately, and any
user can close it during a start that legitimately takes minutes on a large `chat.db`. So
`beginStart` holds the attempt on the model, which outlives every window, rather than awaiting
it somewhere that gets torn down. The window's `.task` now does the one thing that genuinely
needs a window: dismissing it.

`applicationDidFinishLaunching` DOES reach an `@NSApplicationDelegateAdaptor` object, verified
by probe on macOS 26 along with `applicationWillFinishLaunching`; an older comment in
`BlueBubblesApp.swift` claimed it did not.

## There are two page shapes, and the difference is whether the content scrolls itself

Nearly every page is a `SettingsPage`: a scroll view over a stack of cards, centred and capped
at `maximumContentWidth`. A page built around a `Table` cannot be, because a table in a scroll
view has no intrinsic height — it collapses or grows unbounded, and gives up the row recycling
that makes a long list cheap. Those use `TablePage`, which is the same `PageFrame` without the
scroll view, filling the height it is given, capped at the wider `maximumTableWidth` (four
columns squeezed into a settings column wrap the addresses they exist to show).

**`TablePage` paints the window background and that is not decoration.** A scroll view paints
it everywhere else, so the one page without a scroll view was the one page with nothing behind
it: a transparent hole in the detail column. The glass card sampled the desktop through it, and
so did the SIDEBAR, whose material samples the same backdrop — so the page tinted the sidebar,
and only while the window sat at the top of the screen. Nothing in the app is that colour.

Glass follows the rule in `GlassSurface.swift`: **chrome samples, content does not.** The
Contacts card is `ContentCard` rather than `GlassCard` for that reason — it fills the page, and
glass that size is a page of desktop behind a table of text.

## The Contacts page reads a page at a time, and the database does the work

Search, sort, filtering and counting are all SQL (`ContactIndex.search`). The page holds one
page of contacts and nothing else. It used to read the whole address book and filter in memory,
which is where the memory went, and it asked for five thousand while `ContactInterface.list`
clamps to a thousand — so an address book larger than that was silently truncated with a row
saying the list was capped naming a number that was never the cap.

Three consequences worth keeping. Sorting belongs to the query, because a page is a window onto
an ordering and re-sorting the window shows the wrong rows. The total comes from the SAME read
as the rows, or a page reports a total an ingest has already changed — which is exactly what
unlinking an account mid-visit does. And `ContactsQuery.clamp` pulls the offset back when the
set shrinks under it, because an offset past the end answers with no rows, and an empty table
reads as a failed read rather than as a page that is no longer there.

The page is the ONLY caller that passes `includeDisabled: true`: a switch you cannot see is a
switch you cannot undo. Everything else gets the serving behaviour by default.

## ntfy is an integration, and "event sink" is not the same as "notification"

ntfy used to be four core settings (`ntfy_topic`, `ntfy_server`, `ntfy_events`, `ntfy_token`)
registered by `WebhookDeliveryService`. That had three consequences nobody chose: ntfy's
configuration lived in the WEBHOOK manifest's entitlements, turning webhooks off stopped ntfy,
and nothing on the Integrations page said this server could do it at all.

It is `BuiltInManifests.ntfy` + `NtfyDeliveryService` now, configured by manifest fields in its
own namespace like every other integration. The four old keys are `isInternal` and are read by
exactly one thing: `NtfyDeliveryService.adoptLegacySettings`, once, which moves them into the
new namespace and clears them. That adoption is CODE and not a `FieldMigration`, because
`ServiceMigrator` assembles every key from the manifest's own namespace specifically so a
migration cannot reach core settings — the boundary working, not a gap. The old declarations
stay: a declaration removed is a value stranded in the database while the service reports
itself unconfigured.

**ntfy ships switched OFF** (`BuiltInManifests.disabledByDefault`), because being compiled in
is not a reason to be running: it publishes to a third-party service most installs do not use.
That is SEEDED into `disabled_services` once, not folded into `ServiceEnablement.isEnabled` —
the stored list means "what the user switched off", so a default applied on every read could
never be switched back on. The seed skips a service the install is evidently already using, and
for ntfy that means a topic in either place one can live, so an upgrade never silently stops a
working setup.

`FieldKind.eventSubscription` was added for its events field, while `ServiceManifest` is marked
FROZEN, under that file's own clause allowing a field a BUILT-IN needs today. A `multiSelect`
over the known event names cannot express `*`, which means "and whatever a later version adds",
and that distinction is the whole difference between the wildcard and ticking every box.

**The Notifications settings tab is `NotificationDeliverySection`**, and what it lists is not a
category query. It was `manifests(in: .eventSink)`, which put WEBHOOKS on a page about
notifications: being an event sink is a capability (`receiveEvents`) that any integration can
hold, and what webhooks delivers is a JSON body to a machine. `NotificationDeliveryRouting`
names the routes that put a notification in front of a person — push and ntfy — because the
frozen manifest surface has no way to declare it. When plugins are real, that becomes a
manifest flag and the list goes away. Routing is a decision because push has a real page
(guided setup, minutes long) and ntfy's configuration is its manifest, so one navigates and the
other opens the same sheet Configure ngrok opens.

## The devices page is Firebase's, and it shows push registrations

There are two device lists and they share nothing. `BBAppStore`'s `device` table is one row
per FCM registration token, written by a client calling `POST /api/v1/device`. `BBAuth`'s
`EnrolledDevice` registry is token-auth enrolment, a different type in a different store.

The sidebar's Devices page read the SECOND one, and under `auth_mode = password` — the
default, and per the setting's own note the only mode existing clients support —
`TokenAuthService` is constructed with no registry at all, so `devices()` returned an empty
array on every default install. The page then drew "No devices. Devices appear here once a
client registers" at a server with a phone registered and delivering notifications. Its own
header described the FCM table (`last seen`, `supported codecs`) while its read named the
other one; nothing caught it, because an empty list is what a correct page looks like before
anybody pairs.

It is `FirebaseDevicesView` now, a sub-page of Firebase (`FirebaseDetail`), reached from the
Manage card — which the page draws only once there is a service account, and that IS the
gate. An FCM token is issued BY a project and every row is dropped when the project changes,
so the list is meaningless until Firebase is set up, and a page that can only ever be empty
does not belong in the sidebar beside pages that work on a default install.

The list is FOLLOWED, not re-read on a timer (`DeviceObservation`): a client re-registers on
every launch and after every token rotation, and the sender prunes a row the moment FCM
rejects its token — a device disappearing is how somebody learns their phone stopped being
reachable, and none of those writes is an event on the bus.
`Tests/BBInterfacesTests/PushDeviceStreamTests` pins that a registration and a removal each
reach a follower.

The enrolment list now has no screen at all. That is a real gap, not a tidy-up: it is
waiting on whatever turns token auth on, and `TokenAuthService.devices()` says so.

## Who opened the app decides what the app does to its own window

`start_minimized` and `start_delay` are both answers to "nobody is looking", and macOS gives
a GUI app no way to tell a login from a double-click: the environment, the arguments and the
activation are identical. So the one process that knows says so. The launcher passes
`LauncherContract.automaticLaunchArgument` in `NSWorkspace.OpenConfiguration.arguments`,
`LaunchOptions.wasLaunchedAutomatically` reads it back, and `AppBehaviourPolicy` decides
(`startDelay(_:isUnattended:)`, `shouldStartMinimized(configured:isUnattended:isAwaitingSetup:)`).
A launch without the argument is a person, which is the safe direction: both settings hide
the window, and being wrong towards "somebody is watching" costs a window that stays open.

`isAwaitingSetup` is the other half and is not optional: onboarding and the migration wizard
are SHEETS on the main window, so minimising puts a modal dialogue somewhere nobody can see
it. That is what a user met after migrating — a long start, a window that minimised itself,
and setup waiting behind it.

The same report is why `StartupStage` exists. `.starting` is one phase and, on an old Mac
with a large `chat.db`, minutes of work; `AppModel.start` names each step and
`ServiceHealthObservation.noteStartupProgress` names the service the registry has
in flight, which is why `followServiceHealth` is attached BEFORE `built.start()`. It is a
separate property rather than a payload on `ServerPhase` because Home and `RootView` both
key a `.task` on the phase.

## Live state is followed, never polled

`serviceHealths`, `toolStatuses`, `privateAPIState`, `webhookDeliveries`,
`webhookRegistrationsVersion`, `pushDevicesVersion` and `accessControl` are followed from the server's streams for
the life of the server (`ServiceHealthObservation`, `ToolActions`, `PrivateAPIObservation`,
`WebhookObservation`, `DeviceObservation`, `AccessControlObservation`) and read off the model. Each follow subscribes BEFORE its seed read so
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
  re-animates every row below an insertion and moves state between rows on deletion. There is
  no offset id left: the log viewer held the last one and no longer has a `ForEach` at all.
- **A selection that has to span rows is one text view, not a stack of `Text`s.** A SwiftUI
  selection lives inside ONE `Text`, and in a LAZY stack it cannot do otherwise, because the
  rows are built and thrown away as they scroll. The log viewer was a `LazyVStack` of
  `Text`s with `.textSelection(.enabled)` on each, so a stack trace in the log could only be
  copied a line at a time. It is `LogTextView` now, one read-only `NSTextView`, which is also
  where ⌘A, ⌘F and a selection that survives the tail arriving under it come from. The cost
  of one document is paid by EDITING it: `LogDocumentUpdate` says what changed, and a tail at
  its 2,000-line cap is a few lines off the top and a few on the end rather than a rebuild.
- **A bespoke settings control is a `CustomSettingControl` case, not a key comparison.**
  `SettingRow.custom` switches over it exhaustively, so a control cannot be added without
  being drawn; `CustomSettingControlTests` proves the cases and the `.custom` declarations
  in the registry are the same set, in both directions.
- **A row whose switch is off is greyed out by its declaration, not by a key comparison.**
  `SettingPresentation.requires` names the parent's storage key; `SettingRow` disables the
  control and adds one `.locked` footnote saying which switch to turn on. It FOLLOWS those
  keys (the parent is usually the row directly above, and reading once left four FaceTime
  rows grey until the tab was left and re-entered) and only a row that declares one
  subscribes at all. Which switch to name is `Settings.blockingRequirement`'s decision and
  not the view's: chains exist (`auto_install_hour` → `auto_install_updates` →
  `check_for_updates`) and it answers with the outermost one that is off, because naming a
  nearer one points at a row that is itself greyed out.
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
  own, and a wrong one is re-made by the next failed login. Remove on a past scheduled
  message is one click too: the message already went or was stopped, and the row is the
  server's record of that. Clear All on the Past section IS confirmed, because it takes
  every failed row's error text, the only record of why a send never happened, in one go. Four of the first kind were
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
  reading the same collided. Two notes a row can show AT ONCE need separate kinds: a
  rejected write and an unread secret is that pair, which is why `.secret` exists.
- **A secret is read when somebody asks for it, never when the screen appears.** A secure
  field's resting state is bullets it did not read: `SettingRow` and `ServiceFormView` ask
  `SettingsStore.presence(ofSecretKey:)`, which answers stored / absent / unreadable without
  materialising anything, and the eye performs the read. It is a LOAD, not a mask toggle,
  and hiding forgets the value again. Two reasons, and the second is the one that bit: on
  the legacy Keychain `kSecReturnData` raises the system access panel when the item's ACL
  does not already trust this binary, and an ad-hoc rebuild invalidates that trust every
  time — so opening the Connection tab cost a panel per secure field; and a value nobody
  asked to see should not sit in a plain `@State` String, which is the rule onboarding has
  always followed (below) and the settings screen was the last place breaking.
  A row that has not read its secret has to SAY so, because bullets it did not read look
  exactly like an empty field: `SettingRowState.secretFootnote`. And "the Keychain refused"
  is never inferred from an empty read — an empty stored value is a real state — it is asked
  for, through `SettingsStore.unreadableSecretKeys`.
- **Error text goes through `DiagnosticText.sentence(for:)`.** Never `String(describing:)`.

## Setup asks for what is missing, and only that

Two rules the onboarding steps are built on, both of them the result of a step that asked
for something it already had or waved past something it did not.

- **The password is kept, not re-asked.** The stored value is never read back into the
  field (that would put a real secret in a plain `@State` for the session) so an empty
  field means "not set" on a fresh install and "set, and not shown" on every other.
  `OnboardingView.hasStoredPassword` asks the store which, through `SettingsStore.secret`,
  reading only `isEmpty`. It opens the gate, changes what `PasswordCard` says, and stops
  `saveCredentials` writing an empty string over a working password. An adopted Electron
  install has a password in the Keychain; the step that demanded a new one would have
  disconnected every client already paired. Deliberately NOT `presence(ofSecretKey:)`, which
  the settings screen uses to avoid materialising a secret: presence answers "is there a
  row", and this gate needs "is there a USABLE password". A secret stored as the empty
  string is present and lets nobody in, and a setup step that waved it through would finish
  with an open server.
- **A connection method with no program blocks, with a tick box.** It used to be a note
  beside a live Continue, and somebody took the Continue and finished setup with a tunnel
  that could never start. It is acknowledged rather than hard-blocked, the same shape
  `permissionsGate` uses and for the same reason: a download can fail for something the
  person cannot fix now, and the connection step has no Skip, so a hard block leaves Quit
  as the only way out. `OnboardingAnchor.requiredProgram` is what `OnboardingView` scrolls
  to when the program turns out to be missing, because the download button is below the
  fold and nothing said there was anything further down.

## The reference window is the only page in this app that can ask for a request

`APIDocsView` embeds Scalar so the API reference can send live requests, and the page it
loads keeps `connect-src 'none'`: the client's `customFetch` posts to `APIDocsRelay` over a
script-message port and the APP makes the call. That indirection is not decoration. It is
what keeps CSP from having to name a runtime origin, what keeps the `null`-origin CORS
allowance out of the load path, and what stops App Transport Security refusing a plain-HTTP
LAN address. `APIDocsRelayPolicy` holds the rules — where a relayed request may be sent,
which headers a page may not assert, and the response ceiling — off the view, so they are
testable.

If anything else in this app ever needs to render remote-ish content, it goes through the
same shape. A web view with a loosened `connect-src` is not the shortcut it looks like.

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
`AlertActionRouting`, `WebhookEventCatalog`, `WebhookChatSelection`, `OnboardingFlow`,
`SendLaterGuidance`, `UpdaterPolicy`, `InstallWindow`, `WhatsNew`, `ScheduledMessageRow`, `ServiceFormLayout`,
`LogFiltering` (with `LogLevelFilter`), `LogDocumentUpdate`, `FirebaseDetail`,
`NotificationDeliveryRouting`, `BlockedClientSummary`,
`ChatPickerNavigation`, `SettingRowState`, `WebhookDeliverySummary`, `DeviceRowSummary`, `HTTPListenerSummary`,
`APIDocsRelayPolicy`, `APIDocsPagePrefill` and
`PermissionGuidance` are enums and structs, not statics on a `View`. `SendLaterGuidance` is the sentence set the
Scheduled Messages page shows about Apple's Send Later, keyed on the macOS major and
`PrivateAPIPresence`; its version floor is `PrivateAPICapability.sendLater.minimumMacOS`,
never a number typed into the app. Touching a SwiftUI `View` type from a test process traps, so a decision
that deserves a test cannot live on the view that uses it. If you find yourself writing a
`static func` on a view that decides something, move it.

**Three shapes hide a decision from a test, and the last two are the ones people miss.** A
`private func` on the view is the obvious one. A type NESTED in a view is the second:
`LogLevelFilter` sat inside `LogsView`, so naming it meant naming the view, and the rules
that `critical` belongs under Error and that a line with no level appears only under All were
asserted by nothing. The third is a rule that MUTATES `@State` rather than answering:
`moveSelection` wrote the new selection in place, so it could not be asked what it would do —
`ChatPickerNavigation.selection(movedBy:in:from:)` returns it and the view does the writing.

A rule that reads the clock is the same problem in a fourth costume. `BlockedClientSummary`
and `ScheduledMessageRow.when` both take `now` as a parameter, which is what makes their
boundaries — a block that has just lapsed, a send eighteen hours out — something a test can
state rather than wait for.

Moving them is not bookkeeping: doing it found that the Scheduled Messages page showed a raw
GUID for every GROUP chat, because the rule split on `";-;"` and a group GUID is `any;+;chat…`.
It now goes through `ChatGUID`, which knows both separators.

**A note value that is a `View` carries main-actor isolation with it.** `SettingsFootnote`
conforms to `View`, so its stored properties are main-actor isolated and a key path to one
cannot be formed anywhere else; `SettingRowStateTests` and `ServiceFormLayoutTests` are
`@MainActor` for that reason alone. The rules themselves are pure. If a decision layer starts
to feel constrained by this, the answer is a plain note value the view renders, not a
`@MainActor` on the rule.

## Tests that will catch you

`Tests/BlueBubblesAppTests/`: `AccessibilityPolicyTests`, `IntegrationCatalogTests`,
`ConnectionMethodChoicesTests`, `OnboardingFlowTests`, `LaunchOptionsTests`,
`PushSelfHealTests`, `SendLaterGuidanceTests`, `UpdaterPolicyTests`, `InstallWindowTests`,
`WhatsNewTests`, `ScheduledMessageRowTests`, `ServiceFormLayoutTests`, `LogFilteringTests`,
`LogDocumentUpdateTests`, `NotificationDeliveryRoutingTests`, `BlockedClientSummaryTests`,
`ChatPickerNavigationTests`, `SettingRowStateTests`,
`WebhookDeliverySummaryTests`, `WebhookChatSelectionTests`, `DeviceRowSummaryTests`,
`HTTPListenerSummaryTests`, `APIDocsRelayPolicyTests`, `PermissionGuidanceTests`. `AppBehaviourPolicy` is asserted from `CompositionTests/ScopedSettingsTests`
and the setting-dependency declarations from `BBSettingsTests/SettingDependencyTests`.
