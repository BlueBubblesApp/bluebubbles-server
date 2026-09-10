//  AlertActionWiringTests
//  An alert's remedy is reachable, not just declared.
//
//  Two call sites populate `AlertAction`: a rate-limit block carries `.unblock(address:)`,
//  a failing webhook carries `.openSettings`. Both have to reach a view that renders them,
//  or the remedy is unreachable: a user locked out by the throttle is told to visit the
//  Security page and given no way to get there.
//
//  Producers are asserted here rather than the SwiftUI view, because the view is not testable
//  without a host and the half that kept breaking is "does anything produce/consume this at
//  all". `NotificationsView.perform` switches over `AlertAction` exhaustively with no
//  `default`, so a new case fails to compile there rather than rendering a dead button.
//
//  See `docs/AUTH.md`.

import BBAuth
import BBCore
import BBDiagnostics
import BBSettings
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Alert action wiring")
struct AlertActionWiringTests {

  /// Collects what was raised, so a test can assert on the actions rather than the text.
  private actor Collector: AlertRaising {
    private(set) var alerts: [UserAlert] = []
    func raise(_ alert: UserAlert) async { alerts.append(alert) }
    func raise(_ error: any BBError, actions: [AlertAction]) async {}
  }

  @Test("A blocked client's alert carries a one-click unblock for that address")
  func blockAlertCarriesUnblock() async throws {
    // An alert that only said "go to Security" would still leave the user to find the
    // address in a list they have never seen.
    let collector = Collector()
    let control = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 2),
      alerts: collector
    )

    let address = "198.51.100.7"
    for _ in 0..<3 {
      _ = await control.recordFailure(
        .address(address), path: "/api/v1/ping", reason: "bad password"
      )
    }

    let alerts = await collector.alerts
    let blockAlert = try #require(
      alerts.first { alert in
        alert.actions.contains { if case .unblock = $0 { return true } else { return false } }
      },
      "a block must offer to undo itself; raised: \(alerts.map(\.title))"
    )

    // The address has to be IN the action: a bare "unblock" button cannot know which
    // client to lift, and the alert is the only place that context exists.
    #expect(blockAlert.actions.contains(.unblock(address: address)))
    // And the page too, for a user who wants to see the whole list.
    #expect(blockAlert.actions.contains(.openSettings(.security)))
  }

  @Test("Every alert destination lands on the page it names")
  func everyDestinationIsRouted() {
    // The switch is exhaustive, so a destination with no route does not compile; what is
    // left to check is that the two tabbed ones land on the RIGHT tab. "Open Permissions"
    // landing on Settings/General is a button that appears to work and does not.
    #expect(AlertActionRouting.route(for: .permissions).settingsTab == .permissions)
    #expect(AlertActionRouting.route(for: .security).settingsTab == .security)
    #expect(AlertActionRouting.route(for: .webhooks).destination == .webhooks)
    #expect(AlertActionRouting.route(for: .push).destination == .firebase)
    for destination in AlertDestination.allCases {
      #expect(!destination.label.isEmpty)
    }
  }

  @Test("A section that became a settings tab routes to that tab")
  func formerPagesRouteToTheirTab() {
    // The regression this guards: Permissions and Security are tabs inside settings, not
    // pages of their own, so their remedies resolve to Settings, which opens on General
    // unless the tab is carried. A button that lands on the wrong tab looks broken in
    // exactly the way a button that does nothing does.
    //
    // Security matters most of the two: a block alert's "see the whole list" is the one
    // remedy a user follows while actively locked out.
    #expect(
      AlertActionRouting.route(for: .permissions)
        == AlertActionRouting.Route(destination: .settings, settingsTab: .permissions)
    )
    #expect(
      AlertActionRouting.route(for: .security)
        == AlertActionRouting.Route(destination: .settings, settingsTab: .security)
    )
  }
}

@Suite("Settings tabs")
struct SettingsTabTests {

  @Test("Every settings section belongs to exactly one tab")
  func everySectionIsClaimedOnce() {
    // EVERY case, not only the ones that render today: a section whose members are all
    // internal renders nothing now and would fall through to Advanced the day one of them
    // is made visible, without anyone having decided that. Claimed TWICE is the other
    // half: the same rows on two tabs, saving to the same keys.
    for section in SettingSection.allCases {
      let owners = SettingsTab.allCases.filter { $0.sections.contains(section) }
      #expect(
        owners.count == 1,
        "section '\(section.title)' is claimed by \(owners.map(\.title))"
      )
    }
  }

  @Test("Placement is explicit, never the fallback")
  func nothingReliesOnTheFallback() {
    // `containing` keeps its Advanced fallback for the section that is added and not yet
    // placed; this proves that no section is in that state.
    for section in SettingSection.allCases {
      #expect(
        SettingsTab.allCases.contains { $0.sections.contains(section) },
        "'\(section.title)' reaches \(SettingsTab.containing(section: section).title) only by fallback"
      )
    }
  }

  @Test("No tab is empty")
  func everyTabHasContent() {
    // A tab with nothing on it is a dead button. Permissions is the exception by design:
    // it renders native grants rather than registry sections.
    let rendered = Set(Settings.renderableSections.map(\.section))
    for tab in SettingsTab.allCases where tab != .permissions {
      #expect(
        tab.sections.contains(where: rendered.contains),
        "the \(tab.title) tab shows nothing"
      )
    }
  }
}

@Suite("Address formatting")
struct AddressFormattingTests {

  /// Contacts hands back numbers already punctuated; this is for the ones that arrive
  /// through POST /api/v1/contact as raw digits. A leading country code is kept and
  /// separated rather than swallowed into the area code.
  @Test(
    "A bare NANP number is grouped",
    arguments: [
      ("5550101234", "(555) 010-1234"),
      ("15550101234", "+1 (555) 010-1234"),
    ])
  func bareDigitsAreGrouped(_ input: String, _ expected: String) {
    #expect(AddressFormatting.phone(input) == expected)
  }

  @Test("An already-formatted number is left exactly as it is")
  func alreadyFormatted() {
    // The important one. Reformatting what the user typed in Contacts would replace a
    // correct string with our guess at one.
    #expect(AddressFormatting.phone("+1 (555) 010-1234") == "+1 (555) 010-1234")
    #expect(AddressFormatting.phone("555.010.1234") == "555.010.1234")
  }

  @Test("A number we cannot confidently group is returned untouched")
  func unknownFormat() {
    // A wrong grouping reads worse than none. NANP is the only pattern we can infer
    // without a real metadata table.
    #expect(AddressFormatting.phone("+442079460958") == "+442079460958")
    #expect(AddressFormatting.phone("12345") == "12345")
  }

  @Test("Emails are never reformatted")
  func emails() {
    #expect(
      AddressFormatting.list(["person.name@example.com"], areEmails: true)
        == "person.name@example.com"
    )
  }
}
