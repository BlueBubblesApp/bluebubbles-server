# BlueBubblesApp

The SwiftUI application: the settings window, onboarding, and the menu bar. It hosts the
server; it does not reach into it.

Full context: [`../../.claude/docs/architecture.md`](../../.claude/docs/architecture.md).

## Reach the server through a facade, never `AppContext`

`AppContext` is private to the composition root and stays that way. A view reads state off
`AppModel`, and the model reaches server capabilities through grouped facades in
`ServerAccess.swift` (`model.security`, `model.messaging`, `model.delivery`,
`model.subscription`, `model.monitoring`) each a struct built fresh per access over one
private optional reference, and built only by `AppModel.swift`, the one file that can read
the context. No door returns the context itself, even typed as a capability protocol: `as?
AppContext` would recover the whole container from it, so a protocol-typed door returns a
private forwarder (`PushSetup`). Only `settings`, `alertCenter`, `tools` and `serverAdmin`
sit flat on the model. A new capability goes in a group; a fourth flat member on `AppModel`
is the wrong answer. `FrontEndPlumbingPolicyTests` refuses a door whose body is the bare
context, and `AppContext` or a server's `.context` named outside the model and the facades.

**Settings have one door, `model.settings` (`Models/SettingsModel.swift`), and it is not an
optional.** A view reads, writes, follows and keeps an unsaved edit through it and through
nothing else. With no server every call THROWS `ServerNotRunning`, whose sentence
`DiagnosticText` renders, because the shape it replaced (`guard let store =
model.settingsStore else { return }`, at twenty-four call sites) made a write with no server
do nothing and say nothing: the switch flipped back and the page gave no reason. Its writes
run as the operator inside the model, so a view does not wrap them in `asOperator`;
`OperatorAttributionPolicyTests` accepts a call through `model.settings` because it checks
every writer there opens one. It is attached BEFORE the start delay, so the settings screen
opens during one. `ViewPlumbingPolicyTests` refuses `SettingsStore`, `settingsStore` and
`.changes()` under `Views/`.

**A change the app makes to the server runs inside `asOperator`** (`OperatorAttribution.swift`):
a settings write, an access-control change, a webhook or scheduled message, an import, a
licence exchange. The audit log names whoever the work in flight says is acting and names
nobody else, so a write outside it is recorded as `unattributed`. `ScreenModel.perform` and
`SecurityAdministration.mutate` already run their bodies that way; the app's own bookkeeping
(the running version, adopting old `UserDefaults` state) is `.system(component: "app")`.
`OperatorAttributionPolicyTests` fails the build on a write that is neither.

State with its own lifetime lives on a child model in `Models/` (`SettingsModel`,
`PermissionsModel`, `AlertsModel`, `UpdatesModel`, `SparkleUpdater`, `IntegrationsModel`,
`OnboardingModel`, `HomeModel`, `ArchiveModel`, `MigrationModel`, `LogsModel`, `MetricsModel`,
`WebhooksModel`), each `ServerAttachable`.
**Attach and teardown are one list** (`ServerAttachments.swift`): `start` attaches a child
with `attachments.attach(child) { $0.attach(…) }`, which records the child's `detach` in the
same call, and `attachments.detachAll()` undoes every entry in reverse on every way out: a
stop, a failed start, and the next start after one that stopped at the migration wizard. The
composition's own stop and the follows are entries on it too. It used to be a second,
hand-written list in `tearDown`, and from `.migrationRequired` onboarding, Home and the
archive were never detached. `FrontEndPlumbingPolicyTests` refuses a child attached or
detached by hand. `HomeModel` also holds what Home has read, cleared by
`stopFollowingServer`, so the page shows what the last visit read rather than reading it
again (see Home, below).
`SparkleUpdater` is the one that outlives the server: detaching stops it following settings and disarms a scheduled relaunch (which would start the server again), not offering updates; a downloaded update still installs on quit, and `attach` re-arms the relaunch (`UpdaterPolicy.armsScheduledInstall`),
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
attempt once it is running. `start` is private: every Start button, the migration wizard and
`restart` go through `beginStart` too, so none can begin a second attempt beside one in
flight. Neither used to be true: the main window's `.task` did both, and
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

The search waits for typing to pause (`SearchDraft`, drawn by `PausedSearchField`): each
search is a query of the index, and the Audit Log's measurements of a query per keystroke
are in `SearchDraft`'s header. The card around the table is `PagedTableCard`, which the
Audit Log uses too.

