//  EventObservation
//  Inbound events, obtained WITHOUT swizzling Messages.app.
//
//  The shipping Objective-C helper gets all of its inbound events by swizzling (four hooks,
//  one of them into ChatKit's UI layer) and contains no notification observers at all. That
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
//    …messageReceived:              PRESENT: `account:chat:style:chatProperties:messageReceived:`
//    …messagesReceived:             PRESENT: the batched form
//    selectors matching "typing"    NONE: typing arrives as a message item, not its own callback
//    selectors matching "alias"     NONE: see `aliases-removed` below
//    selectors matching "location"  NONE: see `new-findmy-location` below
//
//  See `.claude/docs/private-api.md` and docs/OBSERVATION_LADDER.md.

import BBPrivateAPIContract
import Foundation
import HelperShared
import os

/// What an observed event carries back to the server, in the wire vocabulary the shipping
/// helper established. Deliberately the SAME names the Objective-C helper emits: the server's
/// `HelperEventDecoder` is written against those, and a rename here would be a silent break.
public struct ObservedEvent: Sendable, Equatable {
  public let name: HelperEventName
  public let payload: [WireKey: String]

  public init(name: HelperEventName, payload: [WireKey: String]) {
    self.name = name
    self.payload = payload
  }

  static func typing(chat: String, isTyping: Bool) -> ObservedEvent {
    ObservedEvent(
      name: isTyping ? .startedTyping : .stoppedTyping,
      payload: [.chatGuid: chat]
    )
  }
}

public enum EventObservation {

  /// Where observed events go. Set once at startup by `HelperMain`.
  ///
  /// A closure rather than a delegate because the listener object below is constructed by
  /// the Objective-C runtime and cannot carry Swift generics or an actor reference. Written
  /// from the dylib constructor's thread and read from IMCore's callback thread, so it is
  /// lock-guarded rather than isolated.
  private static let emitter = OSAllocatedUnfairLock<(@Sendable (ObservedEvent) -> Void)?>(
    initialState: nil)

  static func emit(_ event: ObservedEvent) {
    emitter.withLock { $0 }?(event)
  }

  /// Retained for the process lifetime. The listener holds its handlers WEAKLY: a handler
  /// that goes out of scope stops receiving callbacks and nothing reports it, which is a
  /// singularly annoying way to lose typing indicators.
  private static let handler = OSAllocatedUnfairLock<DaemonEventHandler?>(initialState: nil)

  /// Which rung of the observation ladder attached, reported to the server on registration.
  ///
  /// "none" is a real answer and a useful one: it means this macOS has moved the listener
  /// surface and inbound events are gone, which is otherwise indistinguishable from
  /// "nobody has typed at you yet".
  public static var rung: String { attachedRung.withLock { $0 } }
  private static let attachedRung = OSAllocatedUnfairLock<String>(initialState: "none")

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
    emitter.withLock { $0 = emit }

    guard
      let controller = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMDaemonController", accessors: ["sharedController", "sharedInstance"]
      )
    else {
      BlueBubblesHelper.log.error("IMDaemonController is unavailable; inbound events are off")
      return false
    }

    // `listener` is the fan-out object; the controller itself is an IMDistributingProxy
    // on this OS and does not take handlers.
    guard let listener = try? IMCoreRuntime.send(controller, "listener") else {
      BlueBubblesHelper.log.error("IMDaemonController has no -listener; inbound events are off")
      return false
    }

    guard IMCoreRuntime.responds(listener, to: "addHandler:") else {
      // The rung-2 path is gone on this OS. Reported rather than silently falling back
      // to a swizzle: a capability regression the user can be told about beats a
      // fragile hook nobody knows is there.
      BlueBubblesHelper.log.error(
        "listener does not respond to addHandler: on this macOS; typing indicators "
          + "are unavailable"
      )
      return false
    }

    let handler = DaemonEventHandler()
    Self.handler.withLock { $0 = handler }
    do {
      try IMCoreRuntime.send(listener, "addHandler:", handler)
    } catch {
      BlueBubblesHelper.log.error("Could not register the daemon event handler: \(error)")
      Self.handler.withLock { $0 = nil }
      return false
    }

    attachedRung.withLock { $0 = "daemon-listener" }
    BlueBubblesHelper.log.info("Registered as an additional IMDaemonListener handler (rung 2)")
    return true
  }
}

// MARK: - The handler

