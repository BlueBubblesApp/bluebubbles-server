//  FaceTimeBridge
//  FaceTime against TelephonyUtilities, from inside FaceTime.app.
//
//  WHERE THIS RUNS, AND WHY IT IS A DIFFERENT HOST
//  Everything else in this helper runs inside Messages.app and drives IMCore. FaceTime's call
//  machinery (`TUCallCenter`, `TUConversationManagerXPCClient`) is registered with the call
//  daemons by **FaceTime.app**, not Messages, so these calls only mean anything when the
//  helper is injected into `com.apple.FaceTime`. The same dylib serves both hosts; the server
//  injects it into FaceTime.app for FaceTime features and routes FaceTime actions to that
//  connection (see the transport's per-process routing).
//
//  THE FINDING THIS FILE IS BUILT AROUND (docs/headers/FACETIME.md)
//  The shipping Objective-C FaceTime helper "almost never works," and the reason is not the
//  selectors; it is the XPC client lifecycle. `TUConversationManagerXPCClient` has no
//  `sharedInstance`; it must be REGISTERED and have its INITIAL STATE fetched before
//  `activeConversations` / `activatedConversationLinks` are real, and it must re-register when
//  the daemon says so. That helper `alloc/init`s a throwaway client inline on every call
//  and reads immediately, so those collections are empty and completions are torn down before
//  they fire. This file holds ONE long-lived client instead, registered and state-synced, and
//  `FaceTimeBridge+Client.swift` drives everything through it.
//
//  ONE FILE PER FLOW. This file declares the enum and every piece of static state the flows
//  share (the client, the idle camera's watch, the event emitter). Each `FaceTimeBridge+*`
//  file is one flow's functions: `+Client` (registration and the host guard), `+IdlePreview`
//  (the camera injection turns on), `+Links` (Flow A), `+Calls` (Flows B and C, and reading
//  a call), `+Members`, `+Alerts`, `+LinkInvalidation`, and `+Plumbing` (the call centre,
//  handles and the bounded completion wait every flow goes through).
//
//  UNTESTABLE HERE. Every call below needs FaceTime.app running with the dylib injected, which
//  needs SIP off; it cannot run under `swift test`. `IMCoreRuntime` keeps a moved selector
//  from crashing the host; `FaceTimeSelectorTests` pins the selector names against the live
//  runtime. Behaviour is validated on a real Mac.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperObjC
import HelperShared
import ObjectiveC
import os

@MainActor
enum FaceTimeBridge {

  // MARK: - The idle camera's watch

  /// Whether the background watchdog is scheduled.
  static var isWatching = false

  /// How long the next check waits. Doubles after each quiet one.
  static var pollInterval = shortestPollInterval
  /// Consecutive checks that found nothing to stop.
  static var quietPolls = 0

  static let shortestPollInterval: TimeInterval = 2
  static let longestPollInterval: TimeInterval = 60
  /// Quiet checks before the watch stops altogether and waits for an activation change.
  static let quietPollsBeforeStopping = 8

  // MARK: - The long-lived conversation client

  /// The one registered `TUConversationManagerXPCClient`, held for the helper's lifetime.
  ///
  /// This is the whole fix. It is created once, registered and its initial state fetched,
  /// with no delegate installed (`performClientSetup` says why); every link and member
  /// operation goes through it. Reading it
  /// before it has initial state returns empty collections, which is exactly the bug the
  /// throwaway-per-call approach ships, so `ensureClient()` blocks new callers only until
  /// the first registration completes, then reuses it.
  static var conversationClient: AnyObject?
  static var clientReady = false
  /// The registration in flight, so concurrent callers wait on one rather than racing.
  ///
  /// `Task<Void, …>`, not `Task<AnyObject, …>`: an IMCore object is not `Sendable`, and it
  /// does not need to cross anything here — everything on this type is main-actor isolated,
  /// so a waiter reads `conversationClient` itself once the task completes.
  static var clientSetup: Task<Void, any Error>?

  // MARK: - Events

  /// Where event frames go. Set by `FaceTimeHelperMain` from the dylib constructor's
  /// thread before the socket connects, and read from the conversation delegate's queue,
  /// neither of which is the main actor, so it is lock-guarded rather than isolated.
  nonisolated private static let emitter = OSAllocatedUnfairLock<
    (@Sendable (HelperEventName, WireObject) -> Void)?
  >(initialState: nil)

  nonisolated static func setEmitter(
    _ emit: @escaping @Sendable (HelperEventName, WireObject) -> Void
  ) {
    emitter.withLock { $0 = emit }
  }

  /// Emits an event frame to the server, or drops it if nothing is listening yet.
  nonisolated static func emit(_ event: HelperEventName, _ payload: WireObject) {
    emitter.withLock { $0 }?(event, payload)
  }
}
