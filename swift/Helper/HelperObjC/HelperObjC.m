#import "include/HelperObjC.h"

static NSString *const BBHelperErrorDomain = @"com.bluebubbles.helper";

static NSError *BBErrorWithReason(NSInteger code, NSString *reason) {
    return [NSError errorWithDomain:BBHelperErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

BOOL BBCatchingExceptions(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            // Name AND reason. "NSInvalidArgumentException" alone does not say which
            // argument, and the reason string is usually the selector that was not found.
            *error = BBErrorWithReason(
                1,
                [NSString stringWithFormat:@"%@: %@",
                    exception.name ?: @"NSException",
                    exception.reason ?: @"no reason given"]);
        }
        return NO;
    } @catch (id other) {
        // A non-NSException @throw is legal Objective-C and would otherwise escape this
        // barrier and abort the process.
        if (error) {
            *error = BBErrorWithReason(2, @"A non-NSException object was thrown");
        }
        return NO;
    }
}

/// Writes one argument into an invocation according to its declared type encoding.
///
/// Objects pass straight through (`NSNull` meaning an explicit nil, since an array cannot
/// hold one). Primitives must arrive as `NSNumber` and are unboxed to the exact width the
/// method declares — a `long long` parameter given a 32-bit write would read whatever
/// happened to be in the adjacent bytes. Structs must arrive as `NSValue`, and its declared
/// type is checked against the method's before its bytes are copied, because an NSValue
/// carrying the wrong struct would silently write the wrong layout.
///
/// BLOCKS ARE COPIED, and the honest reason is narrower than it first looks.
///
/// The rule for Objective-C is that a block stored beyond the caller's scope must be copied:
/// `objc_retain` on a STACK block is a no-op, so `retainArguments` below cannot promote one,
/// and the callee ends up holding freed stack memory. IMCore's completion handlers are
/// exactly that shape — stored, then fired seconds later on another queue.
///
/// MEASURED, though: Swift does not produce stack blocks. A `@convention(block)` closure
/// comes out as `__NSMallocBlock__` on this toolchain whether it captures anything or not,
/// so every current call site was already safe and this copy changes nothing observable
/// today. It is kept because it is the documented discipline at a boundary that is otherwise
/// only safe by an implementation detail we do not control — the value reaches us through an
/// `unsafeBitCast`, which is precisely where ARC's guarantees stop. One `_Block_copy` per
/// completion is not a cost worth reasoning about.
///
/// Do NOT read this as a fix for an observed crash. It is not, and `BlockArgumentTests` says
/// so: disabling this branch does not make those tests fail.
static BOOL BBSetArgument(NSInvocation *invocation,
                          NSUInteger position,
                          id argument,
                          const char *type,
                          SEL selector,
                          NSMutableArray *heapBlocks,
                          NSError **error) {
    switch (type[0]) {
        case '@':
        case '#': {
            id value = (argument == (id)[NSNull null]) ? nil : argument;

            // A block parameter the method declares as `@?` MUST arrive as a block. Named
            // rather than copied blindly: `-copy` on an object that does not implement
            // NSCopying raises, and a completion slot handed something else is a mistake
            // worth reporting by argument number.
            BOOL declaredBlock = (type[0] == '@' && type[1] == '?');
            BOOL isBlock = (value != nil)
                && [value isKindOfClass:NSClassFromString(@"NSBlock")];

            if (declaredBlock && value != nil && !isBlock) {
                if (error) {
                    *error = BBErrorWithReason(
                        12, [NSString stringWithFormat:
                            @"%@ argument %lu is a block; got %@",
                            NSStringFromSelector(selector),
                            (unsigned long)position - 2, NSStringFromClass([value class])]);
                }
                return NO;
            }

            // Keyed off what the value IS, not only off what the method declares.
            //
            // Every completion parameter measured on macOS 26.5.2 does encode as `@?`, but
            // not every private selector can be measured — `generateMedia:` lives in a
            // plugin bundle that only loads inside Messages — and an encoding that lost the
            // `?` would make a declaration-only check silently stop firing while looking
            // correct. Testing the object costs one `isKindOfClass`.
            if (isBlock) {
                // `-copy` on a block is `_Block_copy`: a retain for one already on the heap,
                // a promotion for one that is not.
                id heapBlock = [value copy];
                // Held by the caller for the rest of the invocation. A strong local here
                // would be released when this function returns — which is BEFORE
                // `retainArguments` runs — leaving the invocation holding a dangling
                // pointer. That one IS a live hazard, introduced by this branch, which is
                // why the array exists rather than a local.
                [heapBlocks addObject:heapBlock];
                value = heapBlock;
            }

            [invocation setArgument:&value atIndex:position];
            return YES;
        }
        case '^':
        case '*': {
            // A raw pointer. Only an explicit nil is accepted — anything else would mean
            // fabricating an address.
            if (argument != (id)[NSNull null]) {
                if (error) {
                    *error = BBErrorWithReason(
                        8, [NSString stringWithFormat:
                            @"%@ argument %lu is a pointer; only NSNull (nil) is accepted",
                            NSStringFromSelector(selector), (unsigned long)position - 2]);
                }
                return NO;
            }
            void *null = NULL;
            [invocation setArgument:&null atIndex:position];
            return YES;
        }
        default:
            break;
    }

    if ([argument isKindOfClass:[NSValue class]] && !([argument isKindOfClass:[NSNumber class]])) {
        NSValue *value = (NSValue *)argument;
        if (strcmp(value.objCType, type) != 0) {
            if (error) {
                *error = BBErrorWithReason(
                    9, [NSString stringWithFormat:
                        @"%@ argument %lu is '%s' but the value carries '%s'",
                        NSStringFromSelector(selector), (unsigned long)position - 2,
                        type, value.objCType]);
            }
            return NO;
        }
        NSUInteger size = 0;
        NSGetSizeAndAlignment(type, &size, NULL);
        void *buffer = calloc(1, size);
        if (buffer == NULL) { return NO; }
        [value getValue:buffer size:size];
        [invocation setArgument:buffer atIndex:position];
        free(buffer);
        return YES;
    }

    if (![argument isKindOfClass:[NSNumber class]]) {
        if (error) {
            *error = BBErrorWithReason(
                10, [NSString stringWithFormat:
                    @"%@ argument %lu is '%s'; pass an NSNumber or NSValue",
                    NSStringFromSelector(selector), (unsigned long)position - 2, type]);
        }
        return NO;
    }

    NSNumber *number = (NSNumber *)argument;
    // Unboxed to the EXACT declared width. `long long` given a 32-bit write reads whatever
    // is in the adjacent bytes, which is a flags word full of garbage.
    switch (type[0]) {
        case 'c': { char v = number.charValue;                 [invocation setArgument:&v atIndex:position]; return YES; }
        case 'C': { unsigned char v = number.unsignedCharValue; [invocation setArgument:&v atIndex:position]; return YES; }
        case 's': { short v = number.shortValue;                [invocation setArgument:&v atIndex:position]; return YES; }
        case 'S': { unsigned short v = number.unsignedShortValue; [invocation setArgument:&v atIndex:position]; return YES; }
        case 'i': { int v = number.intValue;                    [invocation setArgument:&v atIndex:position]; return YES; }
        case 'I': { unsigned int v = number.unsignedIntValue;   [invocation setArgument:&v atIndex:position]; return YES; }
        case 'l': { long v = number.longValue;                  [invocation setArgument:&v atIndex:position]; return YES; }
        case 'L': { unsigned long v = number.unsignedLongValue; [invocation setArgument:&v atIndex:position]; return YES; }
        case 'q': { long long v = number.longLongValue;         [invocation setArgument:&v atIndex:position]; return YES; }
        case 'Q': { unsigned long long v = number.unsignedLongLongValue; [invocation setArgument:&v atIndex:position]; return YES; }
        case 'f': { float v = number.floatValue;                [invocation setArgument:&v atIndex:position]; return YES; }
        case 'd': { double v = number.doubleValue;              [invocation setArgument:&v atIndex:position]; return YES; }
        case 'B': { bool v = number.boolValue;                  [invocation setArgument:&v atIndex:position]; return YES; }
        default:
            if (error) {
                *error = BBErrorWithReason(
                    11, [NSString stringWithFormat:@"%@ argument %lu has unsupported type '%s'",
                        NSStringFromSelector(selector), (unsigned long)position - 2, type]);
            }
            return NO;
    }
}

