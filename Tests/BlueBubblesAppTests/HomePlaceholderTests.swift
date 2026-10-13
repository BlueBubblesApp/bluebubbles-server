//  HomePlaceholderTests
//  What a Home skeleton is drawn from, and when a card is one.
//
//  A skeleton is only as good as its placeholder: a placeholder missing the rows a card adds
//  once a value is present is a skeleton of the wrong height, and the reveal jumps, which is
//  the snap this whole shape exists to remove. The decision of whether a card is loading is
//  off the view for the same reason every Home decision is: so it can be stated here.

import BBAppStore
import BBInterfaces
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Home placeholders")
@MainActor
struct HomePlaceholderTests {

  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  // MARK: - Glance

  @Test("An empty glance has arrived for no card")
  func emptyGlanceHasNothing() {
    let glance = HomeModel.Glance()
    for card in HomeModel.Glance.Card.allCases {
      #expect(!glance.hasArrived(card), "\(card) reported arrived with nothing read")
    }
  }

  @Test("The glance placeholder has every row a card can add")
  func glancePlaceholderIsComplete() {
    let glance = HomeModel.Glance.placeholder(now: now)
    for card in HomeModel.Glance.Card.allCases {
      #expect(glance.hasArrived(card), "\(card) placeholder is missing a value")
    }
    // The rows Library and Delivery only draw once these are present.
    #expect(glance.media != nil)
    #expect((glance.chats?.breakdown.count ?? 0) >= 2, "one row per service, at least two")
    #expect(glance.push?.mostRecent != nil, "the last-active row needs a most recent device")
    #expect((glance.totals?.messages ?? 0) > 0, "redacted text is as wide as the text it hides")
  }

  /// A card reveals when ITS values are in, not when the page's slowest read is.
  @Test("A card has arrived only when everything it draws has")
  func arrivalIsPerCard() {
    var glance = HomeModel.Glance()
    glance.push = HomeDashboard.PushSummary(devices: 1)
    #expect(!glance.hasArrived(.delivery), "Delivery also draws the webhook count")
    glance.webhooksRegistered = 0
    #expect(glance.hasArrived(.delivery))
    #expect(!glance.hasArrived(.schedule))
    #expect(!glance.hasArrived(.library))

    glance.totals = AdminInterface.Totals(handles: 1, messages: 1, chats: 1, attachments: 1)
    glance.media = HomeDashboard.MediaBreakdown()
    #expect(!glance.hasArrived(.library), "Library also draws the per-service rows")
    glance.chats = ChatInterface.ChatCounts(breakdown: [:])
    #expect(glance.hasArrived(.library))
  }

  @Test("Nothing is loading before a read, or after a clear")
  func nothingLoadsWithoutARead() {
    let model = HomeModel()
    for card in HomeModel.Glance.Card.allCases {
      #expect(!model.isLoading(card))
    }
    model.clear()
    for card in HomeModel.Glance.Card.allCases {
      #expect(!model.isLoading(card))
    }
  }

  /// A device registering used to re-count every message in `chat.db`, because the glance
  /// had one key. Now only the card that draws devices follows their version.
  @Test("A device or webhook version moves the Delivery key and no other")
  func visitKeysArePerCard() {
    let before = HomeModel.Visit(phase: .running, pushDevices: 1, webhooks: 1)
    let after = HomeModel.Visit(phase: .running, pushDevices: 2, webhooks: 1)
    #expect(before.key(for: .delivery) != after.key(for: .delivery))
    #expect(before.key(for: .library) == after.key(for: .library))
    #expect(before.key(for: .schedule) == after.key(for: .schedule))

    // The phase moves every card.
    let stopped = HomeModel.Visit(phase: .idle, pushDevices: 1, webhooks: 1)
    for card in HomeModel.Glance.Card.allCases {
      #expect(before.key(for: card) != stopped.key(for: card))
    }
  }

  // MARK: - Activity

  @Test("The activity placeholder fills every part of the section")
  func activityPlaceholderIsComplete() {
    let activity = HomeActivity.placeholder(now: now)
    #expect(activity.flow.days.count >= 14, "today needs the same weekday a week earlier")
    #expect(activity.flow.heatmap.count == 7)
    #expect(activity.flow.heatmap.allSatisfy { $0.count == 24 })
    #expect(activity.chats.count == 5)
    #expect(activity.newChats.count == 5)
    #expect(HomeDashboard.today(activity.flow) != nil)
    #expect(HomeDashboard.busiestDay(activity.flow, range: .week) != nil)
    #expect(!activity.flow.byService.isEmpty, "the service breakdown row only draws when present")
  }

  // MARK: - Server history

  @Test("The history placeholder has a series per charted metric and a span per subject")
  func historyPlaceholderIsComplete() {
    let history = HomeServerHistory.placeholder(now: now)
    let charted: [MetricKey] = [
      .requests, .requestErrors, .socketClients, .events, .memoryMegabytes, .cpuPercent,
    ]
    for key in charted {
      #expect(!(history.series[key] ?? []).isEmpty, "\(key) has no points to draw")
    }
    for subject in AvailabilitySubject.allCases {
      #expect(history.spans.contains { $0.subject == subject }, "\(subject) has no span")
    }
  }
}
