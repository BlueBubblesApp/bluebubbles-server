# BlueBubblesApp

The SwiftUI application: the settings window, onboarding, and the menu bar. It hosts the
server; it does not reach into it.

This file is the rules. Each section ends with a link to the matching section of
[`.claude/docs/app.md`](../../.claude/docs/app.md), which holds the measurement, the failure or
the history behind the rule; read that before arguing with one. The wider picture is
[`.claude/docs/architecture.md`](../../.claude/docs/architecture.md).

## Reach the server through a facade, never `AppContext`

- `AppContext` is private to the composition root. A view reads state off `AppModel`; the model
  reaches server capabilities through the grouped facades in `ServerAccess.swift`
  (`model.security`, `model.messaging`, `model.delivery`, `model.subscription`,
  `model.monitoring`, `model.connection`), built only by `AppModel.swift`. No door returns the context, even typed
  as a protocol (`as? AppContext` recovers the container); a protocol-typed door returns a
  private forwarder (`PushSetup`). Only `settings`, `alertCenter`, `tools` and `serverAdmin`
  sit flat on the model; a new capability goes in a group. `FrontEndPlumbingPolicyTests`.
- **Settings have one door, `model.settings` (`Models/SettingsModel.swift`), and it is not an
  optional.** With no server every call THROWS `ServerNotRunning`, which `DiagnosticText`
  renders, so a write with no server never flips back silently. Its writes run as the
  operator, so a view does not wrap them in `asOperator`. `ViewPlumbingPolicyTests` refuses
  `SettingsStore`, `settingsStore` and `.changes()` under `Views/`.
- **A change the app makes to the server runs inside `asOperator`**
  (`OperatorAttribution.swift`): a settings write, an access-control change, a webhook or
  scheduled message, an import, a licence exchange. The app's own bookkeeping is
  `.system(component: "app")`. `OperatorAttributionPolicyTests` fails the build on a write that
  is neither.
- **State with its own lifetime is a child model in `Models/`**, each `ServerAttachable`, and
  **attach and teardown are one list** (`ServerAttachments.swift`): `attachments.attach(child)
  { $0.attach(…) }` records the detach in the same call, and `detachAll()` undoes every entry
  in reverse on every way out. `FrontEndPlumbingPolicyTests` refuses a child attached or
  detached by hand. `SparkleUpdater` is the one child that outlives the server, and
  `UpdaterPolicy` decides off the object whether it starts at all.

