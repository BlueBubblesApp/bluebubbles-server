//  WebhookEventCatalogTests
//  That the webhook picker offers exactly what a webhook can subscribe to.
//
//  The failure this exists for is silent in both directions. An event added to
//  `EventName.webhookSubscribable` with no entry in the catalog is simply never offered, so
//  the feature ships without the one event someone wanted; an entry whose value no longer
//  matches an emitted event produces a subscription that matches nothing, and a webhook that
//  is registered, listed, and never called.
//
//  Neither shows up as a build failure, and neither shows up in a screenshot.

import BBEvents
import Testing

@testable import BlueBubblesApp

@Suite("Webhook event catalog")
struct WebhookEventCatalogTests {

  @Test("every subscribable event is offered in the picker")
  func coversEverySubscribableEvent() {
    let offered = Set(WebhookEventCatalog.all.map(\.value))
    for event in EventName.webhookSubscribable {
      #expect(
        offered.contains(event.rawValue),
        "\(event.rawValue) can be subscribed to but is not in WebhookEventCatalog"
      )
    }
  }

  @Test("the picker offers nothing that cannot be subscribed to")
  func offersNothingExtra() {
    let subscribable = Set(EventName.webhookSubscribable.map(\.rawValue))
    for event in WebhookEventCatalog.all {
      #expect(
        subscribable.contains(event.value),
        "\(event.value) is offered in the picker but is not a subscribable event"
      )
    }
  }

  @Test("each event appears in exactly one group, with a label")
  func groupsPartitionTheEvents() {
    var seen: Set<String> = []
    for group in WebhookEventCatalog.groups {
      #expect(!group.events.isEmpty)
      for event in group.events {
        #expect(seen.insert(event.value).inserted, "\(event.value) is in two groups")
        #expect(!event.label.isEmpty)
        // The label is what someone reads; the value is what gets stored. A label
        // that IS the wire name means somebody pasted the value into both fields.
        #expect(event.label != event.value)
      }
    }
  }

  @Test("the wildcard is not one of the checkboxes")
  func wildcardIsNotAnEvent() {
    // "*" is the other half of a choice, not one more box to tick — the two rows behave
    // differently as the server adds events, and a picker that offered both would let
    // someone build `["*", "new-message"]`, which means "everything" while reading as
    // "just new messages".
    #expect(!WebhookEventCatalog.all.contains { $0.value == WebhookEventCatalog.allEvents })
  }

  @Test("subscriptions read as a sentence")
  func summarisesSubscriptions() {
    #expect(WebhookEventCatalog.summary(for: ["*"]) == "All events")
    // An empty list means everything, matching what the server stores for a webhook
    // created with no `events` field.
    #expect(WebhookEventCatalog.summary(for: []) == "All events")
    #expect(WebhookEventCatalog.summary(for: ["new-message"]) == "New Messages")
    #expect(
      WebhookEventCatalog.summary(for: ["new-message", "typing-indicator"])
        == "New Messages, Typing Indicators"
    )
    // Registered over the API with something the picker does not offer. It has to show
    // as itself: this row is the only place anyone would find out it is subscribed.
    #expect(WebhookEventCatalog.summary(for: ["some-future-event"]) == "some-future-event")
  }

  @Test("the singular alias the picker offers still matches the plural event")
  func aliasSurvives() {
    // The picker offers `imessage-alias-removed`; the event emitted is
    // `imessage-aliases-removed`. Matching runs through `webhookAliases`, and a webhook
    // subscribed through this picker is dead if that link is ever broken.
    let offered = WebhookEventCatalog.all.first { $0.value.hasPrefix("imessage-alias") }
    #expect(offered != nil)
    #expect(
      EventName.iMessageAliasesRemoved.webhookAliases.contains(offered?.value ?? "")
    )
  }
}

@Suite("Event subscriptions")
struct EventSubscriptionTests {

  @Test("The wildcard round trips")
  func wildcard() {
    let subscription = EventSubscription(wireValues: ["*"])
    #expect(subscription.isAllEvents)
    #expect(subscription.wireValues == ["*"])
    #expect(subscription.summary == "All events")
  }

  @Test("An empty stored list means everything")
  func emptyMeansAll() {
    // What the server stores for a webhook created with no `events` field, and what
    // `WebhookTarget` treats a missing subscription as. Reading it as "nothing" would
    // show every such webhook as subscribed to nothing.
    #expect(EventSubscription(wireValues: []).isAllEvents)
  }

  @Test("An emptied setting string means nothing, and survives the round trip")
  func emptySettingMeansNothing() {
    // The opposite of an empty `wireValues`, deliberately: a setting declared with a
    // default of `*` that now holds "" is somebody having taken everything out of it,
    // and the composition honours that by not registering the sink.
    let emptied = EventSubscription(settingValue: "")
    #expect(!emptied.isAllEvents)
    #expect(emptied.selected.isEmpty)
    #expect(!emptied.isValid)

    // And it round trips. A settings row rewrites itself from the stored string after
    // every save, so the one click on "Only selected" before any box is ticked has to
    // survive being written and read back — otherwise the choice undoes itself on screen
    // and the checkboxes it was meant to reveal never appear.
    #expect(EventSubscription(settingValue: emptied.settingValue) == emptied)
  }

  @Test("Every subscription survives a setting round trip")
  func settingRoundTrip() {
    for subscription in [
      EventSubscription(isAllEvents: true, selected: []),
      EventSubscription(isAllEvents: false, selected: []),
      EventSubscription(isAllEvents: false, selected: ["new-message"]),
      EventSubscription(isAllEvents: false, selected: ["new-message", "typing-indicator"]),
    ] {
      #expect(EventSubscription(settingValue: subscription.settingValue) == subscription)
    }
  }

  @Test("A chosen set round trips in a stable order")
  func chosenSet() {
    let subscription = EventSubscription(wireValues: ["typing-indicator", "new-message"])
    #expect(!subscription.isAllEvents)
    // Sorted, so two endpoints subscribed to the same things store and read identically.
    #expect(subscription.wireValues == ["new-message", "typing-indicator"])
    #expect(subscription.settingValue == "new-message,typing-indicator")
  }

  @Test("An event the picker does not offer is kept")
  func keepsUnknownEvents() {
    // Registered over the API, or from a newer server. Dropping it here would silently
    // unsubscribe that endpoint the moment someone opened it to change something else.
    let subscription = EventSubscription(wireValues: ["some-future-event"])
    #expect(subscription.wireValues == ["some-future-event"])
  }

  @Test("The comma-separated setting form tolerates spacing")
  func settingParsing() {
    let subscription = EventSubscription(settingValue: " new-message , typing-indicator ,, ")
    #expect(subscription.selected == ["new-message", "typing-indicator"])
    #expect(subscription.settingValue == "new-message,typing-indicator")
  }

  @Test("Selecting nothing is not savable")
  func emptySelectionIsInvalid() {
    // The state someone passes through on the way to picking events. It has to be
    // representable — and refused — because a target subscribed to nothing is registered
    // and never delivered to, which looks identical to a broken one.
    var subscription = EventSubscription(wireValues: ["new-message"])
    #expect(subscription.isValid)
    subscription.selected.removeAll()
    #expect(!subscription.isValid)
    subscription.isAllEvents = true
    #expect(subscription.isValid)
  }
}
