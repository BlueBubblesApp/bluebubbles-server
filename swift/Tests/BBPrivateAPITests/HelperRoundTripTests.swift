//  HelperRoundTripTests
//  The server's transport and the injected helper's client, talking to each other.
//
//  Both halves of the protocol are ours, so this is the test that actually proves it: real
//  Unix-domain socket, real length-prefixed frames, real dispatch. Testing either side
//  against a hand-written double would only prove the double matched my assumptions.
//
//  The helper's IMCore methods are all stubbed at this stage, which makes them ideal here: a
//  `notImplemented` travelling back as a structured error exercises the whole path —
//  dispatch, error mapping, framing, transaction correlation — without needing Messages.app.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import NIOPosix
import Testing

@testable import BBPrivateAPI
@testable import BlueBubblesHelper
@testable import HelperShared

private func temporarySocketPath() -> String {
  NSTemporaryDirectory() + "bb-rt-\(UUID().uuidString.prefix(8)).sock"
}

/// Server transport plus a connected helper client.
private func withHelperAndServer(
  _ body: (SocketTransport, HelperSocketClient) async throws -> Void
) async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let path = temporarySocketPath()
  // Permissive: the test binary is ad-hoc signed and could not satisfy a real requirement.
  // What is under test here is the protocol, and rejection is covered separately.
  let transport = SocketTransport(
    socketPath: path, validator: PermissivePeerValidator(), group: group
  )
  try await transport.start()

  // No bridge argument: `IMCoreBridge` is `@MainActor` now and is reached at the dispatch
  // point rather than injected, because a socket client running on its own thread has
  // nowhere to construct a main-actor object. See IMCoreBridge.
  let helper = HelperSocketClient(
    socketPath: path,
    bundleIdentifier: "com.apple.MobileSMS",
    eventRung: EventObservation.rung,
    dispatch: { try await HelperDispatch.perform($0) },
    describeError: { HelperDispatch.describe($0) }
  )
  helper.start()

  for _ in 0..<300 where await !transport.isConnected {
    try await Task.sleep(for: .milliseconds(10))
  }

  do {
    try await body(transport, helper)
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

@Suite("Helper round trip", .serialized)
struct HelperRoundTripTests {

  @Test("The helper connects and the server sees it")
  func connects() async throws {
    try await withHelperAndServer { transport, _ in
      #expect(await transport.isConnected)
    }
  }

  /// The helper announces itself on connect, and that announcement is the only positive
  /// proof an injection took — Messages launching without the dylib looks identical.
  @Test("The helper registers its bundle identifier on connect")
  func registersOnConnect() async throws {
    try await withHelperAndServer { transport, _ in
      for _ in 0..<300 where await transport.connectedProcesses.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await transport.connectedProcesses.contains("com.apple.MobileSMS"))
    }
  }

  /// A full request/response cycle across the socket. The action is unported, so the reply
  /// is a structured error — which still travels the entire path.
  @Test("An unported action returns a structured error, not a timeout")
  func unportedActionReportsCleanly() async throws {
    try await withHelperAndServer { transport, _ in
      await #expect(throws: PrivateAPIError.self) {
        _ = try await transport.request(
          action: "start-typing",
          data: .object(["chatGuid": .string("iMessage;-;someone@example.com")]),
          timeout: .seconds(5)
        )
      }
    }
  }

  /// The distinction matters: an unknown action is a version mismatch between server and
  /// helper, whereas an unported one is a feature not yet written. Conflating them makes a
  /// skew look like a missing feature.
  @Test("An unknown action is reported differently from an unported one")
  func unknownActionIsDistinct() async throws {
    try await withHelperAndServer { transport, _ in
      var unknownReason = ""
      do {
        _ = try await transport.request(
          action: "no-such-action", data: .object([:]), timeout: .seconds(5)
        )
      } catch PrivateAPIError.rejectedByMessages(let reason) {
        unknownReason = reason
      }
      #expect(unknownReason.contains("unknown action"))

      var unportedReason = ""
      do {
        _ = try await transport.request(
          action: "search-messages", data: .object(["query": .string("x")]),
          timeout: .seconds(5)
        )
      } catch PrivateAPIError.rejectedByMessages(let reason) {
        unportedReason = reason
      }
      #expect(unportedReason.contains("not implemented"))
    }
  }

  /// Every FindMy action has to be one the helper RECOGNISES.
  ///
  /// The IMCore calls behind them cannot run here — no Messages.app, no session — so what
  /// this proves is the half that a typo actually breaks: that the server's action names
  /// and the helper's `switch` agree. A misspelling on either side is indistinguishable
  /// from a version skew at runtime, and this is the only place the two are compiled
  /// together.
  ///
  /// `findmy-status` is deliberately excluded: it ANSWERS on a machine with no FindMy
  /// rather than failing, so it is asserted separately below.
  /// The chat-control actions, same shape of check as FindMy's.
  ///
  /// These cannot be exercised for real without Messages running with the helper injected —
  /// what this pins is the half that breaks silently: a client and a helper that disagree
  /// about an action NAME produce "unknown action", which reads to a user as a missing
  /// feature rather than as a version skew.
  @Test("Every chat-control action is recognised by the helper")
  func chatControlActionsAreKnown() async throws {
    let chat = WireJSON.string("iMessage;-;+15550000001")
    let requests: [(String, WireJSON)] = [
      ("get-chat-mute", .object(["chatGuid": chat])),
      ("set-chat-mute", .object(["chatGuid": chat])),
      (
        "set-chat-mute",
        .object([
          "chatGuid": chat,
          "mutedUntil": .number(4_102_444_800_000),
          "syncToPairedDevice": .bool(false),
        ])
      ),
      ("unmute-chat", .object(["chatGuid": chat])),
      ("refetch-chat-background", .object(["chatGuid": chat])),
      ("clear-chat-history", .object(["chatGuid": chat])),
      ("get-chat-filter", .object(["chatGuid": chat])),
      ("mark-sender-known", .object(["chatGuid": chat, "saveInContacts": .bool(false)])),
      ("mark-chat-spam", .object(["chatGuid": chat, "dryRun": .bool(true)])),
      ("report-chat-junk", .object(["chatGuid": chat, "dryRun": .bool(true)])),
      ("set-chat-filter", .object(["chatGuid": chat, "category": .number(0)])),
    ]

    try await withHelperAndServer { transport, _ in
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
          "the helper does not recognise '\(action)'"
        )
      }
    }
  }

  /// A mute request with no chat GUID is refused BY NAME rather than defaulting.
  @Test("A mute without a chat is refused by name")
  func muteRequiresAChat() async throws {
    try await withHelperAndServer { transport, _ in
      var reason = ""
      do {
        _ = try await transport.request(
          action: "set-chat-mute", data: .object([:]), timeout: .seconds(5)
        )
      } catch PrivateAPIError.rejectedByMessages(let text) {
        reason = text
      } catch {
        reason = String(describing: error)
      }
      #expect(reason.contains("chatGuid"))
    }
  }

  @Test("Every FindMy action is recognised by the helper")
  func findMyActionsAreKnown() async throws {
    let requests: [(String, WireJSON)] = [
      ("findmy-friends", .object([:])),
      ("refresh-findmy-friends", .object([:])),
      ("refresh-findmy-location", .object(["address": .string("+15550000001")])),
      ("request-findmy-location-share", .object(["address": .string("+15550000001")])),
      (
        "start-sharing-findmy-location",
        .object([
          "chatGuid": .string("iMessage;-;+15550000001"),
          "duration": .string("one-hour"),
        ])
      ),
      (
        "stop-sharing-findmy-location",
        .object([
          "chatGuid": .string("iMessage;-;+15550000001")
        ])
      ),
    ]

    try await withHelperAndServer { transport, _ in
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
        // Whatever it failed with, it must not be "I have never heard of this".
        #expect(
          !reason.contains("unknown action"),
          "the helper does not recognise '\(action)'"
        )
      }
    }
  }

  /// A share duration the helper does not know must be refused BY NAME, listing what it
  /// would accept. The alternative — passing the string through to IMCore — is how a
  /// client asking for an hour ends up sharing indefinitely, with no error to notice.
  @Test("An unknown share duration is refused with the accepted values")
  func unknownShareDurationIsRefused() async throws {
    try await withHelperAndServer { transport, _ in
      var reason = ""
      do {
        _ = try await transport.request(
          action: "start-sharing-findmy-location",
          data: .object([
            "chatGuid": .string("iMessage;-;+15550000001"),
            "duration": .string("forever"),
          ]),
          timeout: .seconds(5)
        )
      } catch PrivateAPIError.rejectedByMessages(let text) {
        reason = text
      }
      #expect(reason.contains("unknown share duration"))
      #expect(reason.contains("one-hour"))
    }
  }

  /// `findmy-status` ANSWERS rather than failing.
  ///
  /// This is the call a client makes to decide whether to show FindMy at all, so an error
  /// would be indistinguishable from the server being broken — a Mac that has never been
  /// signed into iCloud has to get a reply saying so.
  ///
  /// The VALUES are not pinned, deliberately. `IMFMFSession` is an IMCore class, and
  /// whether it resolves in this process depends on whether another suite has already
  /// dlopened IMCore — so a machine-state assertion here would pass or fail on test
  /// ordering. What is asserted is the shape and its one invariant: no backend means not
  /// available.
  @Test("Find My status always answers, whatever this machine has")
  func findMyStatusAlwaysAnswers() async throws {
    try await withHelperAndServer { transport, _ in
      let reply = try await transport.request(
        action: "findmy-status", data: .object([:]), timeout: .seconds(5)
      )
      let backend = try #require(reply?["backend"]?.stringValue)
      #expect(["findmy-locate", "legacy-fmf", "none"].contains(backend))
      #expect(reply?["available"]?.boolValue != nil)
      #expect(reply?["provisioned"]?.boolValue != nil)

      if backend == "none" {
        #expect(reply?["available"]?.boolValue == false)
      }
    }
  }

  /// A missing required field must be refused by the helper rather than reaching IMCore
  /// with a nil it will mishandle.
  @Test("A request missing a required field is refused by name")
  func missingFieldIsRefused() async throws {
    try await withHelperAndServer { transport, _ in
      var reason = ""
      do {
        // `send-message` needs both chatGuid and message.
        _ = try await transport.request(
          action: "send-message", data: .object([:]), timeout: .seconds(5)
        )
      } catch PrivateAPIError.rejectedByMessages(let text) {
        reason = text
      }
      #expect(reason.contains("chatGuid"))
    }
  }

  /// The server reads `error: ""` as SUCCESS, so an error message must never be empty —
  /// an unhelpful string beats a failure that silently reads as a success.
  @Test("Every error description is non-empty")
  func errorDescriptionsAreNeverEmpty() {
    let errors: [any Error] = [
      PrivateAPIError.notImplemented(method: "x"),
      PrivateAPIError.unavailableOnThisOS(method: "x", requires: "macOS 26"),
      PrivateAPIError.rejectedByMessages(reason: ""),
      PrivateAPIError.notConnected,
      PrivateAPIError.timedOut(method: "x"),
    ]
    for error in errors {
      #expect(!HelperDispatch.describe(error).isEmpty)
    }
  }

  /// Several requests in flight at once must each get their own reply. The helper answers
  /// on a task per request, so replies can and do come back out of order.
  @Test("Concurrent requests are each correlated to their own reply")
  func concurrentRequestsAreCorrelated() async throws {
    try await withHelperAndServer { transport, _ in
      // `search-messages` is the one action deliberately left unported — the server
      // answers the same question from chat.db, faster and over the full history.
      let requests: [(action: String, data: WireJSON)] = [
        ("search-messages", .object(["query": .string("a")])),
        ("no-such-action", .object([:])),
        ("search-messages", .object(["query": .string("b")])),
      ]
      var reasons: [String] = []

      await withTaskGroup(of: String.self) { group in
        for request in requests {
          group.addTask {
            do {
              _ = try await transport.request(
                action: request.action, data: request.data, timeout: .seconds(5)
              )
              return "ok"
            } catch PrivateAPIError.rejectedByMessages(let reason) {
              return reason
            } catch {
              return "other"
            }
          }
        }
        for await reason in group { reasons.append(reason) }
      }

      #expect(reasons.count == 3)
      // Each got its OWN answer rather than one reply satisfying all three.
      #expect(reasons.contains { $0.contains("unknown action") })
      #expect(reasons.filter { $0.contains("not implemented") }.count == 2)
    }
  }
}