→ [app.md § Reach the server through a facade](../../.claude/docs/app.md#reach-the-server-through-a-facade-never-appcontext)

## The server starts from the delegate, because a window is not guaranteed

- `AppDelegate.applicationDidFinishLaunching` owns startup; `AppModel.beginStart` owns the
  attempt, and `start` is private, so no Start button, wizard or `restart` can begin a second
  attempt beside one in flight. A `Window` scene does not always open (`--headless --set k=v`
  leaves AppKit a leftover argument and no window), and a `.task` belongs to its view, which
  any user can close mid-start. `LaunchStartupOwnershipTests` refuses a scene that starts the
  server.
- **A quit asks `model.shutdownTarget`, never `model.server`.** `server` is nil until every
  service is up; `ShutdownTarget` holds the composition from the moment they begin.
  `ShutdownTargetTests`.

→ [app.md § The server starts from the delegate](../../.claude/docs/app.md#the-server-starts-from-the-delegate-because-a-window-is-not-guaranteed)

## There are two page shapes, and the difference is whether the content scrolls itself

- Nearly every page is a `SettingsPage`: a scroll view over cards, capped at
  `maximumContentWidth`. A page built around a `Table` is a `TablePage`, the same `PageFrame`
  without the scroll view, capped at `maximumTableWidth`; a table inside a scroll view has no
  height of its own.
- **`TablePage` paints the window background, and that is not decoration**: without it the
  detail column is a transparent hole that the glass card and the sidebar sample the desktop
  through.
- Glass follows the rule in `GlassSurface.swift`: **chrome samples, content does not.** The
  Contacts card is `ContentCard`, not `GlassCard`, because it fills the page.

→ [app.md § There are two page shapes](../../.claude/docs/app.md#there-are-two-page-shapes-and-the-difference-is-whether-the-content-scrolls-itself)

## The Contacts page reads a page at a time, and the database does the work

- Search, sort, filtering and counting are SQL (`ContactIndex.search`); the page holds one
  page of contacts. The search waits for typing to pause (`SearchDraft`, drawn by
  `PausedSearchField`); the card is `PagedTableCard`, shared with the Audit Log.
- Sorting belongs to the query; the total comes from the SAME read as the rows; and
  `PageCursor.clamp` runs on every change of total, because the set can shrink to one page
  while the `Pager` is off screen.
- The page is the ONLY caller passing `includeDisabled: true`: a switch you cannot see is a
  switch you cannot undo.
- **Delete Client Contacts removes `.local` rows only** (`ContactIndex.removeClientContacts`),
  behind a confirmation naming the count. The address book (iCloud, Google, On this Mac) is
  all `.macOS` and is never a candidate; Refresh can re-read it, nothing can re-read a client.

→ [app.md § The Contacts page reads a page at a time](../../.claude/docs/app.md#the-contacts-page-reads-a-page-at-a-time-and-the-database-does-the-work)

## ntfy is an integration, and "event sink" is not the same as "notification"

- ntfy is `BuiltInManifests.ntfy` + `NtfyDeliveryService`, configured by manifest fields in its
  own namespace. Its four old core keys are `isInternal`, read only by
  `NtfySettingsAdoption.run` (once, moving them across) and the in-use check; the
  declarations stay so no stored value is stranded.
- **ntfy ships switched OFF** (`BuiltInManifests.disabledByDefault`), seeded into
  `disabled_services` once rather than folded into `ServiceEnablement.isEnabled`; the seed
  skips an install already using it.
- `FieldKind.eventSubscription` exists because a `multiSelect` cannot express `*`.
- **The Notifications tab is `NotificationDeliverySection`**, listing what
  `NotificationDeliveryRouting` names (push and ntfy), not `manifests(in: .eventSink)`, which
  would put webhooks on a page about notifications.

→ [app.md § ntfy is an integration](../../.claude/docs/app.md#ntfy-is-an-integration-and-event-sink-is-not-the-same-as-notification)

## The devices page is Firebase's, and it shows push registrations

- Two device lists share nothing: `BBAppStore`'s `device` table (one row per FCM token, from
  `POST /api/v1/device`) and `BBAuth`'s `EnrolledDevice` registry (token-auth enrolment). The
  page is `FirebaseDevicesView`, a sub-page of `FirebaseDetail`, drawn only once there is a
  service account, because a token is issued BY a project.
- The list is FOLLOWED, not re-read on a timer (`DeviceObservation`);
  `Tests/BBInterfacesTests/PushDeviceStreamTests` pins that a registration and a removal each
  reach a follower. The enrolment list has no screen; `TokenAuthService.devices()` says why.

→ [app.md § The devices page is Firebase's](../../.claude/docs/app.md#the-devices-page-is-firebases-and-it-shows-push-registrations)

## Who opened the app decides what the app does to its own window

- macOS cannot tell a login from a double-click, so the launch agent says: its plist passes
  `LaunchAgentContract.automaticLaunchArgument`, `LaunchOptions.wasLaunchedAutomatically` reads
  it back (unless a person's copy handed over: `LaunchAgentContract.consumePersonHandover`), and
  `AppBehaviourPolicy` decides (`startDelay(_:isUnattended:)`,
  `shouldStartMinimized(configured:isUnattended:isHeadless:isAwaitingSetup:)`). A launch
  without the argument is a person. `isAwaitingSetup` is not optional: both setup sheets are
  modal on the main window.
- **The window minimises as soon as that can be answered, and comes back if it was wrong.**
  `AppModel.decideStartMinimised` runs after the migration gate;
  `AppBehaviourPolicy.mainWindowNeedsPerson` and `AppModel.reconcileMainWindow` (from the
  phase's `didSet` and both sheet models' `onPresentationChanged`, never a view) restore it;
  `StartMinimisedWindow` holds what the path has done so a window the person minimised stays
  minimised. Locking the screen and opening FindMy stay in `applyStartupBehaviour`, after
  `.running`, because neither can be undone.
- `StartupStage` names each step of a start, and `followServiceHealth` is attached BEFORE
  `built.start()` so the service in flight is named too.

→ [app.md § Who opened the app decides](../../.claude/docs/app.md#who-opened-the-app-decides-what-the-app-does-to-its-own-window)

## Live state is followed, never polled

- `serviceHealths`, `toolStatuses`, `privateAPIState`, `pushDevicesVersion`, `accessControl`
  and `clientAddress` are followed from the server's streams (`ServiceHealthObservation`,
  `ToolActions`, `PrivateAPIObservation`, `DeviceObservation`, `AccessControlObservation`,
  `AddressObservation`). A follow is a case on `ServerFollow`, started through
  `follow(_:subscribe:seed:apply:reset:)` (subscribes BEFORE its seed read) or
  `countChanges(_:of:atMostEvery:bump:)` in `ServerFollows.swift`, and registers what stopping
  it clears, so `stopFollowingServer` is one call over the `FollowTable`.
- **A stop waits for what it stops.** `FollowTable.stopAll` waits for every follow before it
  resets, and a child model's `detach` `await`s its `OwnedTask`'s `stop()`.
  `OwnedTaskPolicyTests` refuses a `detach` that only cancels.
- Followed state with a lifetime of its own is a child model: `model.webhooks`
  (`WebhooksModel`), `model.metrics` (`MetricsModel`), `model.logs` (`LogsModel`), each on its
  own `OwnedTask`, its followed values `private(set)`.
- **A view never polls and never subscribes on its own.** No `.task`/`.onDisappear` pairs with
  counters, no timers. The log page reads `logs.lines`, which `LogsModel` follows from
  `FileSink.follow(tail:)` while the page is showing; lines arrive as `LogLine` carrying their
  level, never parsed from text.
- Which services are on is `IntegrationsModel` (its `refresh` is private); settings are
  `SettingsModel`, read as `model.settings.version(of: keys)` or `version(inNamespace:)`, keyed
  into a `.task(id:)`. Read a version only for keys the view follows: reading is subscribing.
- **If something moves on the server without a stream, add the stream on the server**
  (`ServiceRegistry.healthChanges()`, `PrivateAPIRuntime.states()`,
  `WebhookDeliveryTracker.changes()`, `AccessControlService.changes()`, `AppDatabase.observe`
  are the pattern). Do not add a timer. A value that lapses on the clock is the server's to
  announce (`AccessControlService.scheduleExpiry`).

→ [app.md § Live state is followed, never polled](../../.claude/docs/app.md#live-state-is-followed-never-polled)

## A read that can fail shows that it failed

- A page whose content IS a server read composes a `ScreenModel` (`ScreenModel.swift`) and
  switches on its state. `(try? await …) ?? []` makes "refused" and "none" the same value.
- `try?` is allowed in exactly three shapes, each saying which in a comment: the failure is
  reported on another path (named); the value is a glance, not the content (Home's tiles);
  `try? await Task.sleep`. A settings write is never `try?`.
- **A read is keyed on the server phase, never a bare `.task`.** A page with a `ScreenModel`
  writes `.reloads(screen, following: model)`, adding `alsoOn:` for rows written by something
  other than the page; a page with its own read writes `.task(id: model.phase.isRunning)`.
  `ScreenReloadPolicyTests` refuses the bare form.

→ [app.md § A read that can fail shows that it failed](../../.claude/docs/app.md#a-read-that-can-fail-shows-that-it-failed)

## Home is a dashboard, and every summary on it is decided off the view

- What a card SAYS is `HomeDashboard`, tested in `HomeDashboardTests`. Live numbers arrive
  from `ServerMetrics` on the server; Home keeps no clock. One stream lands on three
  properties of `MetricsModel` moving at three rates (`snapshot`, `ring`,
  `newMessageMinute`); a section reads the slowest one that answers its question. Longer
  history is `model.monitoring`.
- **Two depths, and Basic is the default** (`HomeModel.Detail`, persisted as
  `Settings.homeDetail`); Advanced sections read `chat.db` only while on screen.
- **A visible change inside glass is a glass re-sample, whatever caused it** (measured at
  about 200 MB of graphics memory per repaint). A figure that moves on every sample is not
  drawn live; a relative age goes through `HomeDashboard.relative`, the app's ONE relative
  age, which `SharedComponentPolicyTests` enforces module-wide. A `ProgressView()` spinner is
  exempt: it is its own layer.
- **Nothing in a body reads `.now`.** Clock readings go through `HomeDashboard.minute`,
  placeholders are built once (`Glance.sample`, `HomeActivity.sample`,
  `HomeServerHistory.sample`), and every chart is its own `Equatable` view under
  `.equatable()`.
- **What Home has read lives on `HomeModel`, not in `@State`, and a visit reads only what is
  stale**: per card (`Glance.Card`, `Visit.key(for:)`, `ReadFreshness`,
  `HomeModel.maximumAge`), through `ScreenModel.reload(for:unlessFresherThan:)`. The age is
  measured when the person arrives, never on a schedule. `ScreenModelTests`,
  `ReadFreshnessTests`.
- **A first read is a skeleton of the card, and each card reveals on its own**
  (`Skeleton`, `Glance.hasArrived`). A failed read draws `-`; a Refresh never re-skeletons a
  value on screen. Placeholders live on the data types and take `now`; `HomePlaceholderTests`
  pins that the skeleton is the loaded height. Charts take `chartFrame(height:)`.

→ [app.md § Home is a dashboard](../../.claude/docs/app.md#home-is-a-dashboard-and-every-summary-on-it-is-decided-off-the-view)

## Views

Each rule names the component or the decision type, and the test that holds it. The reasons,
the measurements and what each shape replaced are in
[app.md § Views](../../.claude/docs/app.md#views).

- **No `AnyView`.** A slot takes a generic parameter with a `@ViewBuilder` initialiser and an
  `EmptyView` default (`SettingsSection(_:subtitle:content:trailing:)` in `SettingsLayout.swift`).
- **Rows are identified by the model's id, never by offset.** No `ForEach(…, id: \.offset)`.
- **A selection that has to span rows is one text view**: the log viewer is `LogTextView`, one
  `NSTextView`, edited through `LogDocumentUpdate` rather than rebuilt.
- **A bespoke settings control is a `CustomSettingControl` case**, switched exhaustively in
  `SettingRow.custom`; `CustomSettingControlTests` holds the cases and the registry together.
- **A row whose switch is off is greyed out by its declaration** (`SettingPresentation.requires`),
  FOLLOWING that key through `model.settings.version(of:)`; `Settings.blockingRequirement`
  names the outermost switch that is off.
- **A setting drawn by a bespoke screen is marked `isInternal`, and the screen declares its
  list off the view** (`HTTPSettingsPanel`, `HTTPSettingsPanelTests`); its rows are `SettingRow`.
- **A state's colour is a `StatusTone` (`StatusTone.swift`)**: `.informational`, `.good`,
  `.attention`, `.problem`. The rule that answers with one lives off the view
  (`ServerPhase.tone`, `AuditRowSummary.tone`). `SharedComponentPolicyTests` refuses `.red`,
  `.orange`, `.green` and `.yellow` under `Views/` outside a chart.
- **A symbol over an explanation is `NoticeCard`**, its colour a `StatusTone`,
  `.informational` by default; `NoticeBody` where the caller owns the container.
- **Shared views live in `Views/Components/`**, measured in `SettingsMetrics.swift`: `Tag`,
  `StatCard`, `StatusDot`, `GlassCard`, `TitledCard`, `CopyableValue`, `SheetScaffold`,
  `ConfigureSheet`, `FloatingBar`, `NoticeCard`, `LoadingNotice`, `Skeleton`, `ManifestRow`,
  `ServiceStatusLine`, `DropZone`, `ListPage`, `PagedTableCard`, `SearchField`,
  `PausedSearchField`, `Pager`, `SecretField`, `SectionEmptyText`, `ToolbarCaption`,
  `ErrorLine`, `ActionOutcomeLine`, `DividedForEach`, `ServerAddressRow`, `HomeChartSection`.
- **A service's status line is `ServiceStatusLine`**, its words `ServiceStatusSummary`'s.
- **A row that names an integration is `ManifestRow`**; the caller owns what pressing it does.
- **A file drop target is `DropZone`, and it always has a Choose button**; a whole page that
  accepts drops uses `acceptsFileDrop`. `SharedComponentPolicyTests` refuses `isProblem`, a
  `chevron.right` image and `.onDrop(` outside the component that owns each.
- **A glass card that opens with a headline is `TitledCard`**, spaced by
  `SettingsMetrics.cardStackSpacing`.
- **A failure said in one line is `ErrorLine`**; what a one-off button did is an
  `ActionOutcome` drawn by `ActionOutcomeLine`; a settings row's note is `SettingsFootnote`.
- **The address a person types into a client is `ServerAddressRow`**; `ClientAddress.forThisMac`
  is only for a request made from this Mac.
- **Rows divided by a line are `DividedForEach`; a tick box over a set is
  `Binding(contains:in:)`.**
- **A section with nothing in it says so with `SectionEmptyText`**; a whole empty page is a
  `ContentUnavailableView` or the `ListPage` empty slot. `SharedComponentPolicyTests` refuses a
  hand-written `Text("No …")` elsewhere under `Views/`.
- **A measurement is a token from `SettingsMetrics.swift`** (`cardCornerRadius`,
  `tileCornerRadius`, `fieldCornerRadius`, `rowCornerRadius`, `iconColumnWidth`,
  `cardStackSpacing`); a one-off geometry is a named constant in its control's file.
  `DesignTokenPolicyTests`.
- **A copy to the clipboard is `Pasteboard.copy(_:)`.** `SharedComponentPolicyTests` refuses
  `NSPasteboard` anywhere else.
- **A case is identity; its title is a computed property** (`Destination`, `SettingsTab`,
  `SettingSection`, `ScheduleRecurrence`, `LogLevelFilter`, `ScheduleDraft.Recipient`). A
  status read off a record goes through its enum (`ScheduledMessageStatus(rawValue:)`); a
  wire value lives on its own property with a comment naming the contract
  (`Repeats.intervalType`). `SettingsTabTests` proves every section is placed exactly once.
- **A destructive action confirms when it destroys something a person made; it is one click
  when it undoes the server's own bookkeeping.** While a mutation is in flight the button is
  disabled (`screen.isPerforming`).
- **A switch shows its new position while the write is in flight**:
  `Binding.optimistic(current, pending:, write:)` (`OptimisticWrite.swift`), with `asksFirst:`
  for one that confirms. Text fields are the exception: a rejected password must not look saved.
- **A dialog presented over an optional is `.isPresent($optional)`** (`Binding+Presence.swift`).
  `ViewPlumbingPolicyTests` refuses a hand-built presence binding.
- **A sheet is `SheetScaffold`**, with `SheetCancel` and `scrollsContent:` as parameters; a
  service's form in a sheet is `ConfigureSheet`. **Sheets declare a `SheetSize`, never a fixed
  one** (`SheetScaffold(size:)`, `.sheetFrame(_:)`); the main window's minimum height is the
  tallest sheet's.
- **⌘, opens Settings and ⌘1 to ⌘9 walk the sidebar** (`NavigationMenuItem`); a menu item that
  navigates opens the main window first.
- **An empty state is not shown while the read is still running.** `ScreenState` keeps `idle`
  and `loading` apart; a list page hands its screen to `ListPage`; a dashboard card is a
  `Skeleton`, one view, never pulsing. `ScreenLoadingStatePolicyTests`.
- **The branching that decides which state to draw is CLOSED**: decide off the view and
  `switch` on it (`SubscriptionPolicy.Page`, `ListPagePolicy.state`). An `else if` chain with
  no `else` renders nothing in the state it forgot, and takes its `.reloads` task with it.
- **A page does not write its own "server not running" state.** `ServerStoppedNotice`, with
  its words from `ServerAvailability.swift`; `FeatureDisabledNotice` is the sibling for a
  switched-off feature, with a required placement. `ServerStoppedNoticeTests`.
- **A control a person can press has a name.** `AccessibilityPolicyTests`; see the root
  `CLAUDE.md`.
- **A count and its noun go through `Int.counted(_:)`.**
- **A footnote's identity is its `Kind`, not its text** (`SettingsFootnote`).
- **A secret is read when somebody asks for it, never when the screen appears.** `SettingRow`
  and `ServiceFormView` ask `model.settings.presence(…)` and draw `SecretField`, whose eye
  LOADS through `reveal` and whose hiding calls `forget`; `SecretFieldPolicy` decides its
  words. "The Keychain refused" is asked for (`model.settings.isUnreadable(_:)`), never
  inferred from an empty read.
- **Nothing writes a setting on the way out.** A row leaving with an edit keeps it
  (`model.settings.keepDraft(_:typedOver:for:)`); a sheet's Done commits before it closes
  (`ServiceFormView.commitRequest`). `ViewPlumbingPolicyTests` refuses a commit or write in
  `.onDisappear`.
- **Error text goes through `DiagnosticText.sentence(for:)`.** Never `String(describing:)`.
- **A service's form is built from the settings row's controls (`SettingControls.swift`)** and
  follows its namespace (`version(inNamespace:)`); a number outside its range is refused under
  the field (`ServiceFormLayout.rangeFailure`), never clamped.
- **A preference written from a `didSet` goes through a `PreferenceWriter`**, one write at a
  time; a read-modify-write over a shared list (`IntegrationsModel.toggle`) starts from what
  the switches already say.

## Setup asks for what is missing, and only that

- **The password is kept, not re-asked.** `OnboardingView.hasStoredPassword` asks
  `model.settings.secret` for `isEmpty`, deliberately not `presence(ofSecretKey:)`: a secret
  stored as the empty string is present and lets nobody in.
- **Contacts is asked for when somebody presses its button**; setup finishing with it
  unanswered raises the notice (`RunningServer.setupFinished`).
- **A connection method with no program blocks, with a tick box**, acknowledged rather than
  hard-blocked; `OnboardingAnchor.requiredProgram` is where the view scrolls.
- **What a connection method still needs is one answer, `ConnectionMethodNeeds`**, through
  `model.connectionNeeds(of:)`, drawn once by `ConnectionMethodSteps`.
  `SharedComponentPolicyTests` refuses a view reading the steps or `tools.first` itself.
- **Nothing on the connection step is a dead button**: with no server the method chooser is a
  `ServerStoppedNotice`.

→ [app.md § Setup asks for what is missing](../../.claude/docs/app.md#setup-asks-for-what-is-missing-and-only-that)

## The reference window is the only page in this app that can ask for a request

`APIDocsView` embeds Scalar with `connect-src 'none'`; the client's `customFetch` posts to
`APIDocsRelay` over a script-message port and the APP makes the call, under `APIDocsRelayPolicy`.
Anything else that renders remote-ish content goes through the same shape.
→ [app.md § The reference window](../../.claude/docs/app.md#the-reference-window-is-the-only-page-in-this-app-that-can-ask-for-a-request)

## Manifests come from the catalog

Every manifest lookup goes through `IntegrationCatalog` (`manifest(_:)`, `connectionMethods`,
`manifests(in:)`, `manifestDeclaring(tool:)`), which reads the built-in list on ONE private
line. A glyph is `manifest.symbol`. `IntegrationCatalogTests` refuses a second lookup.
→ [app.md § Manifests come from the catalog](../../.claude/docs/app.md#manifests-come-from-the-catalog)

## Being listed and having a switch are two questions

`isUserManageable` answers the second; `IntegrationCatalog.isListed` is that or having a
`settingControl`, and a service with one draws that setting's `SettingRow` instead of a switch.
`BuiltInManifests.alwaysOn` keeps `disabled_services` from being a second state by hand;
`IntegrationsListingTests` holds the two lists together. What a service is doing is
`model.statusLine(for:)`, one door for the row and the page; a grant does not need Try Again
(see "How a grant reaches a service" in
[`architecture.md`](../../.claude/docs/architecture.md)).
→ [app.md § Being listed and having a switch](../../.claude/docs/app.md#being-listed-and-having-a-switch-are-two-questions)

## Policy lives off the view

Touching a SwiftUI `View` type from a test process traps, so a decision that deserves a test
cannot live on the view that uses it. Decisions are enums and structs (`IntegrationCatalog`,
`ConnectionMethodNeeds`, `AppBehaviourPolicy`, `ScheduleDraft`, `SettingRowState`,
`ListPagePolicy`, `SecretFieldPolicy`, `OptimisticWrite` and the rest; the list is in app.md).
If you find yourself writing a `static func` on a view that decides something, move it.

- **Three shapes hide a decision from a test**: a `private func` on the view; a type NESTED
  in a view (`LogLevelFilter` once sat inside `LogsView`); and a rule that MUTATES `@State`
  rather than answering (`ChatPickerNavigation.selection(movedBy:in:from:)` returns the
  answer and the view writes it).
- **A rule that reads the clock takes `now` as a parameter** (`BlockedClientSummary`,
  `ScheduledMessageRow.when`).
- **A note value that is a `View` carries main-actor isolation with it**; `SettingRowStateTests`
  and `ServiceFormLayoutTests` are `@MainActor` for that reason alone. The answer to a rule
  constrained by this is a plain note value, never `@MainActor` on the rule.

→ [app.md § Policy lives off the view](../../.claude/docs/app.md#policy-lives-off-the-view)

## Tests that will catch you

`Tests/BlueBubblesAppTests/`: `ServerLifecycleTests`, `IntegrationCatalogTests`,
`ConnectionMethodChoicesTests`, `ConnectionMethodNeedsTests`, `OnboardingFlowTests`,
`LaunchOptionsTests`,
`PushSelfHealTests`, `SendLaterGuidanceTests`, `UpdaterPolicyTests`, `InstallWindowTests`,
`WhatsNewTests`, `ScheduledMessageRowTests`, `ServiceFormLayoutTests`, `LogFilteringTests`,
`LogDocumentUpdateTests`, `NotificationDeliveryRoutingTests`, `BlockedClientSummaryTests`,
`ChatPickerNavigationTests`, `SettingRowStateTests`,
`WebhookDeliverySummaryTests`, `DeviceRowSummaryTests`, `HTTPListenerSummaryTests`,
`APIDocsRelayPolicyTests`, `PermissionGuidanceTests`, `SubscriptionPolicyTests`,
`ServiceStatusSummaryTests`, `FirebaseSetupPromptTests`,
`ListPagePolicyTests`, `PageCursorTests`, `ScheduleDraftTests`, `IntegrationsModelTests`,
`SettingsModelTests`, `BindingShapesTests`, `SecretFieldPolicyTests` (in
`SettingRowStateTests.swift`),
`AppBehaviourPolicyTests`, `StartMinimisedWindowTests`, `IntegrationsListingTests`,
`AppCapabilityTests`, `PresentationRulesTests`, `PrivateAPIPrerequisiteTests`,
`SearchDraftTests`, `PreferenceWriterTests`, `ToolButtonsTests`, `TailscaleHandoffTests`. The
setting-dependency declarations are asserted from `BBSettingsTests/SettingDependencyTests`.
`CompositionTests` does not link this target, so a suite naming an app type goes in
`BlueBubblesAppTests`. The scans that read this module's source as text are in
`Tests/SourcePolicyTests/`: `AccessibilityPolicyTests`, `FrontEndPlumbingPolicyTests`,
`SharedComponentPolicyTests`, `ViewPlumbingPolicyTests`, `DesignTokenPolicyTests`,
`ScreenLoadingStatePolicyTests`, `ScreenReloadPolicyTests` and `OperatorAttributionPolicyTests`.
