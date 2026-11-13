//  ConnectionMethodNeedsTests
//  What a chosen connection method still needs, for any method, from one answer.
//
//  Setup's connection step drew the program and the fields and never read the steps a service
//  raises, so Tailscale's sign-in link was on no screen a person in setup could reach. Each
//  rule here is one the Connection row and setup used to decide for themselves.

import BBBuiltIns
import BBDiagnostics
import BBServiceKit
import BBTestSupport
import Foundation
import Testing

@testable import BBTooling
@testable import BlueBubblesApp
@testable import BlueBubblesServerCore

@Suite("Connection method needs")
struct ConnectionMethodNeedsTests {

  private static let link = URL(string: "https://example.com/sign-in/abc")!

  private func status(
    of manifest: ServiceManifest,
    path: String?,
    activity: ToolActivity = .idle,
    copy: ToolCopyOnThisMac = .none
  ) throws -> ToolStatus {
    let tool = try #require(manifest.tools.first)
    return ToolStatus(
      descriptor: tool, state: ToolState(toolID: tool.id), activity: activity,
      origin: path == nil ? .missing : .managed, executablePath: path, copyOnThisMac: copy,
      preference: .automatic)
  }

  private func needs(
    _ manifest: ServiceManifest,
    toolStatus: ToolStatus? = nil,
    missingFields: [FieldDescriptor] = [],
    pendingSteps: [UserAlert] = [],
    refusals: [UserAlert] = [],
    health: ServiceHealth? = nil,
    blockedBy: String? = nil
  ) -> ConnectionMethodNeeds {
    ConnectionMethodNeeds(
      manifest: manifest, toolStatus: toolStatus, missingFields: missingFields,
      pendingSteps: pendingSteps, refusals: refusals, health: health, blockedBy: blockedBy)
  }

  private func alert(_ title: String, link: URL? = nil) -> UserAlert {
    UserAlert(
      severity: .warning, title: title, body: "What to do about it.", source: "Connection",
      actions: (link.map { [.openURL($0)] } ?? []) + [.openSettings(.settings)])
  }

  // MARK: - The program

  @Test("A status that has not arrived is not a missing program")
  func unknownStatusIsNotMissing() {
    let answer = needs(BuiltInManifests.tailscale)
    #expect(answer.tool != nil)
    #expect(!answer.isProgramMissing)
    #expect(!answer.canDownloadProgram)
    #expect(answer.programLine == nil)
  }

  @Test("A program the service could not be handed is missing, and can be downloaded")
  func missingProgram() throws {
    let manifest = BuiltInManifests.tailscale
    let answer = needs(manifest, toolStatus: try status(of: manifest, path: nil))
    #expect(answer.isProgramMissing)
    #expect(answer.canDownloadProgram)
    #expect(answer.programLine?.tone == .attention)
    #expect(answer.programLine?.text.contains(manifest.name) == true)
  }

  @Test("A program that is here needs nothing, whoever installed it")
  func presentProgram() throws {
    let manifest = BuiltInManifests.ngrok
    let answer = needs(manifest, toolStatus: try status(of: manifest, path: "/opt/ngrok"))
    #expect(!answer.isProgramMissing)
    #expect(answer.programLine == nil)
  }

