//  AlertActionWiringTests
//  An alert's remedy is reachable, not just declared.
//
//  Two call sites populate `AlertAction` — a rate-limit block carries `.unblock(address:)`,
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

    // The address has to be IN the action — a bare "unblock" button cannot know which
    // client to lift, and the alert is the only place that context exists.
    #expect(blockAlert.actions.contains(.unblock(address: address)))
    // And the page too, for a user who wants to see the whole list.
    #expect(blockAlert.actions.contains(.openSettings(section: "security")))
  }

  @Test("Every action an alert can carry maps to a page or a command")
  func everyActionIsHandled() {
    // A cheap guard on the thing that actually broke. `NotificationsView.perform` is
    // exhaustive, so this asserts the section strings producers actually use resolve to a
    // real page — an unrecognised one silently lands on Settings, which is a button that
    // appears to work and does not.
    for section in ["security", "webhooks", "permissions", "notifications", "logs"] {
      #expect(
        AlertActionRouting.route(forSection: section) != nil,
        "no page for alert section '\(section)'"
      )
    }
  }

  @Test("A section that became a settings tab routes to that tab")
  func formerPagesRouteToTheirTab() {
    // The regression this guards: Permissions and Security are tabs inside settings, not
    // pages of their own, so their remedies resolve to Settings — which opens on General
    // unless the tab is carried. A button that lands on the wrong tab looks broken in
    // exactly the way a button that does nothing does.
    //
    // Security matters most of the two: a block alert's "see the whole list" is the one
    // remedy a user follows while actively locked out.
    #expect(
      AlertActionRouting.route(forSection: "permissions")
        == AlertActionRouting.Route(destination: .settings, settingsTab: .permissions)
    )
    #expect(
      AlertActionRouting.route(forSection: "security")
        == AlertActionRouting.Route(destination: .settings, settingsTab: .security)
    )
  }
}

@Suite("Settings tabs")
struct SettingsTabTests {

  @Test("Every settings section the app renders belongs to exactly one tab")
  func everySectionIsClaimedOnce() {
    // The whole screen is generated from the registry, so a section nobody assigned would
    // be settings that exist, save, are read by the server, and have no screen. Claimed
    // TWICE is the other half: the same rows on two tabs, saving to the same keys.
    for group in Settings.renderableSections {
      let owners = SettingsTab.allCases.filter { $0.sections.contains(group.section) }
      #expect(
        owners.count == 1,
        "section '\(group.section)' is claimed by \(owners.map(\.title))"
      )
    }
  }

  @Test("A section nobody claimed still appears somewhere")
  func straySectionsFallThrough() {
    // Not a hypothetical: adding a setting with a new section name is a one-line change in
    // BBSettings that nothing forces you to follow up here.
    #expect(SettingsTab.containing(section: "Something Nobody Assigned") == .advanced)
  }

  @Test("No tab is empty")
  func everyTabHasContent() {
    // A tab with nothing on it is a dead button. Permissions is the exception by design —
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

  @Test("A bare ten-digit number is grouped")
  func tenDigits() {
    // Contacts hands back numbers already punctuated; this is for the ones that arrive
    // through POST /api/v1/contact as raw digits.
    #expect(AddressFormatting.phone("5550101234") == "(555) 010-1234")
  }

  @Test("A leading country code is kept and separated")
  func elevenDigits() {
    #expect(AddressFormatting.phone("15550101234") == "+1 (555) 010-1234")
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