/// Boxes a scalar return value as an NSNumber, reading it at its declared width.
///
/// `getReturnValue:` copies exactly as many bytes as the method's return type occupies, so
/// each width is read into its own C type rather than into one wide local — reading a `char`
/// return into an `long long` would leave the upper seven bytes as whatever was on the stack,
/// and a BOOL of `NO` would come back as a large nonzero number.
///
/// Anything that is not a scalar — void, a struct, a raw pointer — returns nil, which is the
/// same answer this function's absence used to give for everything. Boxing a struct would
/// need its layout, and a caller that wants one should say so with its own accessor.
static id BBBoxedScalarReturn(NSInvocation *invocation, const char *type) {
    switch (type[0]) {
        case 'c': { char value = 0;               [invocation getReturnValue:&value]; return @(value); }
        case 'C': { unsigned char value = 0;      [invocation getReturnValue:&value]; return @(value); }
        case 'B': { bool value = false;           [invocation getReturnValue:&value]; return @(value); }
        case 's': { short value = 0;              [invocation getReturnValue:&value]; return @(value); }
        case 'S': { unsigned short value = 0;     [invocation getReturnValue:&value]; return @(value); }
        case 'i': { int value = 0;                [invocation getReturnValue:&value]; return @(value); }
        case 'I': { unsigned int value = 0;       [invocation getReturnValue:&value]; return @(value); }
        case 'l': { long value = 0;               [invocation getReturnValue:&value]; return @(value); }
        case 'L': { unsigned long value = 0;      [invocation getReturnValue:&value]; return @(value); }
        case 'q': { long long value = 0;          [invocation getReturnValue:&value]; return @(value); }
        case 'Q': { unsigned long long value = 0; [invocation getReturnValue:&value]; return @(value); }
        case 'f': { float value = 0;              [invocation getReturnValue:&value]; return @(value); }
        case 'd': { double value = 0;             [invocation getReturnValue:&value]; return @(value); }
        default: return nil;
    }
}

