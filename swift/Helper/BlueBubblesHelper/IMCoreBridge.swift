//  BlueBubblesHelper
//  Injected into Messages.app via DYLD_INSERT_LIBRARIES. This is where the Objective-C
//  helper (BlueBubblesApp/bluebubbles-helper) gets ported to Swift, method by method.
//
//  HOW TO PORT
//  Every method below throws .notImplemented and names its counterpart in
//  Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m. Fill in bodies one at a time.
//  The server already compiles against this contract, so nothing on that side changes as
//  methods land, and a partial port is shippable: unported methods report as unavailable.
//
//  Two reference implementations are worth reading before starting:
//    - The shipping ObjC helper. Authoritative for behaviour, and the only source for the
//      per-macOS-version workarounds it has accumulated.
//    - Beeper's Barcelona (https://github.com/beeper/barcelona), Apache-2.0 like this
//      project, already in Swift. The best map of which IMCore classes and selectors to
//      call. Take its IMCore call sites, not its architecture: it runs standalone on an
//      AMFI-disabled machine, whereas this runs inside Messages.app. Expect drift: it
//      targets the Big Sur / Monterey era. Vendor selectively with a NOTICE entry.
//
//  This target depends on BBPrivateAPIContract and nothing else. It must not pull server
//  code into another process's address space.
//
//  See `.claude/docs/private-api.md`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

/// Implements the Private API surface against IMCore, from inside Messages.app.
/// `@MainActor`, and that is the load-bearing part.
///
/// IMCore requires the main thread and enforces it with `dispatch_assert_queue()`, which
/// raises `EXC_BREAKPOINT`: `__builtin_trap`, not an `NSException`. No `@try/@catch` can
/// catch it; the process dies. Measured: a send from a cooperative-pool thread delivered the
/// message and then took Messages down, with `_dispatch_assert_queue_fail` at the top of the
/// crash report.
///
/// The shipping Objective-C helper never hit this, and not because it handled threading
/// carefully: its socket library was constructed with
/// `delegateQueue:dispatch_get_main_queue()` (NetworkController.m:49), so every callback and
/// therefore every IMCore call beneath it was already on the main thread. It got the property
/// for free and never had to name it.
///
/// This helper reads on its own `Thread` and dispatches into Swift `Task`s, which run on the
/// cooperative pool: never main. So the guarantee has to be stated, and `@MainActor` is how
/// Swift states it: the isolation is checked at compile time, and `await` **suspends** rather
/// than blocking. Forcing the hop with `DispatchQueue.main.sync` inside `IMCoreRuntime`
/// also works, but blocks a helper thread on every call and cannot run under `swift test` at
/// all, because a test host does not drain the main queue.
@MainActor
public final class IMCoreBridge: PrivateAPI {

  public init() {}

  /// The one bridge, reached from the dispatch point.
  ///
  /// A singleton because it is stateless and because constructing it requires the main
  /// actor: a socket client running on its own thread has nowhere to build one. Reaching
  /// it here is what lets the isolation flow from the request handler rather than from the
  /// object graph.
  public static let shared = IMCoreBridge()

  /// Runs an IMCore call and translates its failure into the contract's vocabulary.
  ///
  /// The distinction preserved here is the one that matters to a user: a selector that
  /// moved in a macOS release is `unavailableOnThisOS` and will never work here, while a
  /// rejection from Messages is `rejectedByMessages` and might work next time. Collapsing
  /// them into one error would make an OS upgrade look like a transient failure.
  /// Wraps a call into IMCore, turning its two lookup failures into contract errors.
  ///
  /// `method` defaults to `#function`, which is evaluated AT THE CALL SITE, so the error
  /// names `sendMessage(_:)` rather than `translating(_:)`. Evaluated inside the body it
  /// would name the wrapper every time, making every "unavailable on this macOS" report
  /// identical.
  func translating<T>(
    _ method: String = #function,
    _ body: () throws -> T
  ) throws -> T {
    do {
      return try body()
    } catch let lookup as IMCoreLookupError {
      throw PrivateAPIError.unavailableOnThisOS(
        method: method, requires: lookup.description
      )
    } catch let shim as PrivateAPIErrorShim {
      throw PrivateAPIError.rejectedByMessages(reason: shim.description)
    }
  }

  /// The chat a loaded message item belongs to.
  ///
  /// Edits and retractions are sent BY the chat, but a client addresses them by message
  /// GUID alone, so the chat has to be recovered from the item. IMCore exposes it through
  /// the item's own chat identifier, and a message that names a chat IMCore has forgotten
  /// is a real state (a deleted conversation), so it is reported rather than crashed on.
  static func chat(owning item: AnyObject, fallbackGUID: String?) throws -> IMChat {
    let identifier =
      (try? IMCoreRuntime.string(item, "chatIdentifier"))
      ?? (try? IMCoreRuntime.string(item, "chatGUID"))
      ?? nil

    for candidate in [identifier, fallbackGUID].compactMap({ $0 }) {
      if let chat = ((try? IMChatRegistry.chat(guid: candidate)) ?? nil) {
        return chat
      }
    }
    throw PrivateAPIErrorShim.rejected(
      "could not find the conversation this message belongs to"
    )
  }

