//  SwitchGateTests
//  One gate for a route behind a switch, and what it puts on the wire.
//
//  The FaceTime routes gate on a setting and the FindMy location routes on a feature flag,
//  through `SettingsProviding.requireOn`, which throws `InterfaceError.serviceDisabled`. The
//  responses they answer with are pinned here against the `Forbidden` envelope they have
//  always had: same status, type, message and detail, and still no `data`, because only an
//  INTEGRATION refusal names a service to switch on.

import BBCore
import BBHTTPAPI
import BBPersistence
import BBSerialization
import BBSettings
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Switch gate")
struct SwitchGateTests {

  private struct Context: SettingsProviding {
    let settings: SettingsStore
  }

  private func context() async throws -> Context {
    return Context(
      settings: try await TestSettings.store())
  }

  private func rendered(_ error: any Error) throws -> (status: Int, envelope: JSONValue) {
    let (status, envelope) = ErrorRenderer.render(error, logger: Logger(label: "test"))
    return (status, try JSONValue.parse(try envelope.encoded()))
  }

  @Test("A switched-off setting answers exactly the Forbidden it always did")
  func settingRefusalShape() async throws {
    let context = try await context()
    let setting = Settings.enableFaceTimePrivateAPI
    try await context.settings.set(setting, to: false)

    do {
      try await context.requireOn(setting)
      Issue.record("expected a refusal")
    } catch {
      let sentence =
        "\(setting.presentation?.label ?? setting.key) is disabled on this server. "
        + "Enable `\(setting.key)` in the server settings to use it."
      let ours = try rendered(error)
      let before = try rendered(Forbidden(sentence))
      #expect(ours.status == 403)
      #expect(ours.status == before.status)
      #expect(ours.envelope == before.envelope)
      #expect(ours.envelope["data"] == nil)
    }
  }

  @Test("A switched-off flag answers with its own reason and no data")
  func flagRefusalShape() async throws {
    let context = try await context()
    let flag = Features.findMyLocationSharing
    do {
      try await context.requireOn(flag)
      Issue.record("expected a refusal: the flag is off by default")
    } catch {
      let ours = try rendered(error)
      #expect(ours.status == 403)
      #expect(ours.envelope["error"]?["message"]?.stringValue?.contains(flag.rationale) == true)
      #expect(ours.envelope["data"] == nil)
    }
  }

  @Test("A switched-on setting lets the request through")
  func settingOn() async throws {
    let context = try await context()
    try await context.settings.set(Settings.enableFaceTimePrivateAPI, to: true)
    try await context.requireOn(Settings.enableFaceTimePrivateAPI)
  }

  @Test("An integration refusal still names its service in data")
  func integrationRefusalKeepsData() throws {
    let service = "app.bluebubbles.core.contacts"
    let error = InterfaceError.serviceDisabled("off", service: service)
    #expect(try rendered(error).envelope["data"] == .object(["service": .string(service)]))
  }
}