  @Test("A download in flight offers no second download, and a failed one says so")
  func programActivity() throws {
    let manifest = BuiltInManifests.zrok
    let installing = needs(
      manifest,
      toolStatus: try status(
        of: manifest, path: nil, activity: .installing(.downloading(fraction: 0.5))))
    #expect(installing.isProgramMissing)
    #expect(!installing.canDownloadProgram)
    #expect(installing.programLine?.tone == .informational)

    let failed = needs(
      manifest, toolStatus: try status(of: manifest, path: nil, activity: .failed("No network")))
    #expect(
      failed.programLine == .init(text: "No network", symbol: "arrow.down.circle", tone: .problem))
    // Pressing it again is the remedy, so the button comes back with the failure beside it.
    #expect(failed.canDownloadProgram)
  }

  @Test("A refused copy on this Mac is named, not reported as never downloaded")
  func refusedCopy() throws {
    let manifest = BuiltInManifests.cloudflare
    let answer = needs(
      manifest,
      toolStatus: try status(
        of: manifest, path: nil,
        copy: .incompatible(path: "/opt/tool", version: "1.0", requirement: "2.0 or newer")))
    #expect(answer.programLine?.symbol == "externaldrive")
    #expect(answer.programLine?.text.contains("/opt/tool") == true)
  }

  // MARK: - The fields

  @Test("A blank required field is named")
  func blankFields() throws {
    let manifest = BuiltInManifests.ngrok
    let token = try #require(manifest.fields.filter(\.isRequired).first)
    let answer = needs(manifest, missingFields: [token])
    #expect(answer.fieldsLine?.text == "ngrok needs: \(token.label)")
    #expect(needs(manifest).fieldsLine == nil)
  }

  // MARK: - The steps

  @Test("A step carries its link; one without a link is no button")
  func stepLinks() {
    let answer = needs(
      BuiltInManifests.tailscale,
      pendingSteps: [alert("Sign in", link: Self.link), alert("Approve this Mac")])
    #expect(answer.steps.map(\.title) == ["Sign in", "Approve this Mac"])
    #expect(answer.steps[0].link == Self.link)
    #expect(answer.steps[1].link == nil)
  }

  /// "ngrok has no auth token" beside "ngrok needs: Auth Token" is one fact said twice; once
  /// the field is filled, a refusal still standing is about something else (a token the
  /// provider rejected) and is the only place that sentence can be read during setup.
  @Test("A refusal waits for the blank fields it would only repeat")
  func refusalsDeferToBlankFields() throws {
    let manifest = BuiltInManifests.zrok
    let token = try #require(manifest.fields.filter(\.isRequired).first)
    let refusal = alert("zrok rejected the account token")
    #expect(needs(manifest, missingFields: [token], refusals: [refusal]).steps.isEmpty)
    #expect(needs(manifest, refusals: [refusal]).steps.map(\.title) == [refusal.title])
  }

  @Test("A step speaks instead of the status line, which speaks in every other state")
  func statusLineGivesWayToSteps() {
    let manifest = BuiltInManifests.tailscale
    let waiting = ServiceHealth.inactive(reason: "waiting for you to sign in to Tailscale")
    #expect(needs(manifest, pendingSteps: [alert("Sign in")], health: waiting).statusLine == nil)
    #expect(needs(manifest, health: waiting).statusLine != nil)
    #expect(needs(manifest, health: .running).statusLine?.text == "Tailscale is connected.")
    // No server: nothing to say, and the screen has said why.
    #expect(needs(manifest).statusLine == nil)
  }

  /// The case a step can never answer: the service is not going to raise one.
  @Test("A method stranded behind a switched-off dependency names the switch")
  func blockedMethodSaysWhy() {
    let answer = needs(
      BuiltInManifests.tailscale, health: .inactive(reason: "waiting"), blockedBy: "HTTP API")
    #expect(answer.steps.isEmpty)
    #expect(answer.statusLine?.text == "Tailscale is not running: HTTP API is switched off.")
  }

  // MARK: - Every method

  /// No tunnel names: this is the rule that a method nobody here has heard of gets the same.
  @Test("Every connection method that declares a program gets the same answer")
  func everyMethodIsTreatedAlike() throws {
    let methods = IntegrationCatalog.connectionMethods
    #expect(methods.count >= 6, "the catalog lost its methods, so this checks nothing")
    for manifest in methods {
      let refusal = alert("Refused")
      let answer = needs(
        manifest,
        toolStatus: manifest.tools.isEmpty ? nil : try status(of: manifest, path: nil),
        pendingSteps: [alert("Sign in", link: Self.link)],
        refusals: [refusal])
      #expect(answer.name == manifest.name)
      #expect(answer.isProgramMissing == !manifest.tools.isEmpty, "\(manifest.name)")
      #expect(answer.steps.map(\.title) == ["Sign in", "Refused"], "\(manifest.name)")
    }
  }
}

/// The alerts a service raises, as the screens read them.
@Suite("Connection method alerts")
@MainActor
struct ConnectionMethodAlertsTests {

  private let method = BuiltInManifests.tailscale.id

  private func raise(_ key: ProxyAttentionAlerts.Key, _ title: String, in centre: AlertCenter) async
  {
    await centre.raise(
      UserAlert(
        severity: .warning, title: title, body: "Body.", source: "Connection",
        dedupeKey: key.dedupeKey(for: method)))
  }

  @Test("Steps and refusals are told apart, and the rest of a method's notices are neither")
  func readsTheRightNotices() async throws {
    let centre = AlertCenter()
    let model = AlertsModel()
    model.attach(centre)

    await raise(.step("sign-in"), "Sign in", in: centre)
    await raise(.refusal("token"), "Token refused", in: centre)
    await raise(.toolMissing, "Not installed", in: centre)
    await raise(.gaveUp, "Has stopped", in: centre)
    try await waitUntil("all four to arrive", timeout: .seconds(2)) { model.items.count == 4 }

    #expect(model.pendingAttention(for: method).map(\.title) == ["Sign in"])
    #expect(model.refusals(for: method).map(\.title) == ["Token refused"])
    // Another method's are not this one's.
    #expect(model.pendingAttention(for: BuiltInManifests.ngrok.id).isEmpty)

    await model.detach()
  }

  /// The two ways a link stops being live, and neither may leave a button behind.
  @Test("A step goes when the service withdraws it, and when the server stops")
  func noDeadLinks() async throws {
    let centre = AlertCenter()
    let model = AlertsModel()
    model.attach(centre)

    await raise(.step("sign-in"), "Sign in", in: centre)
    try await waitUntil("the step to arrive", timeout: .seconds(2)) {
      !model.pendingAttention(for: method).isEmpty
    }
    await centre.dismiss(dedupeKeyPrefix: ProxyAttentionAlerts.everyAlertPrefix(for: method))
    try await waitUntil("the step to be withdrawn", timeout: .seconds(2)) {
      model.pendingAttention(for: method).isEmpty
    }

    await raise(.step("sign-in-again"), "Sign in", in: centre)
    try await waitUntil("the next step to arrive", timeout: .seconds(2)) {
      !model.pendingAttention(for: method).isEmpty
    }
    await model.detach()
    #expect(model.pendingAttention(for: method).isEmpty)
  }
}
