//  AppMessageWireTests
//  An app balloon's preview image on the helper wire: `filePath` when there is one, nothing
//  when there is not.
//
//  The key is the attachment send's own, because it is the same thing: a file inside
//  Messages' container that the helper registers as a transfer. Absent rather than empty
//  when no image was asked for, so a helper never tries to register a path of "".
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBPrivateAPI

/// Records each payload and answers with a message GUID.
private actor RecordingTransport: PrivateAPITransport {
  var isConnected: Bool { true }
  var connectedProcesses: Set<String> { ["com.apple.MobileSMS"] }

  private(set) var payloads: [WireJSON] = []

  func start() async throws {}
  func stop() async {}

  @discardableResult
  func request(action: String, data: WireJSON, timeout: Duration) async throws -> WireJSON? {
    payloads.append(data)
    return .object(["identifier": .string("00000000-0000-0000-0000-000000000001")])
  }

  func send(action: String, data: WireJSON) async throws { payloads.append(data) }

  nonisolated var events: AsyncStream<PrivateAPIEvent> { AsyncStream { $0.finish() } }
  var lastPayload: WireJSON? { payloads.last }
}

@Suite("App message over the wire")
struct AppMessageWireTests {

  private let chat = ChatIdentifier("iMessage;-;someone@example.com")
  private let bundle =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:TEAMID123:com.example.game"

  @Test("A preview image travels as filePath")
  func previewImage() async throws {
    let transport = RecordingTransport()
    let client = PrivateAPIClient(transport: transport)
    _ = try await client.sendAppMessage(
      SendAppMessageRequest(
        chat: chat, balloonBundleID: bundle, payload: Data([1, 2, 3]),
        previewImagePath: "/staged/preview.jpeg"))
    #expect(await transport.lastPayload?["filePath"]?.stringValue == "/staged/preview.jpeg")
  }

  @Test("No preview image means no filePath key at all")
  func noPreviewImage() async throws {
    let transport = RecordingTransport()
    let client = PrivateAPIClient(transport: transport)
    _ = try await client.sendAppMessage(
      SendAppMessageRequest(chat: chat, balloonBundleID: bundle, payload: Data([1, 2, 3])))
    #expect(await transport.lastPayload?["filePath"] == nil)
    #expect(await transport.lastPayload?["payload"]?.stringValue == "AQID")
  }

  @Test("A later turn names the session's first message")
  func sessionOrigin() async throws {
    let transport = RecordingTransport()
    let client = PrivateAPIClient(transport: transport)
    _ = try await client.sendAppMessage(
      SendAppMessageRequest(
        chat: chat, balloonBundleID: bundle, payload: Data([1, 2, 3]),
        sessionOriginGUID: "11111111-0000-0000-0000-000000000004"))
    #expect(
      await transport.lastPayload?["sessionOriginGuid"]?.stringValue
        == "11111111-0000-0000-0000-000000000004")
  }

  @Test("A first turn carries no sessionOriginGuid key at all")
  func noSessionOrigin() async throws {
    // Absent rather than null or empty: the helper links whatever it is handed, and an
    // empty GUID would be a balloon associated with nothing.
    let transport = RecordingTransport()
    let client = PrivateAPIClient(transport: transport)
    _ = try await client.sendAppMessage(
      SendAppMessageRequest(chat: chat, balloonBundleID: bundle, payload: Data([1, 2, 3])))
    #expect(await transport.lastPayload?["sessionOriginGuid"] == nil)
  }
}
