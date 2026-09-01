//  IMCoreRuntime
//  Safe dynamic dispatch against IMCore's private classes.
//
//  IMCore ships no headers. The shipping Objective-C helper gets around that with a
//  hand-maintained header dump, which is why it accumulates a new set every macOS release and
//  why a class or selector that moved shows up as a link error at build time. That trade is
//  wrong for a helper injected into someone else's process: a link error is a helper that
//  will not load, and a load failure is invisible — dyld declines the insert and Messages
//  starts normally without it.
//
//  So everything here is looked up at RUNTIME and checked before it is called. A selector
//  that moved degrades to a clear `unavailableOnThisOS`, naming the selector, on the one
//  method that needed it. Everything else keeps working.
//
//  That difference is the whole point of § 15's observation ladder applied to calls rather
//  than events: fail one feature loudly, never the process.
//
//  **`objc_msgSend` cannot be called from Swift.** Its signature depends on the method being
//  called, and Swift has no variadic C calling convention. Everything below therefore goes
//  through `NSInvocation`-equivalent machinery — `perform(_:with:)` for the shapes it covers,
//  and typed `@convention(c)` casts of the runtime's IMP for the rest.
//
//  See `.claude/docs/private-api.md`.

import Foundation
import HelperObjC
import ObjectiveC

/// Why an IMCore call could not be made.
///
/// Distinct from `PrivateAPIError.notImplemented`, which means "not ported yet". These mean
/// "ported, but this macOS does not have it" — a different problem with a different fix, and
/// conflating them would make an OS upgrade look like a regression in this code.
public enum IMCoreLookupError: Error, CustomStringConvertible {
  case classMissing(String)
  case selectorMissing(class: String, selector: String)
  case unexpectedReturn(selector: String, expected: String)
  case argumentCountMismatch(selector: String, expected: Int, given: Int)
  case nonObjectReturn(selector: String, encoding: String)
  /// An Objective-C exception, caught at the boundary. Without the barrier this would not
  /// be an error at all — it would be `abort()` inside Messages.app.
  case raised(selector: String, reason: String)

  public var description: String {
    switch self {
    case .classMissing(let name):
      "IMCore class \(name) is not present on this macOS"
    case .selectorMissing(let className, let selector):
      "\(className) does not respond to \(selector) on this macOS"
    case .unexpectedReturn(let selector, let expected):
      "\(selector) did not return \(expected)"
    case .argumentCountMismatch(let selector, let expected, let given):
      "\(selector) takes \(expected) argument(s), not \(given)"
    case .nonObjectReturn(let selector, let encoding):
      "\(selector) returns '\(encoding)', not an object — read it with a typed accessor"
    case .raised(let selector, let reason):
      "\(selector) raised: \(reason)"
    }
  }
}

public enum IMCoreRuntime {

  // MARK: - Classes

