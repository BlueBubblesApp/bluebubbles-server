//  DaemonListenerSignatureTests
//  Our handler's argument types match the ones IMCore actually calls it with.
//
//  This is the one place in the tree where Apple's runtime calls INTO our code, and it is the
//  only dispatch direction the rest of the helper's machinery cannot protect. `IMCoreRuntime`
//  guards every call we make OUT: it checks `responds(to:)`, it checks arity, it checks the
//  return encoding, and it wraps the send in an exception barrier. None of that applies when
//  the daemon listener calls us, because by then the call frame is already built.
//
//  So the failure mode is different in kind. A selector we guess wrong about never fires, and
//  the feature is quietly absent. An ARGUMENT TYPE we get wrong is dispatched into: `style:`
//  is `unsigned char`, and declaring it `Any?` makes the Swift thunk read the raw value
//  (`IMChatStyle` is `0x2D` or `0x2B`) as an object pointer and retain it. That segfaults
//  Messages.app inside Apple's own callback, where nothing of ours can catch it.
//
//  The encoding is the whole of the check, and it is checkable at runtime, so it is checked
//  rather than asserted in a comment. `_IMLegacyDaemonListener` is dumped in every release
//  folder (`docs/headers/*/_IMLegacyDaemonListener.h:81`) and all three agree, so a divergence
//  here means one of two things, both of which want a person: Apple changed the signature, or
//  someone edited `DaemonEventHandler` without reading the dump.
//
//  Comparing the encodings rather than hard-coding one is deliberate. A hard-coded string
//  would pin what Apple's ABI is TODAY and fail on a release that repacks the frame for a
//  reason that does not concern us. What has to hold is that the two agree.

import Foundation
import ObjectiveC.runtime
import Testing

@testable import BlueBubblesHelper

@Suite(
  "Daemon listener signatures",
  .enabled(if: IMCorePrivateFrameworks.areLoaded))
struct DaemonListenerSignatureTests {

  /// Every selector we implement on the listener, and nothing else.
  private static let selectors = [
    "account:chat:style:chatProperties:messageReceived:",
    "account:chat:style:chatProperties:messagesReceived:",
  ]

  @Test("Our handler is typed the way IMCore declares the selector")
  func handlerMatchesIMCore() throws {
    let theirs: AnyClass = try #require(
      NSClassFromString("_IMLegacyDaemonListener"),
      "_IMLegacyDaemonListener is gone; the rung-2 observation path needs re-deriving")
    let ours: AnyClass = DaemonEventHandler.self

    for name in Self.selectors {
      let selector = NSSelectorFromString(name)
      let mine = try #require(
        class_getInstanceMethod(ours, selector),
        "DaemonEventHandler no longer implements \(name)")
      let mineEncoding = try #require(method_getTypeEncoding(mine).map(String.init(cString:)))

      guard let mirror = class_getInstanceMethod(theirs, selector),
        let theirEncoding = method_getTypeEncoding(mirror).map(String.init(cString:))
      else {
        // Apple removing the selector is a real event and the reason this suite exists,
        // but it is not something this test can fix. Say so and move on.
        Issue.record("_IMLegacyDaemonListener no longer declares \(name)")
        continue
      }

      #expect(
        mineEncoding == theirEncoding,
        """
        \(name) is typed differently from the selector IMCore calls.
          IMCore:  \(theirEncoding)
          ours:    \(mineEncoding)
        Read docs/headers/<release>/_IMLegacyDaemonListener.h and match it exactly. An \
        argument typed wrong here is dispatched into and crashes Messages; it does not \
        fail quietly.
        """)
    }
  }

  @Test("The style argument is a byte, which is the one that has been wrong")
  func styleIsAByte() throws {
    let selector = NSSelectorFromString(Self.selectors[0])
    let method = try #require(class_getInstanceMethod(DaemonEventHandler.self, selector))
    let encoding = try #require(method_getTypeEncoding(method).map(String.init(cString:)))
    // Two leading entries are self and _cmd, so `style:` is argument index 4.
    // `method_copyArgumentType` hands back a buffer the caller owns.
    let styleBuffer = try #require(method_copyArgumentType(method, 4))
    let style = String(cString: styleBuffer)
    free(styleBuffer)
    #expect(
      style == "C",
      """
      style: is \(style), not `C` (unsigned char). Full encoding: \(encoding). \
      Declaring it as an object makes the thunk retain a small integer.
      """)
  }
}