BOOL BBInvoke(id target,
              SEL selector,
              NSArray *arguments,
              id *outResult,
              NSError **error) {
    if (outResult) { *outResult = nil; }

    if (target == nil) {
        if (error) { *error = BBErrorWithReason(3, @"Target is nil"); }
        return NO;
    }
    if (![target respondsToSelector:selector]) {
        if (error) {
            *error = BBErrorWithReason(
                4, [NSString stringWithFormat:@"%@ does not respond to %@",
                    NSStringFromClass([target class]), NSStringFromSelector(selector)]);
        }
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature == nil) {
        if (error) { *error = BBErrorWithReason(5, @"No method signature"); }
        return NO;
    }

    // Two implicit arguments — self and _cmd — precede the explicit ones.
    NSUInteger expected = signature.numberOfArguments - 2;
    if (expected != arguments.count) {
        if (error) {
            *error = BBErrorWithReason(
                6, [NSString stringWithFormat:@"%@ takes %lu argument(s), not %lu",
                    NSStringFromSelector(selector),
                    (unsigned long)expected, (unsigned long)arguments.count]);
        }
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    invocation.target = target;

    // Each argument is written according to the METHOD's declared type, not according to
    // what the caller happened to pass. IMCore's constructors mix objects, integer flag
    // words and an NSRange in one selector, and writing an NSNumber's pointer where an
    // integer belongs does not fail — it puts a pointer value into the flags and produces a
    // message with nonsense properties.
    //
    // `heapBlocks` keeps every promoted block alive across the loop, because a strong local
    // inside `BBSetArgument` would be released before `retainArguments` could claim it.
    NSMutableArray *heapBlocks = [NSMutableArray array];

    for (NSUInteger index = 0; index < arguments.count; index++) {
        id argument = arguments[index];
        const char *type = [signature getArgumentTypeAtIndex:index + 2];
        if (type == NULL) {
            if (error) { *error = BBErrorWithReason(7, @"Missing argument type"); }
            return NO;
        }

        if (!BBSetArgument(invocation, index + 2, argument, type, selector,
                           heapBlocks, error)) {
            return NO;
        }
    }

    // Arguments are retained for the duration. Without this a temporary built by the caller
    // can be released before the callee reads it — a use-after-free that usually survives
    // long enough to look like it worked.
    [invocation retainArguments];

    __block id result = nil;
    const char *returnType = signature.methodReturnType;

    BOOL ok = BBCatchingExceptions(^{
        [invocation invoke];
        if (returnType == NULL) { return; }
        if (returnType[0] == '@' || returnType[0] == '#') {
            __unsafe_unretained id unretained = nil;
            [invocation getReturnValue:&unretained];
            result = unretained;
            return;
        }
        // A scalar comes back BOXED rather than dropped. Several IMCore selectors the helper
        // has to call answer with one and the answer is the point: `-deleteAllHistory`
        // returns whether it deleted anything, and `-markAsSpam:` returns how many messages
        // it reported. Both used to arrive here as nil, indistinguishable from a method that
        // returns nothing — so the caller reported success for a call that had done nothing.
        result = BBBoxedScalarReturn(invocation, returnType);
    }, error);

    if (!ok) { return NO; }
    if (outResult) { *outResult = result; }
    return YES;
}
