//  HelperObjC
//  The two things Swift cannot do when talking to IMCore.
//
//  1. CATCH OBJECTIVE-C EXCEPTIONS. Swift's `do/catch` does not catch `@throw`. An
//     unrecognised selector, a nil argument a method insists on, an internal IMCore
//     assertion — every one raises an NSException, and an uncaught NSException calls
//     `abort()`. This code runs inside **Messages.app**, so that is the user's Messages
//     terminating because we probed something. There is no way to recover from it in Swift,
//     and no way to even find out it is about to happen. It has to be caught here.
//
//  2. INVOKE ARBITRARY SELECTORS. `objc_msgSend` cannot be called from Swift — its signature
//     depends on the method, and Swift has no variadic C calling convention.
//     `perform(_:with:with:)` covers at most two object arguments, and IMCore's message
//     constructor takes eleven. `NSInvocation` handles any arity but is unavailable in Swift.
//
//  The same reasoning as BBTypedStreamShim, for the same reason: a narrow Objective-C file
//  that exists solely to make a boundary safe.
//
//  See `.claude/docs/private-api.md`.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block, converting any Objective-C exception into an NSError.
///
/// Returns YES on success. On failure `error` carries the exception's name and reason, which
/// is the only diagnostic that survives — the stack is gone by the time this returns.
BOOL BBCatchingExceptions(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

/// Invokes a selector with any number of arguments, inside an exception barrier.
///
/// Each argument is written according to the METHOD's declared type encoding, not according
/// to what the caller passed:
///
///   - objects pass through, with `NSNull` meaning an explicit nil (an array cannot hold one)
///   - primitives must arrive as `NSNumber` and are unboxed to the exact declared width
///   - structs must arrive as `NSValue`, whose own type is checked against the method's first
///   - blocks are copied, because a block stored beyond the caller's scope must be — which
///     IMCore's completion handlers are. Swift happens not to produce stack blocks, so this
///     is discipline at an `unsafeBitCast` boundary rather than a fix for anything observed;
///     see the note on `BBSetArgument`. Call sites do not have to remember it.
///
/// That checking is the point. IMCore's message constructor mixes objects, an integer flags
/// word and an `NSRange` in one selector, and writing an NSNumber's pointer where an integer
/// belongs does not fail — it builds a message with nonsense properties.
///
/// `outResult` receives the return value: the object itself when the method returns one, an
/// `NSNumber` at the declared width when it returns a scalar, an `NSValue` carrying the
/// method's type encoding when it returns a struct (`rangeValue` reads an `NSRange` back
/// out), and nil for `void` or a raw pointer. A dropped scalar is why this boxes at all —
/// `-[IMChat deleteAllHistory]` returns a BOOL and `-[IMChat markAsSpam:]` returns a count,
/// and both used to be indistinguishable here from a method returning nothing.
///
/// Returns NO and fills `error` if the target does not respond, the arity does not match, or
/// the call raises.
BOOL BBInvoke(id target,
              SEL selector,
              NSArray *arguments,
              id _Nullable *_Nullable outResult,
              NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
