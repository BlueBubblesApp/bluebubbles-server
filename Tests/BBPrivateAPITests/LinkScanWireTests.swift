//  LinkScanWireTests
//  `ddScan` on the helper wire: present on both send actions, as 0 or 1.
//
//  A number rather than a boolean because the shipping helper reads it with `integerValue`,
//  and the Swift helper accepts exactly what the shipping one does. Multipart is the action
//  that used to omit it.
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

@Suite("ddScan over the wire")
struct LinkScanWireTests {

  private let chat = ChatIdentifier("iMessage;-;+15551234567")

  @Test("A text send carries ddScan as 1 or 0", arguments: [(true, 1.0), (false, 0.0)])
  func text(_ scan: Bool, _ wire: Double) async throws {
    let transport = RecordingTransport()
    let client = PrivateAPIClient(transport: transport)
    _ = try await client.sendMessage(
      SendMessageRequest(chat: chat, text: "BB test", scanForLinks: scan))
    #expect(await transport.lastPayload?["ddScan"]?.doubleValue == wire)
  }

  @Test("A multipart send carries ddScan as 1 or 0", arguments: [(true, 1.0), (false, 0.0)])
  func multipart(_ scan: Bool, _ wire: Double) async throws {
    let transport = RecordingTransport()
    let client = PrivateAPIClient(transport: transport)
    _ = try await client.sendMultipart(
      SendMultipartRequest(
        chat: chat, parts: [MessagePart(text: "BB test")], scanForLinks: scan))
    #expect(await transport.lastPayload?["ddScan"]?.doubleValue == wire)
  }
}