/// An additional handler on IMCore's daemon listener.
///
/// Duck-typed on purpose: `IMDaemonListenerProtocol` is not a header we have, so this declares
/// only the selectors it wants and the runtime dispatches to them. That is also why every
/// method here is defensive: the listener will happily call a selector with arguments whose
/// shape we inferred rather than read from a header.
///
/// **Inferring an argument TYPE is the one thing that is not survivable, and it is not
/// necessary here.** A selector we guess wrong about simply never fires. An argument we type
/// wrong is dispatched into: `style:` is `unsigned char`, and declaring it `Any?` made the
/// Swift thunk treat the raw value (`IMChatStyle` is `0x2D` or `0x2B`) as an object pointer
/// and retain it, which segfaults Messages.app inside Apple's own callback. Reproduced both
/// ways it can be dispatched, by a typed function-pointer call and through `NSInvocation`.
///
/// `_IMLegacyDaemonListener` IS dumped, in all three release folders, and has been the whole
/// time: `docs/headers/macos-{14.6.1,15.6.1,26.5.2}/_IMLegacyDaemonListener.h:81` each
/// declare `- (void)account:(id) chat:(id) style:(unsigned char) chatProperties:(id)
/// messageReceived:(id)`. The live runtime on a Tahoe machine agrees, reporting the encoding
/// as `v52@0:8@16@24C32@36@44`. So the rule for anything on this listener is: read the dump,
/// match it exactly, and let `DaemonListenerSignatureTests` prove the two still agree.
///
/// **This is not a swizzle.** Nothing is replaced; Messages.app's own handler continues to
/// receive everything it did before, and removing this one restores the process exactly.
/// `@unchecked Sendable` because it has no stored state at all: IMCore calls it on
/// whatever thread it likes, and every method here hands its arguments to main and emits.
final class DaemonEventHandler: NSObject, @unchecked Sendable {

  /// The message-layer callback, and the one that carries typing.
  ///
  /// There is no typing-specific callback on the listener; measured, not assumed: a dump of
  /// all 127 methods on `_IMLegacyDaemonListener` contains no selector matching "typing".
  /// Typing arrives the same way it does in the swizzled `IMChat._handleIncomingItem:` path:
  /// as an `IMMessageItem` flagged as a typing message, which is why the flags below are the
  /// same two the Objective-C helper checks.
  @objc(account:chat:style:chatProperties:messageReceived:)
  func account(
    _ account: Any?,
    chat: Any?,
    // `unsigned char`, NOT an object. See the type header above; getting this wrong
    // crashes Messages rather than failing quietly.
    style: UInt8,
    chatProperties: Any?,
    messageReceived item: Any?
  ) {
    handle(item: item, chat: chat)
  }

  /// The batched form. Messages sent in quick succession arrive here instead, and a handler
  /// that implements only the singular version misses them, which presents as typing
  /// indicators that work "sometimes".
  @objc(account:chat:style:chatProperties:messagesReceived:)
  func account(
    _ account: Any?,
    chat: Any?,
    // `unsigned char`, NOT an object. See the type header above; getting this wrong
    // crashes Messages rather than failing quietly.
    style: UInt8,
    chatProperties: Any?,
    messagesReceived items: Any?
  ) {
    guard let items = items as? [Any] else { return }
    for item in items { handle(item: item, chat: chat) }
  }

  /// Classifies one item and emits if it is a typing change.
  ///
  /// Resolving the chat's GUID asks `IMChatRegistry`, which is main-thread-only (see
  /// `IMCoreRuntime`'s note on `dispatch_assert_queue`, which traps rather than raising), so
  /// the work runs on main: inline when IMCore already called on main, and otherwise queued
  /// there, which keeps one thread's callbacks in the order they arrived.
  private func handle(item: Any?, chat: Any?) {
    let arguments = ListenerArguments(item: item, chat: chat)
    if Thread.isMainThread {
      Self.emitTyping(arguments)
    } else {
      DispatchQueue.main.async { Self.emitTyping(arguments) }
    }
  }

  /// One callback's arguments, carried to main. `@unchecked` because they are IMCore objects
  /// with no `Sendable` story of their own; they are only read, and only on main.
  private struct ListenerArguments: @unchecked Sendable {
    let item: Any?
    let chat: Any?
  }

  /// Main thread only: `registryGUID(for:)` asks `IMChatRegistry`.
  private static func emitTyping(_ arguments: ListenerArguments) {
    guard
      let event = typingEvent(
        item: arguments.item, chat: arguments.chat, resolving: registryGUID(for:))
    else { return }
    EventObservation.emit(event)
  }

