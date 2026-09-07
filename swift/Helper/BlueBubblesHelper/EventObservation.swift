//  EventObservation
//  Inbound events, obtained WITHOUT swizzling Messages.app.
//
//  The shipping Objective-C helper gets all of its inbound events by swizzling — four hooks,
//  one of them into ChatKit's UI layer — and contains no notification observers at all. That
//  is the most version-fragile thing in the whole project: a private selector is renamed, the
//  hook silently stops firing, and the user reports "typing indicators stopped working" with
//  nothing in any log. This file is the alternative the observation ladder went looking for.
//
//  **Typing indicators land on rung 2.** `IMDaemonController`'s listener exposes `addHandler:`,
//  so a second observer can be attached alongside the one Messages.app already owns, and it
//  receives the same message-layer callbacks. No method is replaced, nothing is swizzled, and
//  a selector that disappears degrades to "this event stops firing" rather than corrupting
//  the host process.
//
//  What was measured on macOS 26.5.2 (25F84), by loading IMCore and reading the runtime:
//
//    _IMLegacyDaemonListener        127 methods; `addHandler:`, `removeHandler:`, `handlers`
//    …messageReceived:              PRESENT — `account:chat:style:chatProperties:messageReceived:`
//    …messagesReceived:             PRESENT — the batched form
//    selectors matching "typing"    NONE — typing arrives as a message item, not its own callback
//    selectors matching "alias"     NONE — see `aliases-removed` below
//    selectors matching "location"  NONE — see `new-findmy-location` below
//
//  See `.claude/docs/private-api.md` and docs/OBSERVATION_LADDER.md.

import Foundation
import HelperShared

/// What an observed event carries back to the server, in the wire vocabulary the shipping
/// helper established. Deliberately the SAME names the Objective-C helper emits — the server's
/// `HelperEventDecoder` is written against those, and a rename here would be a silent break.
public struct ObservedEvent: Sendable, Equatable {
  public let name: String
  public let payload: [String: String]

  public init(name: String, payload: [String: String]) {
    self.name = name
    self.payload = payload
  }

  static func typing(chat: String, isTyping: Bool) -> ObservedEvent {
    ObservedEvent(
      name: isTyping ? "started-typing" : "stopped-typing",
      payload: ["chatGuid": chat]
    )
  }
}

public enum EventObservation {

  /// Where observed events go. Set once at startup by `HelperMain`.
  ///
  /// A closure rather than a delegate because the listener object below is constructed by
  /// the Objective-C runtime and cannot carry Swift generics or an actor reference.
  /// `nonisolated(unsafe)` is honest here: it is written once before the listener is
  /// registered and only read afterwards.
  nonisolated(unsafe) static var emit: (@Sendable (ObservedEvent) -> Void)?

  /// Retained for the process lifetime. The listener holds its handlers WEAKLY — a handler
  /// that goes out of scope stops receiving callbacks and nothing reports it, which is a
  /// singularly annoying way to lose typing indicators.
  nonisolated(unsafe) private static var handler: DaemonEventHandler?

  /// Which rung of the observation ladder attached, reported to the server on registration.
  ///
  /// "none" is a real answer and a useful one — it means this macOS has moved the listener
  /// surface and inbound events are gone, which is otherwise indistinguishable from
  /// "nobody has typed at you yet".
  nonisolated(unsafe) public private(set) static var rung = "none"

  /// Attaches to IMCore's daemon listener.
  ///
  /// Returns whether it worked, so the caller can log one line rather than guessing. Every
  /// failure path is a normal, reportable state: this runs inside somebody's Messages.app,
  /// and a macOS that has moved these selectors must cost the user their typing indicators,
  /// not their Messages.
  @discardableResult
  public static func start(
    emit: @escaping @Sendable (ObservedEvent) -> Void
  ) -> Bool {
    self.emit = emit

    guard
      let controller = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMDaemonController", accessors: ["sharedController", "sharedInstance"]
      )
    else {
      BlueBubblesHelper.Logging.error("IMDaemonController is unavailable; inbound events are off")
      return false
    }

    // `listener` is the fan-out object; the controller itself is an IMDistributingProxy
    // on this OS and does not take handlers.
    guard let listener = try? IMCoreRuntime.send(controller, "listener") else {
      BlueBubblesHelper.Logging.error("IMDaemonController has no -listener; inbound events are off")
      return false
    }

    guard listener.responds(to: NSSelectorFromString("addHandler:")) else {
      // The rung-2 path is gone on this OS. Reported rather than silently falling back
      // to a swizzle: a capability regression the user can be told about beats a
      // fragile hook nobody knows is there.
      BlueBubblesHelper.Logging.error(
        "listener does not respond to addHandler: on this macOS; typing indicators "
          + "are unavailable"
      )
      return false
    }

    let handler = DaemonEventHandler()
    Self.handler = handler
    do {
      try IMCoreRuntime.send(listener, "addHandler:", handler)
    } catch {
      BlueBubblesHelper.Logging.error("Could not register the daemon event handler: \(error)")
      Self.handler = nil
      return false
    }