  /// Looks up a class by name, once.
  ///
  /// Cached because these are resolved on every call and `NSClassFromString` walks the
  /// runtime's class table each time. The cache is keyed by name and never invalidated:
  /// classes do not appear or disappear within a process's lifetime.
  public static func lookUpClass(_ name: String) -> AnyClass? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    if let cached = classCache[name] { return cached }
    let resolved: AnyClass? = NSClassFromString(name)
    classCache[name] = resolved
    return resolved
  }

  public static func requireClass(_ name: String) throws -> AnyClass {
    guard let resolved = lookUpClass(name) else {
      throw IMCoreLookupError.classMissing(name)
    }
    return resolved
  }

  private nonisolated(unsafe) static var classCache: [String: AnyClass?] = [:]
  private static let cacheLock = NSLock()

  // MARK: - Sending

  /// Whether an object responds to a selector.
  ///
  /// Every call site checks this first. Sending an unrecognised selector raises an
  /// Objective-C exception, and an uncaught ObjC exception inside Messages.app terminates
  /// **Messages**, not just the helper — the user loses their app because we probed for a
  /// method that moved.
  public static func responds(_ target: AnyObject, to selector: Selector) -> Bool {
    target.responds(to: selector)
  }

  /// Sends a selector taking zero, one or two object arguments, and RETURNS an object.
  ///
  /// Not for writes. `perform` has no exception barrier, so anything the callee raises
  /// unwinds through Swift frames — which killed the dispatch task without killing the
  /// process, so the action applied and the caller waited for a reply that never came.
  /// MEASURED: `_setDisplayName:` renamed the chat and then timed out. Every void-returning
  /// call goes through `invoke` for that reason.
  ///
  /// `perform` covers exactly these shapes. Anything with a non-object argument or more
  /// than two parameters needs a typed IMP cast — see `callVoid` below — because `perform`
  /// would misinterpret the argument registers and corrupt the call.
  @discardableResult
  public static func send(
    _ target: AnyObject,
    _ selectorName: String,
    _ arguments: Any?...
  ) throws -> AnyObject? {
    // AnyObject, not Any: `checkObjectReturn` below has already established that the
    // return is an object or void, so a caller never has to unwrap a boxed primitive.
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector) else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    guard arguments.count <= 2 else {
      // Refused rather than truncated. Silently dropping a third argument would call
      // the method with garbage in that register.
      throw IMCoreLookupError.unexpectedReturn(
        selector: selectorName, expected: "at most two object arguments"
      )
    }

    // Arity is checked against the METHOD, not against `responds(to:)`.
    //
    // `responds(to:)` answers "does this selector exist", not "does it take the
    // arguments I am about to pass". Calling `sortedArrayUsingSelector:` with no
    // arguments passes whatever is in that register as a `SEL` — which aborts the
    // process. Inside Messages.app that terminates the user's Messages, and this is the
    // only place it can be caught, so it is checked on every call rather than trusted.
    try checkArity(target, selector, selectorName, given: arguments.count)

    // The RETURN type is checked too, and this is not belt-and-braces.
    //
    // `perform` hands back whatever the method returned as though it were an object
    // pointer. For a method returning `NSUInteger`, that "pointer" is the count — so
    // `array.count` of 2 becomes address 0x2, and the first message sent to it
    // segfaults. Arity checking does not catch this: the selector exists and takes the
    // right number of arguments; only its return type is wrong for this call path.
    try checkObjectReturn(target, selector, selectorName)

    // Retained explicitly. `perform` returns an unmanaged reference under ARC and the
    // result is otherwise released before the caller reads it, which is a use-after-free
    // that usually survives long enough to look like it worked.
    let unmanaged: Unmanaged<AnyObject>?
    switch arguments.count {
    case 0: unmanaged = target.perform(selector)
    case 1: unmanaged = target.perform(selector, with: arguments[0])
    default: unmanaged = target.perform(selector, with: arguments[0], with: arguments[1])
    }
    return unmanaged?.takeUnretainedValue()
  }

  /// Refuses a selector whose return value is not an object.
  ///
  /// Type encodings: `@` is an object, `#` a Class, `v` void. Everything else — `i`, `Q`,
  /// `B`, `d` — is a primitive that must not travel through `perform`.
  private static func checkObjectReturn(
    _ target: AnyObject,
    _ selector: Selector,
    _ selectorName: String
  ) throws {
    let method =
      class_getInstanceMethod(object_getClass(target), selector)
      ?? class_getInstanceMethod(type(of: target), selector)
    guard let method else { return }

    guard let returnType = method_copyReturnType(method) as UnsafeMutablePointer<CChar>? else {
      return
    }
    defer { free(returnType) }

    let encoding = String(cString: returnType)
    // `v` is allowed: a void method called for its effect returns nothing to misread.
    guard encoding == "@" || encoding == "#" || encoding == "v" else {
      throw IMCoreLookupError.nonObjectReturn(
        selector: selectorName, encoding: encoding
      )
    }
  }

  /// A selector taking a single BOOL argument.
  ///
  /// `perform` boxes its argument as an object, so the callee would read the NSNumber's
  /// POINTER as the byte — and every non-null pointer is non-zero, so `false` would arrive
  /// as `true`. Setting a typing indicator that can only ever turn on is exactly the kind
  /// of bug that looks like Messages misbehaving.
  public static func callBool(
    _ target: AnyObject,
    _ selectorName: String,
    _ value: Bool
  ) throws {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector),
      let method = class_getInstanceMethod(type(of: target), selector)
    else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    guard Int(method_getNumberOfArguments(method)) - 2 == 1 else {
      throw IMCoreLookupError.argumentCountMismatch(
        selector: selectorName,
        expected: Int(method_getNumberOfArguments(method)) - 2, given: 1
      )
    }
    typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
    let implementation = unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
    implementation(target, selector, value)
  }

  /// Calls a designated initializer taking a single OBJECT (which may be nil).
  ///
  /// `send` cannot express "initialise with an explicit nil", and some private classes
  /// refuse `init` outright — `TUDialRequest` asserts "call designated initializer instead"
  /// — so the object-taking designated initializer needs its own typed path.
  public static func initWithObject(
    _ allocated: AnyObject,
    _ selectorName: String,
    _ value: AnyObject?
  ) -> AnyObject? {
    let selector = NSSelectorFromString(selectorName)
    guard let method = class_getInstanceMethod(type(of: allocated), selector) else {
      return nil
    }
    typealias ObjectInitializer =
      @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    let implementation = unsafeBitCast(
      method_getImplementation(method), to: ObjectInitializer.self
    )
    var result: AnyObject?
    var error: NSError?
    guard BBCatchingExceptions({ result = implementation(allocated, selector, value) }, &error)
    else { return nil }
    return result
  }

  /// Calls a designated initializer taking a single `int`, through a typed IMP.
  ///
  /// Needed because some private classes REFUSE `init` — `TUDialRequest` asserts
  /// "call designated initializer instead" — and the designated one takes a non-object
  /// argument, which `perform` cannot pass correctly (it would hand over the boxed
  /// NSNumber's pointer as the integer).
  ///
  /// Returns nil when the selector is absent or the initializer hands back nil.
  public static func initWithInt(
    _ allocated: AnyObject,
    _ selectorName: String,
    _ value: Int32
  ) -> AnyObject? {
    let selector = NSSelectorFromString(selectorName)
    guard let method = class_getInstanceMethod(type(of: allocated), selector) else {
      return nil
    }
    typealias IntInitializer = @convention(c) (AnyObject, Selector, Int32) -> AnyObject?
    let implementation = unsafeBitCast(
      method_getImplementation(method), to: IntInitializer.self
    )
    var result: AnyObject?
    var error: NSError?
    // Inside the barrier: the initializer ASSERTS on a bad argument, and an uncaught
    // Objective-C exception here would abort FaceTime.app.
    guard BBCatchingExceptions({ result = implementation(allocated, selector, value) }, &error)
    else { return nil }
    return result
  }

  /// An integer return, read through a typed cast rather than `perform`.
  public static func integer(_ target: AnyObject, _ selectorName: String) throws -> Int {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector),
      let method = class_getInstanceMethod(type(of: target), selector)
    else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int
    let implementation = unsafeBitCast(method_getImplementation(method), to: IntegerGetter.self)
    return implementation(target, selector)
  }

  /// A `double` return, read through a typed cast rather than `perform`.
  ///
  /// FindMy is why this exists: `FMLLocation` reports latitude, longitude, altitude,
  /// accuracy and its timestamp as bare `double`s. Through `perform` each of those bit
  /// patterns would be read as an object pointer — a latitude of 37.33 becomes an address
  /// in the low four billion, and the first message sent to it segfaults **Messages**.
  public static func double(_ target: AnyObject, _ selectorName: String) throws -> Double {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector),
      let method = class_getInstanceMethod(type(of: target), selector)
    else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    guard Int(method_getNumberOfArguments(method)) - 2 == 0 else {
      throw IMCoreLookupError.argumentCountMismatch(
        selector: selectorName,
        expected: Int(method_getNumberOfArguments(method)) - 2, given: 0
      )
    }
    // Checked, not assumed: a selector that returns `float` on some future release would
    // otherwise be read as a double and produce a plausible, wrong coordinate. Silently
    // wrong is the failure mode this whole file exists to avoid.
    guard let returnType = method_copyReturnType(method) as UnsafeMutablePointer<CChar>? else {
      throw IMCoreLookupError.unexpectedReturn(selector: selectorName, expected: "a double")
    }
    defer { free(returnType) }
    let encoding = String(cString: returnType)
    guard encoding == "d" else {
      throw IMCoreLookupError.nonObjectReturn(selector: selectorName, encoding: encoding)
    }

    typealias DoubleGetter = @convention(c) (AnyObject, Selector) -> Double
    let implementation = unsafeBitCast(method_getImplementation(method), to: DoubleGetter.self)
    return implementation(target, selector)
  }

  /// A BOOL return from a selector taking ONE object argument.
  ///
  /// The zero-argument `bool` above cannot serve these: passing an argument to a cast that
  /// declares none leaves it in a register the callee never reads, so the predicate answers
  /// about nothing in particular. `IMFMFSession`'s relationship checks —
  /// `handleIsSharingLocationWithMe:` and its siblings — are all this shape.
  public static func bool(
    _ target: AnyObject,
    _ selectorName: String,
    with argument: AnyObject?
  ) throws -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector),
      let method = class_getInstanceMethod(type(of: target), selector)
    else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    guard Int(method_getNumberOfArguments(method)) - 2 == 1 else {
      throw IMCoreLookupError.argumentCountMismatch(
        selector: selectorName,
        expected: Int(method_getNumberOfArguments(method)) - 2, given: 1
      )
    }
    typealias BoolPredicate = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
    let implementation = unsafeBitCast(method_getImplementation(method), to: BoolPredicate.self)
    return implementation(target, selector, argument)
  }

  /// Compares a selector's declared argument count against what the caller is passing.
  ///
  /// `method_getNumberOfArguments` counts the implicit `self` and `_cmd`, so an explicit
  /// argument count is that number minus two.
  private static func checkArity(
    _ target: AnyObject,
    _ selector: Selector,
    _ selectorName: String,
    given: Int
  ) throws {
    // Class methods live on the metaclass. Looking only at the instance method would
    // miss the arity of a singleton accessor and let it through unchecked.
    let method =
      class_getInstanceMethod(object_getClass(target), selector)
      ?? class_getInstanceMethod(type(of: target), selector)
    guard let method else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    let expected = Int(method_getNumberOfArguments(method)) - 2
    guard expected == given else {
      throw IMCoreLookupError.argumentCountMismatch(
        selector: selectorName, expected: expected, given: given
      )
    }
  }

  /// A selector whose return value is ignored, called through a typed IMP.
  ///
  /// Used where `perform` cannot go: three or more arguments, or a non-object argument.
  /// The cast must match the real signature exactly — a wrong one reads the wrong
  /// registers, which does not crash, it produces nonsense.
  public static func callVoid(
    _ target: AnyObject,
    _ selectorName: String,
    _ arguments: [AnyObject?]
  ) throws {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector) else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    guard let method = class_getInstanceMethod(type(of: target), selector) else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    let expected = Int(method_getNumberOfArguments(method)) - 2
    guard expected == arguments.count else {
      throw IMCoreLookupError.argumentCountMismatch(
        selector: selectorName, expected: expected, given: arguments.count
      )
    }
    let implementation = method_getImplementation(method)

    switch arguments.count {
    case 3:
      typealias Three =
        @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
      let three = unsafeBitCast(implementation, to: Three.self)
      three(target, selector, arguments[0], arguments[1], arguments[2])
    case 4:
      typealias Four =
        @convention(c) (
          AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?
        ) -> Void
      let four = unsafeBitCast(implementation, to: Four.self)
      four(target, selector, arguments[0], arguments[1], arguments[2], arguments[3])
    default:
      throw IMCoreLookupError.unexpectedReturn(
        selector: selectorName, expected: "three or four object arguments"
      )
    }
  }

  // MARK: - Typed reads

  public static func string(_ target: AnyObject, _ selectorName: String) throws -> String? {
    try send(target, selectorName) as? String
  }

  public static func bool(_ target: AnyObject, _ selectorName: String) throws -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector) else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    guard let method = class_getInstanceMethod(type(of: target), selector) else {
      throw IMCoreLookupError.selectorMissing(
        class: String(describing: type(of: target)), selector: selectorName
      )
    }
    guard Int(method_getNumberOfArguments(method)) - 2 == 0 else {
      throw IMCoreLookupError.argumentCountMismatch(
        selector: selectorName, expected: Int(method_getNumberOfArguments(method)) - 2,
        given: 0
      )
    }
    // A BOOL return is a single byte, not an object. `perform` would interpret that byte
    // as a pointer — so `NO` reads as nil and `YES` reads as an address that is not an
    // object, which crashes on the next message sent to it.
    typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    let implementation = unsafeBitCast(method_getImplementation(method), to: BoolGetter.self)
    return implementation(target, selector)
  }

  public static func objects(_ target: AnyObject, _ selectorName: String) throws -> [AnyObject] {
    (try send(target, selectorName) as? [AnyObject]) ?? []
  }

  /// The `sharedInstance`-style singleton of a class, under whichever name it uses.
  ///
  /// IMCore is not consistent about this — `sharedInstance`, `sharedController`,
  /// `sharedRegistry` and `defaultInstance` all appear — so the accessor is discovered
  /// rather than assumed, which also absorbs a rename between releases.
  public static func sharedInstance(
    ofClass name: String,
    accessors: [String] = [
      "sharedInstance", "sharedController", "sharedRegistry", "defaultInstance",
    ]
  ) throws -> AnyObject {
    let type: AnyClass = try requireClass(name)
    for accessor in accessors {
      let selector = NSSelectorFromString(accessor)
      guard type.responds(to: selector) else { continue }
      if let instance = (type as AnyObject).perform(selector)?.takeUnretainedValue() {
        return instance
      }
    }
    throw IMCoreLookupError.selectorMissing(
      class: name, selector: accessors.joined(separator: " / ")
    )
  }
}