  /// The typing event one listener callback carries, or nil when it carries none.
  ///
  /// Every lookup goes through `responds(to:)` and then `IMCoreRuntime`, because these are
  /// private selectors on an object we were HANDED rather than one we built: the shape is
  /// whatever IMCore passed and it changes between releases.
  ///
  /// `resolve` turns a string naming a chat into that chat's GUID; production asks the
  /// registry (`registryGUID(for:)`), and a test passes a table.
  static func typingEvent(
    item: Any?, chat: Any?, resolving resolve: (String) -> String?
  ) -> ObservedEvent? {
    guard let item = item as AnyObject? else { return nil }

    // `isIncomingTypingMessage` FIRST, then `isTypingMessage`, and BOTH rungs are load
    // bearing. Measured on `IMMessageItem`: `isIncomingTypingMessage` is present on 14.6.1
    // and 15.6.1 and **absent on 26.5.2**; `isTypingMessage` is on all three
    // (`docs/MACOS_COMPATIBILITY.md` §3b).
    //
    // `boolean` answers false for a selector that is absent, so reading only the first
    // spelling is hardcoded false on Tahoe: the guard below could then only be reached by a
    // CANCEL, `isTyping && !isCancel` would be false as well, and the helper would emit
    // `stopped-typing` while **`started-typing` could never fire at all**. Typing indicators
    // half-working, in the direction nobody notices, with nothing in any log.
    let isTyping =
      Self.boolean(item, "isIncomingTypingMessage")
      || Self.boolean(item, "isTypingMessage")
    let isCancel = Self.boolean(item, "isCancelTypingMessage")

    // Neither flag set means an ordinary message, which the server already learns about
    // from chat.db. Forwarding those would duplicate every message on the socket.
    guard isTyping || isCancel else { return nil }

    // `isTypingMessage` is not directional, unlike the `isIncomingTypingMessage` check the
    // shipping helper's swizzle uses. Without this
    // the helper reports OUR OWN typing back to the client as though the other party were
    // typing: every keystroke the user makes in Messages.app, echoed to every connected
    // device. Absent `isFromMe`, treat the item as incoming: the callback this arrives on
    // is `messageReceived:`, which is inbound by construction.
    guard !Self.boolean(item, "isFromMe") else { return nil }

    guard let guid = chatGUID(from: chat, resolving: resolve) else { return nil }
    return .typing(chat: guid, isTyping: isTyping && !isCancel)
  }

  /// The chat's GUID, from whatever the listener handed us, or nil.
  ///
  /// The `chat` argument is documented nowhere. It arrives as a string in some call shapes
  /// and as an `IMChat` in others, and the string is not necessarily a GUID: it can be the
  /// chat IDENTIFIER (`chat.chat_identifier`, an address or a `chat…` id). The event's field
  /// is `chatGuid`, and a client matches it against the GUIDs it holds, so an identifier
  /// there names no chat at all and the indicator never shows. So nothing here is forwarded
  /// as it arrived: a string is RESOLVED to its chat and an `IMChat` answers its own `guid`.
  /// An `IMChat` offering only `chatIdentifier` is resolved the same way as a string.
  ///
  /// Nil when nothing resolves, and the event is then dropped: a typing indicator naming no
  /// chat the client knows is worth less than none.
  static func chatGUID(from chat: Any?, resolving resolve: (String) -> String?) -> String? {
    if let string = chat as? String {
      return string.isEmpty ? nil : nonEmpty(resolve(string))
    }
    guard let object = chat as AnyObject? else { return nil }
    if let guid = string(object, "guid") { return guid }
    return string(object, "chatIdentifier").flatMap { nonEmpty(resolve($0)) }
  }

  /// The chat's GUID for a string naming it, as the registry answers it.
  ///
  /// Asked as a GUID first and as an identifier second, because which one the listener
  /// passed is not documented; either way the answer is read off the chat itself.
  /// `try?`: a registry that cannot answer is a chat that cannot be named, which drops this
  /// one event (see `chatGUID(from:resolving:)`). Main thread only, like every registry call.
  static func registryGUID(for value: String) -> String? {
    let byGUID = (try? IMChatRegistry.chat(guid: value)) ?? nil
    let chat = byGUID ?? ((try? IMChatRegistry.chat(chatIdentifier: value)) ?? nil)
    return chat?.guid
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  /// A string property read through the gateway, nil when absent, empty or not a string.
  ///
  /// Through `IMCoreRuntime.send`, not `perform` directly: this object arrives from IMCore
  /// rather than being one we built, and `send` applies the arity check, the return-TYPE
  /// check and the exception barrier. The return-type check is the one that matters here: a
  /// selector answering a primitive puts a bit pattern where a pointer belongs, and
  /// `as? String` then sends `isKindOfClass:` to it, a segfault inside Messages on IMCore's
  /// own callback thread. `responds(to:)` alone does not cover it: a selector can exist,
  /// take the right number of arguments, and still return an `int`.
  private static func string(_ object: AnyObject, _ accessor: String) -> String? {
    guard IMCoreRuntime.responds(object, to: accessor) else { return nil }
    return nonEmpty((try? IMCoreRuntime.send(object, accessor)) as? String)
  }

  private static func boolean(_ target: AnyObject, _ selectorName: String) -> Bool {
    guard IMCoreRuntime.responds(target, to: selectorName) else { return false }
    return (try? IMCoreRuntime.bool(target, selectorName)) ?? false
  }
}
