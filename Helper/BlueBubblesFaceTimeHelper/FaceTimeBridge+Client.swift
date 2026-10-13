//  FaceTimeBridge+Client
//  The one long-lived `TUConversationManagerXPCClient`: registered, its initial state fetched
//  before anything reads it, and registered again when the daemon says so. Also the hard host
//  guard every FaceTime entry point checks before it reaches TelephonyUtilities.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FaceTimeBridge {

  // MARK: - The long-lived conversation client

  /// Refuses to touch TelephonyUtilities anywhere but FaceTime.app.
  ///
  /// This is a HARD guard, not an optimisation. `TUConversationManagerXPCClient` and
  /// `TUCallCenter` are backed by an XPC registration that only FaceTime.app holds;
  /// constructing and registering them in any other process (Messages, or a test host)
  /// traps inside TelephonyUtilities and takes the process down. The same dylib is injected
  /// into both Messages and FaceTime, so every FaceTime entry point checks the host first
  /// and reports `unavailableOnThisOS` (a recognised-but-unavailable answer) rather than
  /// reaching for a call that will abort.
  ///
  /// `HelperHostGuard.isRunning(in:)`, not `shouldRun`: the socket override that lets a test
  /// START a helper outside its app must not let it reach TelephonyUtilities there.
  static func requireFaceTimeHost() throws {
    guard HelperHostGuard.isRunning(in: HelperHost.faceTime) else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "FaceTime",
        requires: "the helper to be running inside FaceTime.app; this host is "
          + (HelperHostGuard.currentHost ?? "unknown")
      )
    }
  }

  /// Stands up the long-lived client if it is not already up.
  ///
  /// Idempotent and cheap after the first call. The registration and initial-state fetch are
  /// awaited so the first operation does not race an unpopulated client: the precise race
  /// that makes the old helper return empty lists.
  ///
  /// CONCURRENT callers share one registration through `clientSetup`. `conversationClient`
  /// is assigned before the first await, so without this a second caller arriving in that
  /// window would take the reuse branch and re-run `registerWithCompletionHandler:` and
  /// `fetchInitialStateWithCompletionHandler:` against a client that was mid-registration,
  /// then set `clientReady` on its own.
  @discardableResult
  static func ensureClient() async throws -> AnyObject {
    try requireFaceTimeHost()
    if let client = conversationClient, clientReady { return client }

    // Someone else is already doing this: wait for theirs rather than starting a second.
    if let inFlight = clientSetup {
      try await inFlight.value
      guard let client = conversationClient else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "the FaceTime conversation client went away during setup"
        )
      }
      return client
    }

    let setup = Task<Void, any Error> { _ = try await performClientSetup() }
    clientSetup = setup
    defer { clientSetup = nil }
    try await setup.value
    guard let client = conversationClient else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "could not construct the FaceTime conversation client"
      )
    }
    return client
  }

  private static func performClientSetup() async throws -> AnyObject {
    let client: AnyObject
    if let existing = conversationClient {
      client = existing
    } else {
      guard let type = IMCoreRuntime.lookUpClass("TUConversationManagerXPCClient") else {
        throw PrivateAPIError.unavailableOnThisOS(
          method: "FaceTime",
          requires: "TUConversationManagerXPCClient (is the helper in FaceTime.app?)"
        )
      }
      // Allocated and initialised in ONE call: `-init` consumes the allocation's +1, so
      // an uninitialised object held here would be a reference the initialiser has already
      // disposed of. See `IMCoreRuntime.create`.
      guard let initialized = try? IMCoreRuntime.create(type, "init") else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "could not construct the FaceTime conversation client"
        )
      }
      conversationClient = initialized
      client = initialized
      // NO delegate installed. `TUConversationManagerDataSourceDelegate` is a large
      // protocol, and `TUConversationManagerXPCClient` calls its methods WITHOUT
      // `respondsToSelector:` guards: `handleServerDisconnect` invokes one on the
      // delegate, and an incomplete shim there is `doesNotRecognizeSelector:` →
      // `abort()`, which crashes FaceTime.app. Measured. The link, dial, answer and
      // admit paths do not need the delegate, and Flow C's "wait for join" is done by
      // POLLING `faceTimeMembers` on the server, so the push event is not required to
      // ship. A delegate can be added later only if EVERY protocol method is
      // implemented.
      observeReconnect()
    }

    // Register, then fetch initial state. Both are completion-based; both are awaited so
    // the client is actually usable when this returns.
    //
    // `clientReady` is set only when BOTH completions fired. A timeout or a refused
    // invoke leaves it false, so this call throws and the next one retries the
    // registration, rather than every later call reading an unpopulated client and
    // reporting "not waiting" or "no such conversation" for state it never fetched.
    try await callAwaitingCompletion(client, "registerWithCompletionHandler:")
      .outcome.require("registerWithCompletionHandler:")
    try await callAwaitingCompletion(client, "fetchInitialStateWithCompletionHandler:")
      .outcome.require("fetchInitialStateWithCompletionHandler:")
    clientReady = true
    return client
  }

  /// Re-registers when the daemon posts its "clients should connect" notification.
  ///
  /// `CSDConversationManagerClientsShouldConnectNotification` is the daemon telling clients
  /// to (re)establish. Observing it is how a long-lived client survives the daemon cycling
  /// without going silently stale, the failure mode a throwaway client never even reaches,
  /// because it is destroyed inside a single request.
  private static func observeReconnect() {
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("CSDConversationManagerClientsShouldConnectNotification"),
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        clientReady = false
        // Nothing awaits this attempt, so its failure is logged here. It is not lost:
        // `clientReady` stays false, so the next FaceTime operation's `ensureClient()` runs
        // the registration again and throws to that caller if it fails a second time.
        Task {
          do {
            try await ensureClient()
          } catch {
            BlueBubblesFaceTimeHelper.log.error(
              "Could not re-register the FaceTime conversation client: \(error)")
          }
        }
      }
    }
  }
}
