//  WebhookEventCatalog
//  Which events a webhook can subscribe to, and what to call them on screen.
//
//  The Electron settings window let you register an endpoint for a chosen set of events; this
//  app registered every endpoint for `["*"]` and offered no way to say otherwise, even though
//  the column, the matching in `WebhookSink`, and the `events` field on the create route were
//  all there the whole time. So this is the missing vocabulary rather than a missing feature.
//
//  Off the view for the same reason `IntegrationCatalog` is: touching a SwiftUI `View` type
//  from a test process traps, and the failure this needs a test for is drift — an event added
//  to `EventName.webhookSubscribable` with no label here would simply not be offered, silently,
//  and nobody would notice until someone went looking for a subscription that was never listed.
//
//  Values are the WIRE names and are frozen — they are what is stored in the `events` column
//  and what `WebhookTarget.matches` compares against. Labels are carried over verbatim from the
//  Electron picker, including `imessage-alias-removed` being singular while the event emitted
//  is plural: a webhook registered through the old UI holds the singular string, and renaming
//  it here would quietly unsubscribe it.
//
//  See `.claude/docs/architecture.md`.

import BBEvents

enum WebhookEventCatalog {

  /// The wildcard subscription. Stored as the single entry `["*"]`.
  static let allEvents = "*"

  struct Event: Identifiable, Hashable, Sendable {
    let value: String
    let label: String
    var id: String { value }

    init(_ name: EventName, _ label: String) {
      self.value = name.rawValue
      self.label = label
    }
  }

  /// A heading in the picker. Twenty-five checkboxes in one column is a list nobody reads to
  /// the end of, and the groups are how someone finds the three they came for.
  struct Group: Identifiable, Sendable {
    let title: String
    let events: [Event]
    var id: String { title }
  }

  static let groups: [Group] = [
    Group(
      title: "Messages",
      events: [
        Event(.newMessage, "New Messages"),
        Event(.updatedMessage, "Message Updates"),
        Event(.messageSendError, "Message Send Errors"),
        Event(.typingIndicator, "Typing Indicators"),
        Event(.chatReadStatusChanged, "Chat Read Status Change"),
        Event(.scheduledMessageError, "Scheduled Message Errors"),
      ]),
    Group(
      title: "Groups",
      events: [
        Event(.groupNameChange, "Group Name Changes"),
        Event(.groupIconChanged, "Group Icon Changes"),
        Event(.groupIconRemoved, "Group Icon Removal"),
        Event(.participantAdded, "Participant Added"),
        Event(.participantRemoved, "Participant Removed"),
        Event(.participantLeft, "Participant Left"),
      ]),
    Group(
      title: "Calls & location",
      events: [
        Event(.incomingFaceTime, "Incoming FaceTime Call"),
        Event(.faceTimeCallStatusChanged, "FaceTime Call Status Changed (Experimental)"),
        Event(.newFindMyLocation, "FindMy Location Update"),
      ]),
    Group(
      title: "Server",
      events: [
        Event(.serverUpdate, "Server Update"),
        Event(.newServer, "New Server URL"),
        Event(.helloWorld, "Websocket Hello World"),
        // Singular on purpose — see the file comment.
        Event(EventName("imessage-alias-removed"), "iMessage Alias Removed"),
      ]),
    Group(
      title: "Backups",
      events: [
        Event(.themeBackupCreated, "Theme Backup Created"),
        Event(.themeBackupUpdated, "Theme Backup Updated"),
        Event(.themeBackupDeleted, "Theme Backup Deleted"),
        Event(.settingsBackupCreated, "Settings Backup Created"),
        Event(.settingsBackupUpdated, "Settings Backup Updated"),
        Event(.settingsBackupDeleted, "Settings Backup Deleted"),
      ]),
  ]

  static var all: [Event] { groups.flatMap(\.events) }

  static func label(for value: String) -> String {
    if value == allEvents { return "All Events" }
    // Falls back to the raw name rather than to "Unknown". A webhook registered over the
    // API can carry an event this picker does not offer, and the row that shows it is the
    // only place anyone would find that out.
    return all.first { $0.value == value }?.label ?? value
  }

  /// What a webhook's subscription reads as in a list.
  static func summary(for values: [String]) -> String {
    if values.isEmpty || values.contains(allEvents) { return "All events" }
    return values.map(label(for:)).joined(separator: ", ")
  }
}

/// A subscription being edited: "everything", or a chosen set.
///
/// A value type rather than state on the picker view, for two reasons. The intermediate state
/// is real — someone switches to "Only selected" and has ticked nothing yet, which is not the
/// same as "everything" and must be representable long enough to be refused. And the round
/// trip through the stored wire form is the part that can silently go wrong, so it has to be
/// reachable from a test; touching a SwiftUI `View` type from a test process traps.
struct EventSubscription: Equatable, Sendable {

  /// The wildcard. Picks up events added in later server versions, which ticking every box
  /// does not — the reason the two are different rows rather than the same one.
  var isAllEvents: Bool
  var selected: Set<String>

  init(isAllEvents: Bool = true, selected: Set<String> = []) {
    self.isAllEvents = isAllEvents
    self.selected = selected
  }

  /// Reads a stored subscription.
  ///
  /// An empty list means everything, matching what the server stores for a webhook created
  /// with no `events` field — and what `WebhookTarget` treats a missing subscription as.
  init(wireValues: [String]) {
    let values = wireValues.filter { !$0.isEmpty }
    if values.isEmpty || values.contains(WebhookEventCatalog.allEvents) {
      self.init(isAllEvents: true, selected: [])
    } else {
      // Unrecognised names are KEPT. A subscription registered over the API can carry an
      // event this picker does not offer, and dropping it here would silently
      // unsubscribe that endpoint the moment someone opened it to change something else.
      self.init(isAllEvents: false, selected: Set(values))
    }
  }

  /// Sorted so the stored array has a stable order, and two endpoints subscribed to the same
  /// things read identically in a list.
  var wireValues: [String] {
    isAllEvents ? [WebhookEventCatalog.allEvents] : selected.sorted()
  }

  /// Whether this is safe to save. "Only selected" with nothing selected is an endpoint that
  /// is registered and never called, which is the one state worth refusing.
  var isValid: Bool { isAllEvents || !selected.isEmpty }

  var summary: String { WebhookEventCatalog.summary(for: wireValues) }

  /// The comma-separated form, for the settings that store one in a single string.
  var settingValue: String { wireValues.joined(separator: ",") }

  /// Reads a subscription stored as one setting string.
  ///
  /// Empty means NOTHING here, which is the opposite of what an empty `wireValues` means —
  /// and the difference is not an oversight. An absent or empty JSON `events` array is a
  /// webhook that never specified a subscription, and the server resolves that to `["*"]`.
  /// A setting declared with a default of `*` that now holds an empty string is somebody
  /// having taken everything out of it, which is exactly what the composition honours by
  /// not registering the sink at all.
  ///
  /// It also has to round trip. This state is reachable from the picker — one click on
  /// "Only selected" before any box is ticked — and a settings row rewrites itself from the
  /// stored string after every save, so a state that cannot survive the round trip snaps
  /// back the instant it is chosen.
  init(settingValue: String) {
    let values =
      settingValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    if values.isEmpty {
      self.init(isAllEvents: false, selected: [])
    } else {
      self.init(wireValues: values)
    }
  }
}
