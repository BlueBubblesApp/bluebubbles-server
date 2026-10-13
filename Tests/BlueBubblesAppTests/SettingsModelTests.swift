//  SettingsModelTests
//  The one door from a screen to the server's settings.
//
//  What it replaced was an optional store and twenty-four `guard let store … else { return }`
//  in views, each a write that did nothing and said nothing when there was no server. These
//  pin the three things the door promises instead: no server is an error with a sentence,
//  a write is recorded as the operator's, and a write anywhere moves the counters a view
//  keys its reads on.

import BBCore
import BBPersistence
import BBSettings
import BBTestSupport
import Foundation
import Testing
import os

@testable import BlueBubblesApp

@Suite("Settings model")
@MainActor
struct SettingsModelTests {

  static func store() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  // MARK: - No server

  @Test("With no server, a read throws rather than answering with a default")
  func readWithoutServerThrows() async {
    let settings = SettingsModel()
    #expect(!settings.isAvailable)
    await #expect(throws: ServerNotRunning.self) {
      _ = try await settings.get(Settings.socketPort)
    }
    await #expect(throws: ServerNotRunning.self) {
      _ = try await settings.read(Settings.password.erased)
    }
  }

  /// The failure the door exists for: a switch flipped with no server used to flip back and
  /// say nothing, because the write was skipped by a `guard`.
  @Test("With no server, a write throws rather than doing nothing")
  func writeWithoutServerThrows() async {
    let settings = SettingsModel()
    await #expect(throws: ServerNotRunning.self) {
      try await settings.set(Settings.socketPort, to: 4321)
    }
    await #expect(throws: ServerNotRunning.self) {
      try await settings.write(Settings.dockBadge.erased, .bool(true))
    }
    await #expect(throws: ServerNotRunning.self) {
      try await settings.set("x", forKey: "app.example.field", isSecret: false)
    }
  }

  @Test("No server is said in a sentence, not as a type name")
  func noServerHasASentence() {
    let sentence = DiagnosticText.sentence(for: ServerNotRunning())
    #expect(sentence == ServerNotRunning().body)
    #expect(!sentence.contains("ServerNotRunning"))
  }

  // MARK: - With a server

  @Test("A write lands, and reads back through the same door")
  func roundTrip() async throws {
    let settings = SettingsModel()
    await settings.attach(try await Self.store())
    #expect(settings.isAvailable)

    try await settings.set(Settings.socketPort, to: 4321)
    #expect(try await settings.get(Settings.socketPort) == 4321)

    settings.detach()
    #expect(!settings.isAvailable)
  }

  /// Without this, every setting changed from the app is recorded in the audit log as
  /// nobody's: the view no longer wraps its write, so the door has to.
  @Test("A write through the door is recorded as the operator's")
  func writesRunAsTheOperator() async throws {
    let store = try await Self.store()
    let observer = ActorRecorder()
    await store.attachAuditObserver(observer)
    let settings = SettingsModel()
    await settings.attach(store)

    try await settings.set(Settings.socketPort, to: 4321)
    try await settings.write(Settings.dockBadge.erased, .bool(true))

    #expect(observer.actors == [.operator, .operator])
  }

  /// The follow is wired, end to end: a write moves the counter a view keys its `.task` on.
  @Test("A write anywhere moves the version of the key it wrote")
  func writeMovesTheVersion() async throws {
    let store = try await Self.store()
    let settings = SettingsModel()
    await settings.attach(store)
    let before = settings.version(of: [Settings.socketPort.key])

    // Written straight to the store, as a service or the API would: following is not only
    // for the app's own writes.
    try await store.set(Settings.socketPort, to: 4321)

    try await waitUntil("the write to reach the model's follower") {
      settings.version(of: [Settings.socketPort.key]) != before
    }
    let after = settings.version(of: [Settings.socketPort.key])
    #expect(after != before, "a write to the store did not reach the model's follower")
  }

  // MARK: - Counting

  @Test("A change moves the keys it names and nothing else")
  func versionsArePerKey() {
    let settings = SettingsModel()
    let port = settings.version(of: [Settings.socketPort.key])
    let badge = settings.version(of: [Settings.dockBadge.key])

    settings.noteChange([Settings.socketPort.key])

    #expect(settings.version(of: [Settings.socketPort.key]) != port)
    #expect(settings.version(of: [Settings.dockBadge.key]) == badge)
    #expect(
      settings.version(of: [Settings.socketPort.key, Settings.dockBadge.key]) != port &+ badge)
  }

  @Test("A namespace moves on a change to any key inside it, and only those")
  func versionsByNamespace() {
    let settings = SettingsModel()
    let ngrok = settings.version(inNamespace: "app.bluebubbles.proxy.ngrok.")

    settings.noteChange(["app.bluebubbles.proxy.zrok.token"])
    #expect(settings.version(inNamespace: "app.bluebubbles.proxy.ngrok.") == ngrok)

    settings.noteChange(["app.bluebubbles.proxy.ngrok.auth_token"])
    #expect(settings.version(inNamespace: "app.bluebubbles.proxy.ngrok.") != ngrok)
  }

  // MARK: - Drafts

  @Test("A kept edit comes back once, over the value it was typed over")
  func draftComesBackOnce() {
    let settings = SettingsModel()
    settings.keepDraft("new address", typedOver: "old address", for: Settings.serverAddress.key)

    #expect(
      settings.takeDraft(for: Settings.serverAddress.key, ifStillOver: "old address")
        == "new address")
    #expect(
      settings.takeDraft(for: Settings.serverAddress.key, ifStillOver: "old address") == nil,
      "a kept edit was handed back twice")
  }

  /// A reset, the API or another screen moved the value: the edit was of something that is
  /// no longer there, and putting it back would write over the newer value on the next blur.
  @Test("A kept edit over a value that has since moved is dropped")
  func staleDraftIsDropped() {
    let settings = SettingsModel()
    settings.keepDraft("typed", typedOver: "before", for: "key")
    #expect(settings.takeDraft(for: "key", ifStillOver: "after") == nil)
    #expect(settings.takeDraft(for: "key", ifStillOver: "before") == nil, "and not kept either")
  }

  @Test("A committed edit and a stopped server both forget what was kept")
  func draftsAreForgotten() async throws {
    let settings = SettingsModel()
    settings.keepDraft("typed", typedOver: "", for: "a")
    settings.discardDraft(for: "a")
    #expect(settings.takeDraft(for: "a", ifStillOver: "") == nil)

    await settings.attach(try await Self.store())
    settings.keepDraft("typed", typedOver: "", for: "b")
    settings.detach()
    #expect(settings.takeDraft(for: "b", ifStillOver: "") == nil)
  }
}

/// Records who the audit context said was acting for each settings write.
private final class ActorRecorder: SettingsWriteObserving, Sendable {
  private let recorded = OSAllocatedUnfairLock<[AuditActor?]>(initialState: [])
  var actors: [AuditActor?] { recorded.withLock { $0 } }
  func settingsDidChange(_ record: SettingsWriteRecord) {
    let actor = AuditContext.current?.actor
    recorded.withLock { $0.append(actor) }
  }
}