Three consequences worth keeping. Sorting belongs to the query, because a page is a window onto
an ordering and re-sorting the window shows the wrong rows. The total comes from the SAME read
as the rows, or a page reports a total an ingest has already changed — which is exactly what
unlinking an account mid-visit does. And `PageCursor.clamp` pulls the offset back when the
set shrinks under it, because an offset past the end answers with no rows, and an empty table
reads as a failed read rather than as a page that is no longer there. The cursor is a value
`ContactsQuery` holds (the Audit Log's query holds another), the page calls the clamp on every
change of total, and `Pager` only draws it: the clamp must run when the set has shrunk to one
page, which is exactly when the pager is not on screen.

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

`serviceHealths`, `toolStatuses`, `privateAPIState`, `pushDevicesVersion`, `accessControl`
and `clientAddress` are followed from the server's streams for the life of the server
(`ServiceHealthObservation`, `ToolActions`, `PrivateAPIObservation`, `DeviceObservation`,
`AccessControlObservation`, `AddressObservation`) and read off the model. A follow is a case
on `ServerFollow` started through one of two helpers (`ServerFollows.swift`):
`follow(_:subscribe:seed:apply:reset:)`, which subscribes BEFORE its seed read so no
transition falls between them, and `countChanges(_:of:atMostEvery:bump:)` for a table a page
reads itself. Each registers what stopping it clears, so `stopFollowingServer` is one call
over the `FollowTable` and a stopped server shows nothing stale; there is no task property
per follow to forget.

Three groups of followed state are child models instead, because each is one concern with a
lifetime of its own: `model.webhooks` (`WebhooksModel`: `deliveries` and
`registrationsVersion`), `model.metrics` (`MetricsModel`: `snapshot`, `ring` and
`newMessageMinute`) and `model.logs` (`LogsModel`: the tail). Each follows on its own
`OwnedTask`, as `AlertsModel` does, is attached through the attachment list once the services
are up, and clears what it held in `detach`; the webhook registrations share the counting loop
with the table, `FollowTable.countChanges(named:of:atMostEvery:bump:)`. Their followed values
are `private(set)`: only the follow writes them.

A view never polls and never subscribes on its own. There are no `.task`/`.onDisappear` pairs
with reference counters (there were two, and a row that scrolled off screen could unsubscribe
the row still on it) and no timers: the log page reads `logs.lines`, which `LogsModel`
follows from `FileSink.follow(tail:)` while the page is showing (`AppModel.selection` tells
it), the last loop this app had. Those arrive as `LogLine`,
carrying the level the handler logged them at. A viewer never decides what a line is by
looking at its text: that is work per line forever on a sink every actor writes to, and it
breaks silently the day the format moves. The one parse left is the historical tail read back
from the file, where the text is the only record.

Which services are switched on is followed the same way, by a child model rather than a
property: `IntegrationsModel.attach` subscribes to `SettingsStore.changes()` for
`connection_method` and `disabled_services`, then seeds, and every writer (the Integrations
page, a page's own `FeatureDisabledNotice`, onboarding, an API client, the server seeding its
defaults) goes through that one store. Its `refresh` is private, so a page cannot re-read it
on every visit, which is what Contacts, Audit Log, API & Webhooks and Firebase each did.

Settings are followed the same way, by `SettingsModel`, and read in a different shape
because a view reads only a few keys: `model.settings.version(of: keys)` (or
`version(inNamespace:)` for a manifest's fields) moves on every write to them, from anywhere,
and a view keys a `.task(id:)` on it to read again. Each key's counter is its own observable
object, so a write re-renders the views following that key and no others; read a version
only for keys the view actually follows, because reading it is what subscribes. Five views
had their own `for await … store.changes()` loop.

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

**A read is keyed on the server phase, never a bare `.task`.** Every list page is a `ListPage`
that switches between `ServerStoppedNotice` and its content, and the notice carries a Start
button, so a `.task { await screen.reload() }` on that view ran once against no server and
never again, and pressing Start showed "No devices" over a read that had not happened. A page
with a `ScreenModel` writes `.reloads(screen, following: model)`; a page whose rows are written
by something other than the page adds `alsoOn:` with a version the model follows from a
stream (Webhooks); a page with its own read writes `.task(id: model.phase.isRunning)`.
`ScreenReloadPolicyTests` refuses the bare form.

## Home is a dashboard, and every summary on it is decided off the view

Every card summarises state another page owns and carries the button to that page. What a
card SAYS (which services count as a problem, how minutes fold into a chart bucket, what
"today" is compared with) is `HomeDashboard`, tested in `HomeDashboardTests`. The live
server numbers arrive from `ServerMetrics`, which samples on the SERVER every few seconds;
Home keeps no clock. One stream lands on THREE properties, because a view observes a
property and they move at three rates (`MetricsModel`): `metrics.snapshot` on every
sample, for a live figure; `metrics.ring` once a minute, for the hour's sparklines;
`metrics.newMessageMinute` when a message arrives and at most once a minute, for the activity
section's read. A section reads the slowest one that answers its question, or every sample
re-evaluates it. The
message-flow and server-history sections are `ScreenModel` reads keyed on their range and on
the property that moves with them, so they refresh without a timer. Longer history is
`model.monitoring`, a fifth facade group, because none of the others is about it.

**Two depths, and Basic is the default.** `HomeModel.Detail` is picked in the toolbar: Basic is
the attention rows, the tiles and the summary cards; Advanced adds the Messages and Server
sections, whose `.reloads` tasks exist only while they are on screen, so Basic never reads
`chat.db` for a chart nobody is looking at. Persisted per server as `Settings.homeDetail`,
seeded by `HomeModel.attach` beside the onboarding state and written back on change, the
`OnboardingModel` shape; Basic on a server that has never been asked.

**A visible change inside glass is a glass re-sample, whatever caused it.** Measured: about
200 MB of graphics memory per repaint on macOS 26, the same with and without the page's
`GlassEffectContainer`, and none at all with the plain surface style. So a figure that moves
on every sample must not be drawn live: the Memory card shows the last finished minute, not
the snapshot, and the other live figures change only when something happened. A relative age
goes through `HomeDashboard.relative`, which is to the minute, because `formatted(.relative(…))`
says "5 seconds ago" and then "10 seconds ago". It is the app's ONE relative age, off Home as
well (the audit log, scheduled messages, webhook deliveries, registered devices), so a
summary that formats one takes `now` and calls it; `SharedComponentPolicyTests` refuses
`.relative(presentation`, `RelativeDateTimeFormatter` and `style: .relative` anywhere else
in the module. The same rule holds off Home: a stream that
lands in the glass sidebar reports no faster than it has to (`progressReportInterval` is five
seconds), and a degraded service that measures its progress is in flight on Home, not a
problem whose text moves with every report. CoreAnimation-driven motion is exempt: a
`ProgressView()` spinner inside a glass card was measured at no cost at all, because it is a
layer of its own and never re-renders the glass view.

**A card's inputs are what lets SwiftUI skip it, so nothing in a body reads `.now`.** A
clock reading handed to a card goes through `HomeDashboard.minute`, so the card is the same
value for a minute; a placeholder is built once (`Glance.sample`, `HomeActivity.sample`,
`HomeServerHistory.sample`), never `placeholder(now: .now)` in a body; and every chart is its
own `Equatable` view under `.equatable()`, apart from the live figure beside it, because a
chart is the most expensive thing on the page to lay out and its data moves far less often
than the figure. Measured before these: every five-second sample re-evaluated the whole page,
seven charts included, and re-composited the page's glass.

**What Home has read lives on `HomeModel`, not in the page's `@State`, and a visit reads only
what is stale.** The reads are the most expensive the app makes (every message counted, every
attachment grouped, a month of messages read three ways), and held in `@State` they ran again
on every visit, because `.task(id:)` fires on every appearance and the detail column tears the
page down whenever another page shows. `HomeModel` keeps the glance, the two `ScreenModel`s
and the ranges for the life of the app model; each read records what it was read for and when
(`ReadFreshness`), PER CARD (`Glance.Card`, with `Visit.key(for:)` naming what each card
depends on: only Delivery follows the device and webhook versions), and a visit reads only
the cards whose key moved or whose values are older than `HomeModel.maximumAge`. The Refresh
button in the toolbar, beside "Updated … ago", reads everything on screen. This
is not a timer, and the rule above stands: the age is measured when the person arrives, never
on a schedule. `ScreenModel.reload(for:unlessFresherThan:)` and the matching `.reloads(…,
unlessFresherThan:)` are the general form; `ScreenModelTests` and `ReadFreshnessTests` pin
what a visit costs. `stopFollowingServer` clears it with everything else followed.

**A first read is a skeleton of the card, and each card reveals on its own.** The glance is
read concurrently and each value assigned as it lands; a card is a `Skeleton` while a glance
read is in flight and its own values (`Glance.hasArrived`) are not back, so Library waits on
the totals and Delivery does not. A card whose read failed stops being a skeleton the moment
the read finishes and draws `-`, and a Refresh never re-skeletons a value on screen, the same
rule `ScreenModel.load` keeps with `if state.value == nil`. The two sections are skeletons
under `screen.state.isLoading`. Figures the model follows from streams (`metrics`,
`accessControl`, the six tiles) are not reads Home makes and render `-` until the stream
seeds, never a skeleton. Placeholders live on the data types (`Glance.placeholder(now:)`,
`HomeActivity.placeholder(now:)`, `HomeServerHistory.placeholder(now:)`), take `now`, and
carry every row a card adds once a value is present, so the skeleton is the loaded height;
`HomePlaceholderTests` pins that. Every chart on Home takes `chartFrame(height:)`, which is
a flat block under redaction, because a chart of placeholder bars reads as data.

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
  rows grey until the tab was left and re-entered), by keying a `.task(id:)` on
  `model.settings.version(of:)`, and only a row that declares one reads that version at
  all. Which switch to name is `Settings.blockingRequirement`'s decision and
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
- **A state's colour is a `StatusTone` (`StatusTone.swift`), never a colour of its own.**
  One vocabulary for notices, footnotes, status dots, Home's tiles and every row coloured by
  its state: `.informational`, `.good`, `.attention`, `.problem`, each with its `tint` and,
  for a tone drawn on its own, its `symbol`. A view maps its state to a tone; a rule that
  answers with one lives off the view (`ServerPhase.tone`, `AuditRowSummary.tone`,
  `StatusTone(Severity)`). Four vocabularies and five private colour maps had drifted: a
  starting server was a warning in the sidebar and unknown on Home. A chart's series colour
  is not a state. `SharedComponentPolicyTests` refuses `.red`, `.orange`, `.green` and
  `.yellow` under `Views/` outside a chart's gradient or scale.
- **A symbol over an explanation is `NoticeCard`, and its colour is a `StatusTone`, not a
  `foregroundStyle`.** Four screens had drawn this shape and no two agreed on where the
  symbol sat, how far apart, or whether the explanation was `.callout` or `.subheadline`.
  Tone is a separate argument on purpose: a notice explaining how a feature works must not
  borrow the colour of one reporting a problem, and `.informational` is the default because
  a page of coloured symbols teaches people to ignore the coloured one that matters. Use
  `NoticeBody` where the caller owns the container, as `FeatureDisabledNotice` does.
- **Shared views live in `Views/Components/`.** `Tag`, `StatCard`, `StatusDot`, `GlassCard`,
  `TitledCard`, `CopyableValue`, `SheetScaffold`, `ConfigureSheet`, `FloatingBar`,
  `NoticeCard`, `LoadingNotice`, `Skeleton`, `ManifestRow`, `ServiceStatusLine`, `DropZone`,
  `ListPage`, `PagedTableCard`, `SearchField`, `PausedSearchField`, `Pager`, `SecretField`,
  `SectionEmptyText`, `ToolbarCaption`, `ErrorLine`, `ActionOutcomeLine`, `DividedForEach`,
  `ServerAddressRow`, the two notices, the settings layout, and the tokens they are measured
  in (`SettingsMetrics.swift`). Home's two Advanced sections share `HomeChartSection`. A short secondary figure in a toolbar (a count, "Updated …
  ago") is `ToolbarCaption`, which carries the inset the toolbar's glass capsule needs.
  A capsule with a word in it is `Tag`, tinted when the word is a judgement ("Required") and
  plain when it describes ("built-in"); five pages had drawn their own at three paddings.
  A search box on a page is `SearchField`, one look (the control-chrome glass) where three
  pages had three backgrounds; a database-paged list's footer is `Pager` over the page's
  `PageCursor`.
- **A service's status line is `ServiceStatusLine`, never a `Label` coloured on
  `isProblem`.** The words are `ServiceStatusSummary`'s, off the view, and the colour is the
  line's `StatusTone`; five sites had drawn it at two sizes, and one re-declared the line as
  a tuple so its sentences could not be asserted. A line with different words for a
  different place (`publishedAddressLine`) is another function on `ServiceStatusSummary`,
  not a switch in a view.
- **A row that names an integration is `ManifestRow`.** The glyph is `manifest.symbol`, the
  tags beside the name are a slot (`Tag`, a selected dot), the trailing edge is a slot (a
  button, a count), and `showsChevron` says the row leads somewhere. The caller owns what
  pressing it does: a `NavigationLink` around it or a button in the trailing slot. The
  Firebase devices row is not a manifest and uses the initialiser that names its parts.
- **A file drop target is `DropZone`, and it always has a Choose button.** A drop cannot be
  reached by keyboard or VoiceOver, so dragging is never the only way in. Dropped and chosen
  files reach the same closure as one batch, and a whole page that accepts drops uses
  `acceptsFileDrop`. `allowedContentTypes` narrows the panel only: both callers classify a
  file by reading it, and refusing a drop by extension would refuse the misnamed one they
  could have read. `SharedComponentPolicyTests` refuses `isProblem`, a `chevron.right`
  image and `.onDrop(` in a view outside the component that owns each.
- **A glass card that opens with a headline is `TitledCard`**, with a `trailing:` slot for a
  tag or a spinner beside the title. Nine cards drew it at three spacings; it has one,
  `SettingsMetrics.cardStackSpacing`. A card titled by a `Label` (`HomeCard`) or by a value
  (a device's name) is another shape and stays one. `SharedComponentPolicyTests` refuses a
  `GlassCard` whose first lines are a literal `.headline` `Text`.
- **A failure said in one line is `ErrorLine`**, `.regular` under a page, a section or in a
  sheet's footer and `.compact` inside a row. Not a footnote in a settings row's list (that
  is `SettingsFootnote`, keyed by its kind) and not a state a page is IN (a `NoticeCard`).
  What a one-off button did is an `ActionOutcome` drawn by `ActionOutcomeLine`: done,
  waiting on somebody else (a system sheet), or failed, which is drawn as an `ErrorLine`.
- **The address a person types into a client is `ServerAddressRow`**, over the model's
  followed `clientAddress` and `APIReachability`'s placeholder and note, so it moves when a
  tunnel republishes and is never offered while nothing is listening behind it.
  `ClientAddress.forThisMac` is the `localhost` fallback, and it is only for a request made
  from this Mac (the API reference's samples): on a phone, `localhost` is the phone.
- **Rows divided by a line are `DividedForEach`, and a tick box over a set is
  `Binding(contains:in:)`.** Both were written by hand at a dozen and four sites.
- **A section with nothing in it says so with `SectionEmptyText`**: one quiet line, callout
  and secondary, with a row's vertical room. Nine sections drew it in three fonts. A whole
  page or list that is empty is an invitation instead (`ContentUnavailableView`, the
  `ListPage` empty slot). `SharedComponentPolicyTests` refuses a `Text("No …")`,
  `Text("None …")` or `Text("Nothing …")` elsewhere under `Views/`.
- **A measurement is a token from `SettingsMetrics.swift`, never a number at the call
  site.** Corner radii are `cardCornerRadius` (a card), `tileCornerRadius` (a surface that
  stands on its own smaller than a card: a drop zone, a choice, a migration step),
  `fieldCornerRadius` (a field, a block or a clipped table inside a card) and
  `rowCornerRadius` (a row's hover or selection highlight); a leading symbol column is
  `iconColumnWidth`, and the gap between the blocks a card stacks is `cardStackSpacing`. A
  radius that is one control's own geometry is a named constant in that control's file
  saying what it is relative to (`FloatingBar`'s concentric pair, `ConversationRow`'s inset
  highlight). A one-off measurement (a chart's height, a glyph's size, the width one picker
  needs) stays where it is: a token claims a sameness, and a one-off has none.
  `DesignTokenPolicyTests` refuses a literal `cornerRadius:` or ideal sheet size under
  `Views/` outside the tokens file.
- **A copy to the clipboard is `Pasteboard.copy(_:)`.** It clears before it writes, which a
  hand-written `setString` can forget, leaving another app's representation to be pasted.
  `SharedComponentPolicyTests` refuses `NSPasteboard` anywhere else in the module.
- **A case is identity; its title is a computed property.** `Destination`, `SettingsTab`,
  `SettingSection`, `ScheduleRecurrence`, `LogLevelFilter` and `ScheduleDraft.Recipient` have no raw
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
  as a control that refused to move. Bind it through `Binding.optimistic(current, pending:,
  write:)` (`OptimisticWrite.swift`), which holds the value being written and lets it go in
  a `defer` (unless a newer write has put its own value there), so a refused write snaps
  back beside the error that says why; a switch that
  confirms first passes `asksFirst:` and its dialog runs `OptimisticWrite.perform`. Four
  screens had built this by hand, four ways. Text fields are the exception, on purpose: a
  rejected password must not sit in the field looking saved.
- **A dialog presented over an optional is `.isPresent($optional)`**, or
  `.isPresent({ … }, dismiss: { … })` when a model owns what is presented
  (`Binding+Presence.swift`). Seven copies of `Binding(get: { x != nil }, set: …)` existed;
  `ViewPlumbingPolicyTests` refuses an eighth.
- **A sheet is `SheetScaffold`.** Title and subtitle, the content, and a footer that commits,
  in the same places on every sheet. What genuinely differs is a parameter: `SheetCancel`
  (`.dismiss`; `.action` for a sheet held on a model, whose Cancel has to tell the model;
  `.none` with "Done" for a form that saves as it is edited, where a Cancel would promise
  an undo that does not exist) and `scrollsContent: false` for content that scrolls itself,
  a `List`. A sheet that only shows something (the audit record inspector) takes the
  read-only initialiser and has a single Done, because a Cancel beside nothing to commit
  offers to undo a change nobody made. A service's form in a sheet is `ConfigureSheet`, which
  is the scaffold around `ServiceFormView`.
- **Sheets declare a minimum and an ideal size, never a fixed one**, so a person can resize
  one under a larger text size. Both are a `SheetSize`, named for what the sheet holds
  (`.form`, `.detail`, `.short`, `.prompt`, and the two sheets with their own chrome,
  `.migration` and `.onboarding`): `SheetScaffold(size:)` takes one, and a sheet that is
  not a scaffold frames itself with `.sheetFrame(_:)`. The main window's minimum height is set by the tallest sheet
  (onboarding, 640 points at its ideal), because a sheet taller than its window draws its
  footer off the bottom, out of reach.
- **⌘, opens Settings and ⌘1 to ⌘9 walk the sidebar** (`NavigationMenuItem` in
  `BlueBubblesApp.swift`). A menu item that navigates opens the main window first, so a
  shortcut pressed with the window closed brings the page up rather than moving a selection
  nobody can see.
- **An empty state is not shown while the read is still running.** A collection is empty
  before its first result lands, so a page that branches on `isEmpty` alone announces "No
  devices" or "Nothing scheduled" for the whole of the read. `ScreenState` keeps `idle` and
  `loading` apart for this. A list page hands its screen to `ListPage`, which shows
  `LoadingNotice` ahead of the empty case and keeps a failed read away from it; anything else
  branches on `screen.state.isLoading` itself. It is the same rule as the `problem == nil`
  guard, one moment earlier: a read that has not finished is as bad an answer as one that
  failed. `ScreenLoadingStatePolicyTests` scans for a screen that does not say.
  A dashboard card says it another way: `Skeleton` (`Views/Components/Skeleton.swift`)
  draws the card's OWN layout from a placeholder value, greyed and dimmed, and swaps to the
  read in place when it lands, so the content arrives where the skeleton was instead of
  under a spinner of another height. It is ONE view, never a redacted copy over the real
  card: two glass surfaces on top of each other inside the page's `GlassEffectContainer`
  merge into one smeared shape, which is what a crossfade between them looked like. And it
  does not pulse: a repeating opacity change inside glass re-samples the glass at frame rate
  for as long as the read runs. The loading decision still comes from `ScreenState` or, for
  the glance, `HomeModel.isLoading(_:)`; the view decides nothing.
- **And the branching that decides which of those to draw is CLOSED.** A `body` whose
  `else if` chain has no final `else` renders nothing in the state it forgot, and a view with
  nothing to draw takes its modifiers with it: the `.reloads` task never installs, so the page
  does not fill in a moment later either. `SubscriptionSettings` shipped that way and the
  Subscription tab was blank on a working server, because the state it forgot was `idle`,
  which is the state every visit starts in. Decide the state off the view and `switch` on it,
  so the compiler checks the totality — `SubscriptionPolicy.Page` is the shape. For a LIST
  page the switch already exists: `ListPage` (`Views/Components/ListPage.swift`) switches
  over `ListPagePolicy.state` (stopped, switched off, loading, empty, rows), and the page
  supplies only its empty state, its rows and, when it has filters or a pager that stay put
  while it reads, the frame the list area sits in. Scheduled Messages, API & Webhooks, Audit
  Log, Contacts and Firebase's devices are built on it; each had written the chain by hand,
  and two had drifted (an empty state over a failed read, a branch that drew nothing).
  `ScreenLoadingStatePolicyTests` scans for the open chain, and for a page that composes a
  `ScreenModel` and draws the whole-page stopped notice itself instead of going through
  `ListPage`.
- **A page does not write its own "server not running" state.** `ServerStoppedNotice` is the
  one place that sentence lives and the one place the Start button sits beside it; nine pages
  each wrote the sentence and none offered the button. `ServerStoppedNoticeTests` scans for
  the literal. Its words are the phase's (`ServerAvailability.swift`): the settings door is
  attached before the start delay, so a tab draws live rows during it, and the notice under
  them says the server is starting, with a spinner where the Start button would be, rather
  than "not running" under rows that plainly work. `FeatureDisabledNotice` is the sibling
  for a switched-off feature, with the same kind of placement: `.page` on a `SettingsPage`
  (what `ListPage` draws), `.card` above content that still renders (Firebase), `.inline`
  in a card the page draws (both API & Webhooks cards). The placement is required, so no
  page wraps it in a `ScrollView` of its own again.
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
  `model.settings.presence(…)`, which answers stored / absent / unreadable without
  materialising anything, and both draw `SecretField`, whose eye performs the read through
  the caller's `reveal` and whose hiding calls the caller's `forget`. One control, because
  the two copies had already drifted (one had Generate, they disagreed on when the eye was
  live); what its prompt says and when its eye is live is `SecretFieldPolicy`. It is a LOAD, not a mask toggle,
  and hiding forgets the value again. Two reasons, and the second is the one that bit: on
  the legacy Keychain `kSecReturnData` raises the system access panel when the item's ACL
  does not already trust this binary, and an ad-hoc rebuild invalidates that trust every
  time — so opening the Connection tab cost a panel per secure field; and a value nobody
  asked to see should not sit in a plain `@State` String, which is the rule onboarding has
  always followed (below) and the settings screen was the last place breaking.
  A row that has not read its secret has to SAY so, because bullets it did not read look
  exactly like an empty field: `SettingRowState.secretFootnote`. And "the Keychain refused"
  is never inferred from an empty read — an empty stored value is a real state — it is asked
  for, through `model.settings.isUnreadable(_:)`.
- **Nothing writes a setting on the way out.** A view being torn down is the one place that
  cannot show what a write refused, so a rejected password would sit in a field nobody can
  see, saved as far as anyone could tell. A row or form leaving with an uncommitted edit
  KEEPS it (`model.settings.keepDraft(_:typedOver:for:)`) and takes it back when it
  appears, still under "Not saved yet", unless the stored value has moved since. A sheet's
  Done commits before it closes (`ServiceFormView.commitRequest`), and a refused field keeps
  the sheet open. `ViewPlumbingPolicyTests` refuses a commit or a settings write inside
  `.onDisappear`.
- **Error text goes through `DiagnosticText.sentence(for:)`.** Never `String(describing:)`.
- **A service's form is built from the settings row's controls (`SettingControls.swift`),
  and keeps the row's lifecycle.** `ServiceFormView` follows its manifest's namespace
  (`version(inNamespace:)`), so a reset or another writer shows without rebuilding the form;
  a field holding an edit keeps it across the re-read. A refused write snaps the control
  back and says why under the field, as a row does, and a read that fails says so above
  fields it leaves untouchable. The Keychain sentence is `SecretFieldPolicy.note`'s, for
  both. A number outside its declared range is refused under the field
  (`ServiceFormLayout.rangeFailure`), never clamped as it is typed.
- **A preference written from a `didSet` goes through a `PreferenceWriter`**, one write at
  a time and the last value set last, because two tasks racing to the store are not
  promised to land in order. A read-modify-write of a list several switches share
  (`IntegrationsModel.toggle`) starts from what the switches already say, not from the
  last read.

## Setup asks for what is missing, and only that

Two rules the onboarding steps are built on, both of them the result of a step that asked
for something it already had or waved past something it did not.

- **The password is kept, not re-asked.** The stored value is never read back into the
  field (that would put a real secret in a plain `@State` for the session) so an empty
  field means "not set" on a fresh install and "set, and not shown" on every other.
  `OnboardingView.hasStoredPassword` asks the store which, through `model.settings.secret`,
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
`AlertActionRouting`, `WebhookEventCatalog`, `OnboardingFlow`, `SendLaterGuidance`,
`UpdaterPolicy`, `InstallWindow`, `WhatsNew`, `ScheduledMessageRow`, `ServiceFormLayout`,
`LogFiltering` (with `LogLevelFilter`), `LogDocumentUpdate`, `FirebaseDetail`, `StatusTone`,
`ActionOutcome`, `ClientAddress`, `GuidanceStatus`, `ConversationChoice`,
`ConversationLabel`, `PrivateAPIStatusSummary`, `MigrationStepPresentation`, `SearchDraft`,
`AllowlistEntry`, `ServerAvailability` (the stopped notice's words, by phase),
`FirebaseSetupPrompt`, `ServiceStatusSummary`,
`NotificationDeliveryRouting`, `BlockedClientSummary`, `SubscriptionPolicy`,
`ChatPickerNavigation`, `SettingRowState`, `WebhookDeliverySummary`, `DeviceRowSummary`, `HTTPListenerSummary`,
`APIDocsRelayPolicy`, `APIDocsPagePrefill`, `ListPagePolicy`, `PageCursor`, `ScheduleDraft`,
`SecretFieldPolicy`, `OptimisticWrite` and
`PermissionGuidance` are enums and structs, not statics on a `View`. `ScheduleDraft` is the
schedule sheet's form as one value: whether Save is possible, which GUID it is aimed at and
the request it sends, where the sheet once held each field as its own `@State` and decided
all three privately. `SettingRow` holds ONE
`SettingRowState` and asks it what to commit, what to keep and what to follow; its controls
are views of their own (`SettingControls.swift`) handed a binding and a commit. `SendLaterGuidance` is the sentence set the
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

`Tests/BlueBubblesAppTests/`: `AccessibilityPolicyTests`, `FrontEndPlumbingPolicyTests`,
`ServerLifecycleTests`, `IntegrationCatalogTests`,
`ConnectionMethodChoicesTests`, `OnboardingFlowTests`, `LaunchOptionsTests`,
`PushSelfHealTests`, `SendLaterGuidanceTests`, `UpdaterPolicyTests`, `InstallWindowTests`,
`WhatsNewTests`, `ScheduledMessageRowTests`, `ServiceFormLayoutTests`, `LogFilteringTests`,
`LogDocumentUpdateTests`, `NotificationDeliveryRoutingTests`, `BlockedClientSummaryTests`,
`ChatPickerNavigationTests`, `SettingRowStateTests`,
`WebhookDeliverySummaryTests`, `DeviceRowSummaryTests`, `HTTPListenerSummaryTests`,
`APIDocsRelayPolicyTests`, `PermissionGuidanceTests`, `SubscriptionPolicyTests`,
`ServiceStatusSummaryTests`, `FirebaseSetupPromptTests`, `SharedComponentPolicyTests`,
`ListPagePolicyTests`, `PageCursorTests`, `ScheduleDraftTests`, `IntegrationsModelTests`,
`SettingsModelTests`, `BindingShapesTests`, `SecretFieldPolicyTests` (in
`SettingRowStateTests.swift`), `ViewPlumbingPolicyTests`, `DesignTokenPolicyTests`,
`AppBehaviourPolicyTests`, `IntegrationsListingTests`, `AppCapabilityTests`,
`PresentationRulesTests`, `SearchDraftTests`, `PreferenceWriterTests`. The
setting-dependency declarations are asserted from `BBSettingsTests/SettingDependencyTests`.
`CompositionTests` does not link this target, so a suite naming an app type goes in
`BlueBubblesAppTests`.
