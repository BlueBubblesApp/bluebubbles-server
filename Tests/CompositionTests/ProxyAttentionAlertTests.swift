//  ProxyAttentionAlertTests
//  A connection method's "needs a person" notice: raised once, replaced by the next step, and
//  withdrawn, not merely read, when the step has been taken.
//
//  The notice is an alert, so it appears in the drawer and on the method's own page. That
//  makes withdrawal the part worth testing: a sign-in link that stays on screen after the
//  sign-in is an instruction to do it again, and a "sign in" beside an "enable certificates"
//  reads as two things still to do when it is one.

import BBBuiltIns
import BBDiagnostics
import BBProxy
import BBServiceKit
import Foundation
import Testing

@testable import BlueBubblesServerCore

/// A provider that is up but still working, needs a person, and later publishes on its own.
private actor PendingProvider: ProxyProviding {
  nonisolated let identifier = ServiceIdentifier("app.test.proxy.pending")
  private(set) var currentAddress: String?
  private var observer: ProxyObserver?

  func observe(_ observer: ProxyObserver) async { self.observer = observer }

  func connect() async throws -> String {
    throw ProxyError.pending(reason: "signing in")
  }

  func disconnect() async { currentAddress = nil }

  func ask(_ attention: ProxyAttention) async {
    await observer?.attentionRequired(attention)
  }

  func finish(with address: String) async {
    currentAddress = address
    await observer?.addressChanged(address)
  }
}

@Suite("Attention alerts")
struct ProxyAttentionAlertTests {

  private let signIn = ProxyAttention(
    title: "Sign in",
    body: "Open the link.",
    link: URL(string: "https://login.tailscale.com/a/0123456789ab"),
    key: "sign-in.0123456789ab",
    summary: "waiting for you to sign in"
  )
  private let certificates = ProxyAttention(
    title: "Enable certificates",
    body: "Turn them on.",
    link: nil,
    key: "https.",
    summary: "waiting for certificates"
  )

  private func attention(_ title: String, key: String) -> UserAlert {
    UserAlert(severity: .warning, title: title, body: "", source: "test", dedupeKey: key)
  }

  @Test("Withdrawing by prefix removes those alerts, tells the drawer, and leaves the rest")
  func prefixDismissal() async {
    let centre = AlertCenter()
    // Subscribed BEFORE the withdrawal, and read after it: the stream buffers, so this is
    // what the drawer would receive without any need to race it.
    let dismissals = await centre.dismissals()

    await centre.raise(attention("a", key: "proxy.attention.x.one"))
    await centre.raise(attention("b", key: "proxy.attention.x.two"))
    await centre.raise(attention("c", key: "proxy.attention.y.one"))
    await centre.dismiss(dedupeKeyPrefix: "proxy.attention.x.")

    #expect(await centre.all().map(\.title) == ["c"])
    var iterator = dismissals.makeAsyncIterator()
    #expect(await iterator.next()?.count == 2)

    // The dedupe key is released with the alert, so the same condition recurring is a
    // fresh notice rather than a coalesce into a row nobody can see.
    await centre.raise(attention("a again", key: "proxy.attention.x.one"))
    #expect(await centre.all().count == 2)
  }

  @Test("A pending step is shown once, replaced by the next, and withdrawn with the address")
  func attentionFollowsTheTunnel() async throws {
    let context = try await AppContextFixture.make()
    let service = ProxyService<TailscaleMethod>(host: context)
    let prefix = ProxyAttentionAlerts.dedupeKeyPrefix(for: BuiltInManifests.tailscale.id)
    func pending() async -> [UserAlert] {
      await context.alerts.all().filter { $0.dedupeKey?.hasPrefix(prefix) == true }
    }

    let provider = PendingProvider()
    try await service.coordinator.start(provider)
    #expect(await pending().isEmpty)

    // The step arrives as one alert carrying the link as its action.
    await provider.ask(signIn)
    let first = await pending()
    #expect(first.map(\.title) == ["Sign in"])
    #expect(first.first?.actions.contains(.openURL(signIn.link!)) == true)

    // The next step REPLACES it: the sign-in happened, or there would be no next step.
    await provider.ask(certificates)
    #expect(await pending().map(\.title) == ["Enable certificates"])

    // An address means every step was taken. Nothing is left asking for one.
    await provider.finish(with: "https://bluebubbles.tail1234.ts.net")
    #expect(await pending().isEmpty)

    // And a method that stops takes its pending step with it.
    await provider.ask(signIn)
    #expect(await pending().count == 1)
    await service.stop()
    #expect(await pending().isEmpty)
  }
}
