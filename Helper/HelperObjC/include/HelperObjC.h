//  HelperObjC
//  The two things Swift cannot do when talking to IMCore.
//
//  1. CATCH OBJECTIVE-C EXCEPTIONS. Swift's `do/catch` does not catch `@throw`. An
//     unrecognised selector, a nil argument a method insists on, an internal IMCore
//     assertion: every one raises an NSException, and an uncaught NSException calls
//     `abort()`. This code runs inside **Messages.app**, so that is the user's Messages
//     terminating because we probed something. There is no way to recover from it in Swift,
//     and no way to even find out it is about to happen. It has to be caught here.
//
//  2. INVOKE ARBITRARY SELECTORS. `objc_msgSend` cannot be called from Swift: its signature
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
/// is the only diagnostic that survives; the stack is gone by the time this returns.
BOOL BBCatchingExceptions(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

/// Allocates an instance of `cls` and sends it a designated initialiser, as one operation.
///
/// **The allocation is never handed out on its own, and that is the whole design.** `+alloc`
/// returns an object at +1 and `-init…` CONSUMES that +1: it either returns the same object
/// with the count transferred to the return value, or — and this is the case that killed
/// Messages — releases the receiver and returns a different object, or nil. None of those
/// conventions is known to `NSInvocation`, and none of them is known to Swift, which holds
/// whatever it is given as an ordinary managed reference and releases it when it goes out of
/// scope. So an allocation that crossed into Swift and was initialised in a second call had
/// a reference Swift still believed in and an object `init` had already disposed of: a
/// use-after-free that `POST /api/v1/message/attachment` hit every time, reaching
/// `-[CKComposition initWithText:subject:]` and taking the user's Messages down with
/// `EXC_ARM_PAC_FAIL` inside `swift_unknownObjectRelease`.
///
/// Keeping both halves here, in a file the compiler compiles with ARC, is what makes the
/// ownership expressible at all:
///
///   - ARC owns the allocation for the duration, and releases it on the way out;
///   - one EXTRA retain is taken before the call, because that is the count `-init…`
///     consumes. Without it, ARC's release and `init`'s consumption are the same count spent
///     twice;
///   - on success the extra retain is handed back through the RESULT, which arrives at +1
///     by the same convention and is retained here for the caller. Substitution and failure
///     both fall out correctly: a released receiver took the extra count with it, and the
///     result carries its own.
///
/// `outResult` receives the initialised object, owned by the caller. Returns NO and fills
/// `error` if the class cannot allocate, the initialiser does not exist, its arity does not
/// match, or the call raises. A `nil` return from a failed initialiser is reported as an
/// error rather than as success with no object.
BOOL BBAllocateAndInitialize(Class cls,
                             SEL selector,
                             NSArray *arguments,
                             id _Nullable *_Nullable outResult,
                             NSError *_Nullable *_Nullable error);

/// Invokes a selector with any number of arguments, inside an exception barrier.
///
/// Each argument is written according to the METHOD's declared type encoding, not according
/// to what the caller passed:
///
///   - objects pass through, with `NSNull` meaning an explicit nil (an array cannot hold one)
///   - primitives must arrive as `NSNumber` and are unboxed to the exact declared width
///   - structs must arrive as `NSValue`, whose own type is checked against the method's first
///   - blocks are copied, because a block stored beyond the caller's scope must be, which
///     IMCore's completion handlers are. Swift happens not to produce stack blocks, so this
///     is discipline at an `unsafeBitCast` boundary rather than a fix for anything observed;
///     see the note on `BBSetArgument`. Call sites do not have to remember it.
///
/// That checking is the point. IMCore's message constructor mixes objects, an integer flags
/// word and an `NSRange` in one selector, and writing an NSNumber's pointer where an integer
/// belongs does not fail; it builds a message with nonsense properties.
///
/// `outResult` receives the return value: the object itself when the method returns one, an
/// `NSNumber` at the declared width when it returns a scalar, an `NSValue` carrying the
/// method's type encoding when it returns a struct (`rangeValue` reads an `NSRange` back
/// out), and nil for `void` or a raw pointer. A dropped scalar is why this boxes at all:
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