extension IMCoreRuntime {

  /// **Callers must already be on the main thread.**
  ///
  /// IMCore requires it and enforces it with `dispatch_assert_queue()`, which raises
  /// `EXC_BREAKPOINT` — `__builtin_trap`, not an `NSException`. Nothing can catch it and
  /// the process dies; measured, with `_dispatch_assert_queue_fail` at the top of a
  /// Messages crash report.
  ///
  /// That guarantee is provided STRUCTURALLY rather than defensively: `IMCoreBridge` is
  /// `@MainActor` and `HelperDispatch.perform` is too, so the hop happens once per request
  /// at the boundary and the compiler checks it. An earlier version forced the hop here
  /// with `DispatchQueue.main.sync` on every call, which worked but blocked a helper
  /// thread each time and could not run under `swift test` at all — a test host does not
  /// drain the main queue, so the suite deadlocked. Pushing the isolation up to the type
  /// removed both problems and the test-only escape hatch that had papered over the second.
  ///
  /// Nothing here dispatches. These functions run wherever their caller is, which in
  /// production is the main actor and in tests is the test thread — safe there, because
  /// Foundation objects assert no queue.

  /// Invokes a selector with any number of object arguments, inside the exception barrier.
  ///
  /// This is the general path, and it is what the send methods need: IMCore's message
  /// constructor takes ELEVEN arguments, which neither `perform` (two) nor the typed casts
  /// above (four) can reach. It is also the safest path, because every call goes through
  /// `@try/@catch` — Swift cannot catch an Objective-C `@throw`, and an uncaught one calls
  /// `abort()` in the host process.
  ///
  /// `NSNull` in `arguments` means an explicit nil, since an array cannot hold one.
  @discardableResult
  public static func invoke(
    _ target: AnyObject,
    _ selectorName: String,
    _ arguments: [Any] = []
  ) throws -> AnyObject? {
    let selector = NSSelectorFromString(selectorName)
    var result: AnyObject?
    var error: NSError?

    let ok = BBInvoke(target, selector, arguments, &result, &error)
    guard ok else {
      throw IMCoreLookupError.raised(
        selector: selectorName,
        reason: error?.localizedDescription ?? "unknown"
      )
    }
    return result
  }

