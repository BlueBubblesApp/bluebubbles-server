//  MultiUserTests
//  Two macOS accounts, logged in at once, each running a server.
//
//  An ordinary setup with fast user switching, and it means two Messages.app processes, two
//  injected helpers and two servers on one machine. Everything keyed to a location or a port
//  has to be keyed per USER, or the two accounts fight over it — and the failures are not
//  loud. They look like "the Private API stopped working for one of us".
//
//  What is genuinely isolated by construction, and what is not, is worth pinning rather than
//  reasoning about each time it comes up.

import BBPrivateAPIContract
import BBSettings
import Foundation
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Multiple macOS users")
struct MultiUserTests {

  // MARK: - Isolated by construction

  @Test("Each account gets its own Private API socket path")
  func socketPathIsPerUser() {
    // Derived from `getpwuid`, which is not container-redirected and is per user. Two
    // accounts land on two different homes, so two different containers, so two
    // different sockets — there is nothing to collide over.
    let path = SocketLocation.privateAPISocket
    #expect(path.hasPrefix(SocketLocation.realHomeDirectory))
    #expect(path.hasSuffix("/Library/Containers/com.apple.MobileSMS/Data/private-api.sock"))

    // And it is rooted at the real home, never a shared or temporary location — both of
    // which the sandbox refuses anyway.
    #expect(!path.hasPrefix("/tmp"))
    #expect(!path.hasPrefix("/Users/Shared"))
    #expect(!path.hasPrefix("/var"))
  }

  @Test("The socket lives inside Messages' container")
  func socketIsInsideTheContainer() {
    // Load-bearing, not incidental. The sandbox refuses a connect to a Unix socket
    // OUTSIDE the container — measured, see `.claude/docs/private-api.md` § "The sandbox,
    // and where the socket must live" — so moving this back to the server's own Application
    // Support directory silently breaks the Private API for everyone.
    #expect(SocketLocation.privateAPISocket.hasPrefix(SocketLocation.messagesContainer))
  }

  @Test("The socket path fits in sun_path")
  func socketPathFits() {
    // `sun_path` is a fixed 104-byte field and a longer path is TRUNCATED, not rejected:
    // the server would bind one path and the helper connect to another, with neither
    // reporting anything wrong. The container path is long, so the headroom is real but
    // not generous.
    #expect(SocketLocation.isUsableSocketPath(SocketLocation.privateAPISocket))
    #expect(
      SocketLocation.privateAPISocket.utf8.count
        <= SocketLocation.maximumSocketPathLength)
  }

  @Test("An over-long path is rejected rather than truncated")
  func overLongPathIsRejected() {
    let tooLong = "/Users/" + String(repeating: "a", count: 200) + "/x.sock"
    #expect(!SocketLocation.isUsableSocketPath(tooLong))
    #expect(!SocketLocation.isUsableSocketPath(""))
  }

  @Test("There is no TCP bridge left to collide over")
  func noTCPBridgeRemains() {
    // The loopback bridge is gone, and with it the uid-derived port that existed to keep
    // two accounts apart. Isolation now comes from the path, which is per-home — a
    // stronger property, since loopback has no user-based access control at all and one
    // account could reach another's port.
    #expect(!Settings.allKeys.contains("private_api_legacy_bridge"))
  }

  // MARK: - NOT isolated, and handled

  /// The one thing two accounts genuinely collide over.
  @Test("A port already in use is reported as such, not as errno 48")
  func portConflictIsDiagnosed() {
    // `socket_port` defaults to 1234 for everybody and binds 0.0.0.0, so the second
    // account's server cannot bind. That is unavoidable — it is one machine and one port
    // — so the job is to say so in terms that name the cause and the fix.
    struct AddressInUse: Error, CustomStringConvertible {
      var description: String { "bind failed: addressInUse(errno: 48)" }
    }

    let error = HTTPListener.bindError(AddressInUse(), port: 1234)
    guard case .portInUse(let port) = error else {
      Issue.record("an in-use port was not recognised: \(error)")
      return
    }
    #expect(port == 1234)
    // The remedy is in the message, because the cause is not guessable.
    #expect(error.description.contains("another macOS user"))
    #expect(error.description.contains("Local Port"))
  }

  @Test("Other bind failures are not mislabelled as a port conflict")
  func otherBindFailuresAreDistinct() {
    struct Denied: Error, CustomStringConvertible {
      var description: String { "permission denied" }
    }
    guard case .bindFailed = HTTPListener.bindError(Denied(), port: 1234) else {
      Issue.record("an unrelated failure was reported as a port conflict")
      return
    }
  }

  /// The reason the readiness probe was replaced.
  @Test("Binding waits for the server's own signal, not for the port to answer")
  func readinessIsNotInferredFromConnecting() async throws {
    // Probing the port by connecting cannot tell "I bound it" from "someone else has
    // it". With two accounts on the default port, the second server's bind fails, its
    // probe connects to the FIRST account's listener, and it reports itself as
    // listening while serving nothing at all.
    struct BindRefused: Error {}
    let signal = BindingSignal()
    await signal.fail(BindRefused())

    await #expect(throws: BindRefused.self) {
      try await signal.waitUntilBound(timeout: .seconds(1))
    }
  }

  @Test("A bound signal releases its waiter")
  func boundSignalReleases() async throws {
    let signal = BindingSignal()
    async let waiting: Void = signal.waitUntilBound(timeout: .seconds(5))
    await signal.markBound()
    try await waiting
  }

  @Test("A bind that never resolves times out rather than hanging startup")
  func bindTimesOut() async {
    // Otherwise a bind that neither succeeds nor reports a failure holds the whole
    // service graph forever, and the registry has nothing to time out against.
    let signal = BindingSignal()
    await #expect(throws: (any Error).self) {
      try await signal.waitUntilBound(timeout: .milliseconds(50))
    }
  }
}