    rung = "daemon-listener"
    BlueBubblesHelper.Logging.log("Registered as an additional IMDaemonListener handler (rung 2)")
    return true
  }

  public static func stop() {
    guard let handler,
      let controller = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMDaemonController", accessors: ["sharedController", "sharedInstance"]
      ),
      let listener = try? IMCoreRuntime.send(controller, "listener"),
      listener.responds(to: NSSelectorFromString("removeHandler:"))
    else { return }

    _ = try? IMCoreRuntime.send(listener, "removeHandler:", handler)
    Self.handler = nil
  }
}

// MARK: - The handler

/// An additional handler on IMCore's daemon listener.
///
/// Duck-typed on purpose: `IMDaemonListenerProtocol` is not a header we have, so this declares
/// only the selectors it wants and the runtime dispatches to them. That is also why every
/// method here is defensive — the listener will happily call a selector with arguments whose
/// shape we inferred rather than read from a header.
///
/// **This is not a swizzle.** Nothing is replaced; Messages.app's own handler continues to
/// receive everything it did before, and removing this one restores the process exactly.
final class DaemonEventHandler: NSObject {

  /// The message-layer callback, and the one that carries typing.
  ///
  /// There is no typing-specific callback on the listener — measured, not assumed: a dump of
  /// all 127 methods on `_IMLegacyDaemonListener` contains no selector matching "typing".
  /// Typing arrives the same way it does in the swizzled `IMChat._handleIncomingItem:` path:
  /// as an `IMMessageItem` flagged as a typing message, which is why the flags below are the
  /// same two the Objective-C helper checks.
  @objc(account:chat:style:chatProperties:messageReceived:)
  func account(
    _ account: Any?,
    chat: Any?,
    style: Any?,
    chatProperties: Any?,
    messageReceived item: Any?
  ) {
    handle(item: item, chatIdentifier: chat)
  }

  /// The batched form. Messages sent in quick succession arrive here instead, and a handler
  /// that implements only the singular version misses them — which presents as typing
  /// indicators that work "sometimes".
  @objc(account:chat:style:chatProperties:messagesReceived:)
  func account(
    _ account: Any?,
    chat: Any?,
    style: Any?,
    chatProperties: Any?,
    messagesReceived items: Any?
  ) {
    guard let items = items as? [Any] else { return }
    for item in items { handle(item: item, chatIdentifier: chat) }
  }

  /// Classifies one item and emits if it is a typing change.
  ///
  /// Wrapped so an unexpected shape cannot take Messages.app down with it. Every lookup goes
  /// through `responds(to:)` first, because these are private selectors on an object we
  /// were handed rather than one we built.
  private func handle(item: Any?, chatIdentifier: Any?) {
    guard let item = item as AnyObject?, let chat = Self.chatGUID(from: chatIdentifier)
    else { return }

    // `isIncomingTypingMessage` FIRST, then `isTypingMessage`, and the fallback is not
    // theoretical: the first spelling exists on NO macOS this project has a dump for —
    // not 26.5.2, not 15.6 — and `boolean` answers false for a selector that is absent.
    //
    // So this read was hardcoded false, the guard below could only ever be reached by a
    // CANCEL, and `isTyping && !isCancel` was then false as well: the helper emitted
    // `stopped-typing` and **`started-typing` could never fire at all**. Typing indicators
    // half-worked, in the direction nobody notices, with nothing in any log. Found by
    // `Tools/private-api/compare-releases.py` once `IMMessageItem` was finally dumped —
    // see `docs/SEQUOIA_COMPATIBILITY.md` §5.5.
    let isTyping =
      Self.boolean(item, "isIncomingTypingMessage")
      || Self.boolean(item, "isTypingMessage")
    let isCancel = Self.boolean(item, "isCancelTypingMessage")

    // Neither flag set means an ordinary message, which the server already learns about
    // from chat.db. Forwarding those would duplicate every message on the socket.
    guard isTyping || isCancel else { return }

    // `isTypingMessage` is not directional, and the selector it replaces was. Without this
    // the helper reports OUR OWN typing back to the client as though the other party were
    // typing — every keystroke the user makes in Messages.app, echoed to every connected
    // device. Absent `isFromMe`, treat the item as incoming: the callback this arrives on
    // is `messageReceived:`, which is inbound by construction.
    guard !Self.boolean(item, "isFromMe") else { return }

    EventObservation.emit?(.typing(chat: chat, isTyping: isTyping && !isCancel))
  }

  /// The chat's GUID, from whatever the listener handed us.
  ///
  /// The `chat` argument is documented nowhere. It arrives as an identifier string in some
  /// call shapes and as an `IMChat` in others, so both are handled rather than one being
  /// assumed — an assumption here fails as "typing indicators never fire", with no error.
  private static func chatGUID(from chat: Any?) -> String? {
    if let string = chat as? String, !string.isEmpty { return string }
    guard let object = chat as AnyObject? else { return nil }
    for accessor in ["guid", "chatIdentifier"] {
      let selector = NSSelectorFromString(accessor)
      guard object.responds(to: selector),
        let value = object.perform(selector)?.takeUnretainedValue() as? String,
        !value.isEmpty
      else { continue }
      return value
    }
    return nil
  }

  private static func boolean(_ target: AnyObject, _ selectorName: String) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector) else { return false }
    return (try? IMCoreRuntime.bool(target, selectorName)) ?? false
  }
}