  /// Invokes a selector that returns a scalar, and reads the scalar.
  ///
  /// `invoke` boxes a scalar return as an `NSNumber`; these three name what the caller
  /// actually wanted, so a call site does not repeat the cast and cannot quietly get it
  /// wrong. Distinct from `bool(_:_:)` and `integer(_:_:)` above in two ways that matter:
  /// those go through a typed IMP and therefore take NO arguments, and they are outside the
  /// exception barrier for argument marshalling because they have none to marshal.
  ///
  /// A method that returns `void`, a struct or a pointer answers nil here. That is reported
  /// as a lookup error rather than as a value, because asking for a number from a selector
  /// that has none to give is a mistake in the call site, not a state of the system.
  public static func number(
    _ target: AnyObject,
    _ selectorName: String,
    _ arguments: [Any] = []
  ) throws -> NSNumber {
    guard let number = try invoke(target, selectorName, arguments) as? NSNumber else {
      throw IMCoreLookupError.unexpectedReturn(
        selector: selectorName, expected: "a scalar return value"
      )
    }
    return number
  }

  /// A BOOL-returning selector WITH arguments — `bool(_:_:)` cannot take any.
  public static func callReturningBool(
    _ target: AnyObject,
    _ selectorName: String,
    _ arguments: [Any] = []
  ) throws -> Bool {
    try number(target, selectorName, arguments).boolValue
  }

  /// An integer-returning selector with or without arguments.
  public static func callReturningInteger(
    _ target: AnyObject,
    _ selectorName: String,
    _ arguments: [Any] = []
  ) throws -> Int {
    try number(target, selectorName, arguments).intValue
  }

  /// Runs a block inside the exception barrier.
  ///
  /// For the places that still use a typed cast — a BOOL getter, an integer return — where
  /// the call itself is correct but the callee may raise.
  public static func guarding<T>(_ selectorName: String, _ body: () -> T) throws -> T {
    var value: T?
    var error: NSError?
    let ok = BBCatchingExceptions({ value = body() }, &error)
    guard ok, let value else {
      throw IMCoreLookupError.raised(
        selector: selectorName,
        reason: error?.localizedDescription ?? "unknown"
      )
    }
    return value
  }
}
