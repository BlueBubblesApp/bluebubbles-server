//  StubHelperTransport
//  Records what was asked of the helpers and replies with whatever the test wants.
//
//  The transport is a protocol precisely so this can exist: `PrivateAPIClient` is the only
//  place in the server that knows each helper's action names and field spellings, and this
//  is the only way to assert them without Messages.app or FaceTime.app. It reports both
//  helpers connected, since the client never consults that and the wire suites for each app
//  share it.

import BBPrivateAPIContract
import Foundation

@testable import BBPrivateAPI

actor StubHelperTransport: PrivateAPITransport {
  var isConnected: Bool { true }
  var connectedProcesses: Set<String> { [HelperHost.messages, HelperHost.faceTime] }

  private(set) var actions: [String] = []
  private(set) var payloads: [WireJSON] = []
  private var replies: [String: WireJSON] = [:]

  init(replies: [String: WireJSON] = [:]) { self.replies = replies }

  func start() async throws {}
  func stop() async {}

  @discardableResult
  func request(action: String, data: WireJSON, timeout: Duration) async throws -> WireJSON? {
    actions.append(action)
    payloads.append(data)
    return replies[action]
  }

  func send(action: String, data: WireJSON) async throws {
    actions.append(action)
    payloads.append(data)
  }

  nonisolated var events: AsyncStream<PrivateAPIEvent> { AsyncStream { $0.finish() } }

  var lastPayload: WireJSON? { payloads.last }
}
