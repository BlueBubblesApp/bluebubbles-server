//  FaceTimeRoundTripTests
//  The server's transport and the FaceTime helper's dispatch, talking over a real socket.
//
//  The peer of HelperRoundTripTests, for the dedicated FaceTime helper. It stands up a
//  `HelperSocketClient` wired to `FaceTimeDispatch` — exactly what `FaceTimeHelperMain` does
//  inside FaceTime.app — and proves the half a typo breaks: that the server's FaceTime action
//  names and the FaceTime dispatch's `switch` agree.
//
//  The TelephonyUtilities calls behind the actions cannot run here (this is not FaceTime.app,
//  so `FaceTimeBridge`'s host guard reports `unavailableOnThisOS`), and that is the point: a
//  recognised-but-unavailable answer is NOT "unknown action," which is what a misspelling
//  would produce.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import NIOPosix
import Testing

@testable import BBPrivateAPI
@testable import BlueBubblesFaceTimeHelper
@testable import BlueBubblesHelper
@testable import HelperShared

private func temporarySocketPath() -> String {
  NSTemporaryDirectory() + "bb-ft-\(UUID().uuidString.prefix(8)).sock"
}

/// Server transport plus a connected FaceTime helper client.
private func withFaceTimeHelper(
  _ body: (SocketTransport) async throws -> Void
) async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let path = temporarySocketPath()
  let transport = SocketTransport(
    socketPath: path, validator: PermissivePeerValidator(), group: group
  )
  try await transport.start()

  let helper = HelperSocketClient(
    socketPath: path,
    bundleIdentifier: "com.apple.FaceTime",
    eventRung: "facetime",
    dispatch: { try await FaceTimeDispatch.perform($0) },
    describeError: { FaceTimeDispatch.describe($0) }
  )
  helper.start()

  for _ in 0..<300 where await !transport.isConnected {
    try await Task.sleep(for: .milliseconds(10))
  }

  do {
    try await body(transport)
  } catch {
    helper.stop()
    await transport.stop()
    try? await group.shutdownGracefully()
    throw error
  }
  helper.stop()
  await transport.stop()
  try? await group.shutdownGracefully()
}

@Suite("FaceTime helper round trip", .serialized)
struct FaceTimeRoundTripTests {

  @Test("The FaceTime helper registers as com.apple.FaceTime")
  func registersAsFaceTime() async throws {
    try await withFaceTimeHelper { transport in
      for _ in 0..<300 where await transport.connectedProcesses.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      // This is what lets the server route FaceTime actions to the RIGHT helper.
      #expect(await transport.connectedProcesses.contains("com.apple.FaceTime"))
    }
  }