  /// The ChatKit conversation for a chat GUID.
  ///
  /// Every write goes through one of these. Recovering the conversation from the message
  /// instead cannot work: an `IMMessageItem` fetched by GUID reports `chatIdentifier = nil`.
  /// The chat GUID travels with the request, resolved by the server from chat.db.
  func requireConversation(_ chat: ChatIdentifier) throws -> CKConversation {
    guard let conversation = try CKConversationList.conversation(guid: chat.rawValue) else {
      throw PrivateAPIErrorShim.rejected(
        "ChatKit does not know a conversation with GUID \(chat.rawValue)"
      )
    }
    return conversation
  }

  /// PORTED. ObjC: `[IMDaemonController sharedController].connected`.
  ///
  /// This is the helper's own view of whether IMCore is usable: distinct from whether the
  /// SERVER can reach the helper, which the transport answers. Both have to be true, and
  /// conflating them makes "Messages is signed out" indistinguishable from "the helper is
  /// not injected".
  public var isConnected: Bool {
    get async { IMAccountController.isDaemonConnected() }
  }

  /// Inbound events come from swizzled Messages.app methods, not from polling.
  /// See `EventHooks` below for the hook table and its fragility.
  public nonisolated var events: AsyncStream<PrivateAPIEvent> {
    AsyncStream { $0.finish() }
  }
}

// MARK: - Event observation
//
// GOAL: NO SWIZZLING. Swizzling is a debugging and last-resort tool, not an architecture.
//
// The ObjC helper obtains all four inbound events by swizzling Messages.app methods, and
// contains no NSNotificationCenter observers at all. That is what we are moving away from,
// not what we are porting, so there is no rung-1 or rung-2 implementation to copy, and this
// is investigation rather than translation.
//
// For each event, find the HIGHEST rung that actually works and stop there:
//
//   1. Observe an IMCore-posted NSNotification.
//      In-process, non-invasive, survives selector churn. Try this first, every time.
//
//   2. Register as an additional IMDaemonListener and implement the delegate methods.
//      Barcelona proves the protocol carries these events (it runs standalone and cannot
//      swizzle). Unverified: whether a SECOND listener can register inside a process that
//      already has one. Worth establishing early: it likely covers several events at once.
//
//   3. Swizzle a message-layer method. Fallback. If you land here, record in a comment which
//      rung-1 and rung-2 attempts were tried and how they failed, so the next person does
//      not repeat the search.
//
//   4. Swizzle a UI-layer method. Last resort, and a defect to be replaced, not a solution.
//
// What the ObjC helper does today, as a starting map (NOT a target):
//
//   IMChat._handleIncomingItem:              rung 3  -> typing (checks isIncomingTypingMessage
//                                                       / isCancelTypingMessage)
//   IMAccount._registrationStatusChanged:    rung 3  -> aliases-removed (filters userInfo for
//                                                       __kIMAccountAliasesRemovedKey)
//   FMFSessionDataManager.setLocations:      rung 3  -> new-findmy-location
//   CKConversationListStandardCell
//       .setShowTypingIndicator:             rung 4  -> typing on macOS 26 only, after the
//                                                       IMChat path stopped delivering
//
// IF SWIZZLING SURVIVES ANYWAY, two rules:
//
//   - ZKSwizzle is Objective-C and does not port. Swift needs a runtime shim: an @objc
//     replacement on an NSObject subclass plus a saved IMP to call through.
//   - A crash here takes the user's Messages.app with it. Guard every call with
//     respondsToSelector and degrade to "this event stops firing" rather than trapping.
//     A missing typing indicator is an annoyance; losing Messages is not.
// IMPLEMENTED for typing indicators; see EventObservation.swift, which reaches RUNG 2 via
// `IMDaemonController.listener.addHandler:` and swizzles nothing.
//
// Still unresolved, and each is recorded in TODO.md with what was measured rather than left
// as an unexplained gap:
//
//   aliases-removed        No rung-1 or rung-2 path found on macOS 26.5.2. The listener
//                          exposes no selector matching "alias", and IMCore does not export
//                          __kIMAccountAliasesChangedNotification (checked with dlsym), so
//                          there is no notification to observe by name either. The ObjC
//                          helper's rung-3 swizzle of IMAccount._registrationStatusChanged:
//                          is still PRESENT and remains the only known route.
//
//   new-findmy-location    RUNG 1 EXISTS, and the earlier "no path at any rung" reading was
//                          a false negative. FMFSessionDataManager is indeed gone and the
//                          daemon listener indeed exposes no "location" selector, but IMCore
//                          posts __kIMFMFSessionLocationReceivedNotification (object: an
//                          IMFindMyHandle, userInfo: nil) and four siblings: the full table
//                          is in docs/headers/README.md. They are STRING LITERALS in IMCore,
//                          not exported symbols, so the dlsym check that dismissed them was
//                          asking the wrong question; observe them by name.
//                          Not yet wired: the FindMy work so far is request/response, and
//                          the event needs a decision about how often a position should be
//                          pushed. Tracked in TODO.md.

/// Exported, empty, and referenced by nothing.
///
/// The dylib's constructor in `Helper/HelperBootstrap/bootstrap.c` calls
/// `bluebubbles_helper_main` (`HelperMain.swift`), which is what connects to the server's
/// socket and installs the hooks above. This symbol is not on that path.
@_cdecl("bluebubbles_helper_init")
public func bluebubblesHelperInit() {
}