  @Test("Every FaceTime action is recognised by the FaceTime dispatch")
  func faceTimeActionsAreKnown() async throws {
    let requests: [(String, WireJSON)] = [
      ("generate-link", .object([:])),
      ("generate-link", .object(["callUUID": .string("CALL-1")])),
      ("dial-facetime", .object(["addresses": .array([.string("+15550000001")])])),
      ("answer-call", .object(["callUUID": .string("CALL-1")])),
      ("leave-call", .object(["callUUID": .string("CALL-1")])),
      (
        "admit-pending-member",
        .object([
          "conversationUUID": .string("GROUP-1"),
          "handleUUID": .string("+15550000001"),
        ])
      ),
      ("facetime-members", .object(["conversationUUID": .string("GROUP-1")])),
      ("facetime-call-status", .object(["callUUID": .string("CALL-1")])),
      ("facetime-active-calls", .object([:])),
      ("invalidate-facetime-links", .object([:])),
      // DIAGNOSTICS. Deliberately not routed over HTTP — `debug` dumps raw
      // TUConversation internals, `windows` and `dismiss-alert` drive FaceTime's UI —
      // so this round trip is the only coverage they have. It is also the answer to
      // "how do we test them now": in-process, through the real dispatch, no API.
      ("facetime-debug", .object(["conversationUUID": .string("GROUP-1")])),
      ("facetime-windows", .object([:])),
      ("facetime-dismiss-alert", .object([:])),
    ]

    try await withFaceTimeHelper { transport in
      for (action, data) in requests {
        var reason = ""
        do {
          _ = try await transport.request(
            action: action, data: data, timeout: .seconds(5)
          )
        } catch PrivateAPIError.rejectedByMessages(let text) {
          reason = text
        } catch {
          reason = String(describing: error)
        }
        #expect(
          !reason.contains("unknown action"),
          "the FaceTime dispatch does not recognise '\(action)'"
        )
      }
    }
  }

  /// A non-FaceTime action routed here IS unknown — the FaceTime helper handles only
  /// FaceTime actions, so this is the honest answer and distinguishes a misroute from a
  /// missing feature.
  @Test("A non-FaceTime action is reported as unknown")
  func nonFaceTimeActionIsUnknown() async throws {
    try await withFaceTimeHelper { transport in
      var reason = ""
      do {
        _ = try await transport.request(
          action: "send-message", data: .object([:]), timeout: .seconds(5)
        )
      } catch PrivateAPIError.rejectedByMessages(let text) {
        reason = text
      }
      #expect(reason.contains("unknown action"))
    }
  }

  /// The routing proof: with BOTH a Messages helper and a FaceTime helper on one socket, a
  /// request targeted at `com.apple.FaceTime` reaches the FaceTime dispatch (which answers
  /// "unavailable", since this is not FaceTime.app) — NOT the Messages dispatch, which would
  /// answer "unknown action" for a FaceTime action. Whichever registered most recently, the
  /// target decides.
  @Test("A FaceTime-targeted request reaches the FaceTime helper, not Messages")
  func routingTargetsTheRightHelper() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    // Two helpers on one socket. The Messages one registers LAST, so "most recent" would
    // send a FaceTime action to the wrong place if routing were not targeted.
    let faceTime = HelperSocketClient(
      socketPath: path, bundleIdentifier: "com.apple.FaceTime", eventRung: "facetime",
      dispatch: { try await FaceTimeDispatch.perform($0) },
      describeError: { FaceTimeDispatch.describe($0) }
    )
    faceTime.start()
    let messages = HelperSocketClient(
      socketPath: path, bundleIdentifier: "com.apple.MobileSMS",
      eventRung: EventObservation.rung,
      dispatch: { try await HelperDispatch.perform($0) },
      describeError: { HelperDispatch.describe($0) }
    )
    messages.start()

    for _ in 0..<300 where await transport.connectedProcesses.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.connectedProcesses.count == 2)

    var reason = ""
    do {
      _ = try await transport.request(
        action: "facetime-members",
        data: .object(["conversationUUID": .string("GROUP-1")]),
        timeout: .seconds(5),
        process: "com.apple.FaceTime"
      )
    } catch PrivateAPIError.rejectedByMessages(let text) {
      reason = text
    }
    // Reached FaceTime (recognised, unavailable) — not Messages (would be "unknown action").
    #expect(!reason.contains("unknown action"), "the request was misrouted to Messages")

    // And an unconnected target fails cleanly rather than misrouting.
    var absentReason = ""
    do {
      _ = try await transport.request(
        action: "facetime-members", data: .object([:]),
        timeout: .seconds(5), process: "com.apple.NotConnected"
      )
    } catch PrivateAPIError.rejectedByMessages(let text) {
      absentReason = text
    }
    #expect(absentReason.contains("not connected"))

    faceTime.stop()
    messages.stop()
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  /// The architecture the sandbox forces, and a REGRESSION TEST for a long misdiagnosis.
  ///
  /// A sandboxed app can only reach a Unix socket inside its OWN container, and that rule
  /// is symmetric — measured with both helpers injected, binding one path at a time:
  ///
  ///     socket in Messages' container   Messages connects; FaceTime never does
  ///     socket in FaceTime's container  FaceTime connects; Messages registers, then drops
  ///
  /// So one socket cannot serve two apps, and the per-process routing was unreachable in a
  /// real install: whichever app did not own the container was silently absent, and every
  /// untargeted action came back `unknown action` from the wrong helper. The server binds
  /// one socket PER APP. Here each client connects to a different path, and both must be
  /// reachable through the one transport.
  @Test("Two helpers on two sockets are both reachable through one transport")
  func bindsOneSocketPerApp() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let messagesPath = temporarySocketPath()
    let faceTimePath = temporarySocketPath()
    let transport = SocketTransport(
      socketPaths: [messagesPath, faceTimePath],
      validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()
    #expect(await transport.paths.count == 2)

    let messages = HelperSocketClient(
      socketPath: messagesPath, bundleIdentifier: "com.apple.MobileSMS",
      eventRung: EventObservation.rung,
      dispatch: { try await HelperDispatch.perform($0) },
      describeError: { HelperDispatch.describe($0) }
    )
    messages.start()
    let faceTime = HelperSocketClient(
      socketPath: faceTimePath, bundleIdentifier: "com.apple.FaceTime",
      eventRung: "facetime",
      dispatch: { try await FaceTimeDispatch.perform($0) },
      describeError: { FaceTimeDispatch.describe($0) }
    )
    faceTime.start()

    for _ in 0..<300 where await transport.connectedProcesses.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    // BOTH, at the same time — the thing a single socket could never deliver.
    #expect(await transport.connectedProcesses == ["com.apple.MobileSMS", "com.apple.FaceTime"])

    // A FaceTime action reaches the FaceTime helper on its own socket...
    var faceTimeReason = ""
    do {
      _ = try await transport.request(
        action: "facetime-members",
        data: .object(["conversationUUID": .string("GROUP-1")]),
        timeout: .seconds(5), process: "com.apple.FaceTime"
      )
    } catch PrivateAPIError.rejectedByMessages(let text) { faceTimeReason = text }
    #expect(!faceTimeReason.contains("unknown action"))

    // ...and an untargeted one reaches Messages on ITS socket.
    var messagesReason = ""
    do {
      _ = try await transport.request(
        action: "check-facetime-availability",
        data: .object(["address": .string("person@example.com")]),
        timeout: .seconds(5)
      )
    } catch PrivateAPIError.rejectedByMessages(let text) { messagesReason = text }
    #expect(!messagesReason.contains("unknown action"))

    faceTime.stop()
    messages.stop()
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  /// The other half of the routing rule, and a REGRESSION TEST.
  ///
  /// Only the FaceTime routes name a process; every inherited action — sending, reactions,
  /// availability — goes out untargeted. Those belong to Messages, but the fallback used to
  /// be "whichever helper connected most recently", so with both injected a plain
  /// `check-facetime-availability` was answered by the FaceTime dispatch as `unknown
  /// action`. Here FaceTime registers LAST, so a most-recent fallback would misroute.
  @Test("An untargeted request reaches Messages even when FaceTime connected last")
  func untargetedRequestsPreferMessages() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    let messages = HelperSocketClient(
      socketPath: path, bundleIdentifier: "com.apple.MobileSMS",
      eventRung: EventObservation.rung,
      dispatch: { try await HelperDispatch.perform($0) },
      describeError: { HelperDispatch.describe($0) }
    )
    messages.start()
    for _ in 0..<300 where await transport.connectedProcesses.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }

    // FaceTime second, so it is the most recent connection.
    let faceTime = HelperSocketClient(
      socketPath: path, bundleIdentifier: "com.apple.FaceTime", eventRung: "facetime",
      dispatch: { try await FaceTimeDispatch.perform($0) },
      describeError: { FaceTimeDispatch.describe($0) }
    )
    faceTime.start()
    for _ in 0..<300 where await transport.connectedProcesses.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.connectedProcesses.count == 2)

    var reason = ""
    do {
      _ = try await transport.request(
        action: "check-facetime-availability",
        data: .object(["address": .string("person@example.com")]),
        timeout: .seconds(5)
      )
    } catch PrivateAPIError.rejectedByMessages(let text) {
      reason = text
    }
    // Messages RECOGNISES the action (and fails for lack of IMCore outside Messages.app).
    // "unknown action" would mean the FaceTime helper answered it.
    #expect(
      !reason.contains("unknown action"),
      "an untargeted Messages action was misrouted to the FaceTime helper"
    )

    faceTime.stop()
    messages.stop()
    await transport.stop()
    try? await group.shutdownGracefully()
  }
}
