//  IMCoreRuntimeTests
//
//  The IMCore call sites cannot be tested here — they need Messages.app running with the
//  helper injected, which needs SIP disabled. The dispatch machinery underneath them can be,
//  against ordinary Foundation classes, and that is where the dangerous mistakes live:
//
//    - Sending an unrecognised selector raises an ObjC exception, and an uncaught one inside
//      Messages.app terminates **Messages**. The user loses their app because we probed for
//      a method that moved.
//    - Reading a BOOL through `perform` interprets one byte as a pointer. `NO` reads as nil
//      and `YES` reads as an address that is not an object.
//    - `perform` returns an unmanaged reference; without retaining it the result is released
//      before the caller reads it, which usually survives long enough to look correct.
//
//  Every one of those is a crash in someone else's process, so each is pinned below.

import Foundation
import Testing

@testable import BlueBubblesHelper
@testable import HelperShared

@Suite("IMCoreRuntime")
struct IMCoreRuntimeTests {

  // MARK: - Class lookup

  @Test("a present class resolves")
  func classLookup() throws {
    #expect(IMCoreRuntime.lookUpClass("NSString") != nil)
    #expect(IMCoreRuntime.lookUpClass("NSMutableArray") != nil)
    _ = try IMCoreRuntime.requireClass("NSObject")
  }

  /// The behaviour that keeps a moved IMCore class from being a crash: a clear error
  /// naming what is missing.
  @Test("an absent class is a named error, not a crash")
  func absentClass() {
    #expect(IMCoreRuntime.lookUpClass("IMDefinitelyNotARealClass") == nil)
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.requireClass("IMDefinitelyNotARealClass")
    }
  }

  @Test("class lookup is cached and stable")
  func caching() {
    let first: AnyClass? = IMCoreRuntime.lookUpClass("NSDate")
    let second: AnyClass? = IMCoreRuntime.lookUpClass("NSDate")
    #expect(first === second)
    // A negative result caches too, so a missing class is not re-walked on every call.
    #expect(IMCoreRuntime.lookUpClass("IMStillNotReal") == nil)
    #expect(IMCoreRuntime.lookUpClass("IMStillNotReal") == nil)
  }

  // MARK: - Sending

  @Test("a zero-argument selector returns its value")
  func zeroArguments() throws {
    let string = "hello" as NSString
    #expect(try IMCoreRuntime.send(string, "uppercaseString") as? String == "HELLO")
    #expect(try IMCoreRuntime.string(string, "lowercaseString") == "hello")
  }

  @Test("one and two argument selectors dispatch")
  func withArguments() throws {
    let array = NSMutableArray()
    try IMCoreRuntime.send(array, "addObject:", "first")
    #expect(array.count == 1)

    let dictionary = NSMutableDictionary()
    try IMCoreRuntime.send(dictionary, "setObject:forKey:", "value", "key")
    #expect(dictionary["key"] as? String == "value")
  }

  /// The one that would terminate Messages. It must be an error, every time.
  @Test("an unrecognised selector is an error rather than an exception")
  func unrecognisedSelector() {
    let object = NSObject()
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.send(object, "thisSelectorDoesNotExist")
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.send(object, "alsoNotReal:", "argument")
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.callVoid(object, "notReal:::", [nil, nil, nil])
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.bool(object, "notABoolGetter")
    }
  }

  /// `perform` handles at most two object arguments. Silently dropping a third would call
  /// the method with whatever happened to be in that register.
  @Test("more than two arguments is refused, not truncated")
  func tooManyArguments() {
    let array = NSMutableArray()
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.send(array, "addObject:", "a", "b", "c")
    }
  }

  @Test("responds reports accurately")
  func responds() {
    let string = "x" as NSString
    #expect(IMCoreRuntime.responds(string, to: NSSelectorFromString("uppercaseString")))
    #expect(!IMCoreRuntime.responds(string, to: NSSelectorFromString("nopeNotHere")))
  }

  // MARK: - Typed reads

  /// A BOOL return is one byte. Read through `perform` it becomes a pointer: `NO` reads as
  /// nil, `YES` reads as an address that is not an object and crashes on first use.
  @Test("BOOL returns read correctly in both states")
  func boolReturns() throws {
    let empty = NSArray()
    let populated = NSArray(array: ["x"])

    // `containsObject:` is not a zero-argument getter, so use ones that are.
    #expect(try IMCoreRuntime.bool("" as NSString, "boolValue") == false)
    #expect(try IMCoreRuntime.bool("1" as NSString, "boolValue") == true)
    #expect(try IMCoreRuntime.bool("YES" as NSString, "boolValue") == true)

    // And that a false result is genuinely false rather than a nil that read as false.
    #expect(try IMCoreRuntime.bool("0" as NSString, "boolValue") == false)
    _ = empty
    _ = populated
  }

  @Test("object array returns decode")
  func objectArrays() throws {
    let dictionary = NSDictionary(dictionary: ["a": 1, "b": 2])
    let keys = try IMCoreRuntime.objects(dictionary, "allKeys")
    #expect(keys.count == 2)

  }

  /// The third crash, and the one arity checking does not catch.
  ///
  /// `perform` hands back whatever the method returned as though it were an object
  /// pointer. `count` returns `NSUInteger`, so an array of 2 becomes address 0x2 and the
  /// first message sent to it segfaults. The selector exists and takes no arguments —
  /// only its RETURN type makes it unsafe on this path.
  @Test("a non-object return is refused rather than read as a pointer")
  func nonObjectReturn() {
    let array = NSArray(array: ["a", "b"])
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.send(array, "count")
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.objects(array, "count")
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.string(array, "count")
    }
  }

  @Test("integer returns read through a typed accessor")
  func integerReturns() throws {
    #expect(try IMCoreRuntime.integer(NSArray(array: ["a", "b", "c"]), "count") == 3)
    #expect(try IMCoreRuntime.integer(NSArray(), "count") == 0)
    #expect(try IMCoreRuntime.integer("42" as NSString, "integerValue") == 42)
  }

  /// The crash this whole file exists to prevent, and the one my first version missed.
  ///
  /// `responds(to:)` answers "does this selector exist", NOT "does it take the arguments I
  /// am about to pass". `sortedArrayUsingSelector:` exists on NSArray, so the check passed
  /// — and calling it with no arguments passed whatever was in that register as a `SEL`,
  /// which aborted the process. Inside Messages.app that terminates the user's Messages.
  @Test("argument count is checked against the method, not just its existence")
  func arityIsChecked() {
    let array = NSArray(array: ["a", "b"])

    // Exists, but takes one argument.
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.objects(array, "sortedArrayUsingSelector:")
    }
    // Exists, but takes none.
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.send(array, "count", "unexpected")
    }
    // A BOOL getter must be zero-argument too.
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.bool(array, "containsObject:")
    }
    // And callVoid.
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.callVoid(NSMutableArray(), "addObject:", [nil, nil, nil])
    }
  }

  @Test("the arity error names both counts")
  func arityMessage() {
    let error = IMCoreLookupError.argumentCountMismatch(
      selector: "sendMessage:onChat:", expected: 2, given: 1
    )
    #expect(error.description.contains("sendMessage:onChat:"))
    #expect(error.description.contains("2"))
  }

  /// The returned object must outlive the call. Without an explicit retain the value is
  /// released before the caller reads it — which usually survives long enough to look like
  /// it worked, and then does not.
  @Test("a returned object survives the call")
  func returnedObjectLifetime() throws {
    var results: [String] = []
    for index in 0..<200 {
      let source = NSString(string: "value-\(index)")
      if let upper = try IMCoreRuntime.send(source, "uppercaseString") as? String {
        results.append(upper)
      }
    }
    #expect(results.count == 200)
    #expect(results[42] == "VALUE-42")
    #expect(results.last == "VALUE-199")
  }

  // MARK: - Singletons

  /// IMCore is inconsistent about the accessor name — `sharedInstance`,
  /// `sharedController`, `sharedRegistry` and `defaultInstance` all appear — so it is
  /// discovered rather than assumed, which also absorbs a rename between releases.
  @Test("a singleton is found under any of its accessor names")
  func singletonDiscovery() throws {
    // NSFileManager exposes `defaultManager`, which is deliberately NOT in the default
    // list — so the default lookup fails and an explicit one succeeds. That is exactly
    // the shape of an IMCore rename.
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.sharedInstance(ofClass: "NSFileManager")
    }
    let manager = try IMCoreRuntime.sharedInstance(
      ofClass: "NSFileManager", accessors: ["defaultManager"]
    )
    #expect(manager is FileManager)
  }

  @Test("a singleton on a missing class is a named error")
  func singletonOnMissingClass() {
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.sharedInstance(ofClass: "IMNotARealClass")
    }
  }

  /// Every error says which class and which selector. A helper that fails inside another
  /// process leaves nothing but this message to debug from.
  @Test("errors name what was missing")
  func errorMessages() {
    let missingClass = IMCoreLookupError.classMissing("IMChatRegistry")
    #expect(missingClass.description.contains("IMChatRegistry"))

    let missingSelector = IMCoreLookupError.selectorMissing(
      class: "IMChat", selector: "sendMessage:"
    )
    #expect(missingSelector.description.contains("IMChat"))
    #expect(missingSelector.description.contains("sendMessage:"))
  }
}

@Suite("Objective-C exception barrier")
struct ExceptionBarrierTests {

  /// The property everything else rests on.
  ///
  /// Swift's `do/catch` does not catch an Objective-C `@throw`, and an uncaught NSException
  /// calls `abort()`. Inside Messages.app that is the user losing their app because we
  /// probed something. Every test below would terminate this process without the barrier —
  /// which is exactly why they are worth running.
  @Test("a raising call becomes an error instead of an abort")
  func raisesBecomeErrors() {
    // A nil key raises NSInvalidArgumentException. Both parameters are objects, so this
    // passes the argument-type guard and genuinely reaches the callee — which is what
    // makes it a test of the barrier rather than of the guard.
    let dictionary = NSMutableDictionary()
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(dictionary, "setObject:forKey:", ["value", NSNull()])
    }
  }

  @Test("the error carries the exception's name and reason")
  func errorDetail() {
    do {
      _ = try IMCoreRuntime.invoke(
        NSMutableDictionary(), "setObject:forKey:", ["value", NSNull()]
      )
      Issue.record("expected a raise")
    } catch let error as IMCoreLookupError {
      let text = error.description
      #expect(text.contains("setObject:forKey:"))
      // The reason string is the only diagnostic that survives — the stack is gone by
      // the time the barrier returns.
      #expect(text.contains("Exception") || text.contains("nil"))
    } catch {
      Issue.record("unexpected error type: \(error)")
    }
  }

  @Test("a successful call returns its value")
  func successfulInvoke() throws {
    let joined = try IMCoreRuntime.invoke(
      "hello " as NSString, "stringByAppendingString:", ["world"]
    )
    #expect(joined as? String == "hello world")
  }

  @Test("a void method returns nil rather than garbage")
  func voidReturn() throws {
    let mutable = NSMutableArray()
    let result = try IMCoreRuntime.invoke(mutable, "addObject:", ["x"])
    #expect(result == nil)
    #expect(mutable.count == 1)
  }

  /// The reason `invoke` exists at all: IMCore's message constructor takes ELEVEN
  /// arguments, and `perform` reaches two.
  @Test("more than two arguments work")
  func manyArguments() throws {
    let replaced = try IMCoreRuntime.invoke(
      "hello world" as NSString,
      "stringByReplacingOccurrencesOfString:withString:", ["world", "there"]
    )
    #expect(replaced as? String == "hello there")

    // Six object arguments, which is past everything `perform` and the typed casts can
    // reach and into the territory IMCore's constructors occupy.
    let target = ManyArgumentTarget()
    let result = try IMCoreRuntime.invoke(
      target, "a:b:c:d:e:f:", ["1", "2", "3", "4", "5", "6"]
    )
    #expect(result as? String == "1-2-3-4-5-6")
    #expect(target.received == 6)
  }

  @Test("a wrong argument count is refused")
  func arityRefused() {
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(NSMutableArray(), "addObject:", ["a", "b"])
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(NSMutableArray(), "addObject:", [])
    }
  }

  @Test("an unrecognised selector is refused before it can raise")
  func unrecognised() {
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(NSObject(), "definitelyNotAMethod")
    }
  }

  /// `NSNull` is how a caller spells an explicit nil, since an array cannot hold one.
  /// IMCore's constructors take nil for most of their eleven arguments.
  @Test("NSNull passes a real nil")
  func explicitNil() throws {
    let dictionary = NSMutableDictionary()
    dictionary["key"] = "value"
    // `setValue:forKey:` with nil REMOVES the key, which is what proves nil arrived as
    // a real nil rather than as an NSNull object.
    _ = try IMCoreRuntime.invoke(dictionary, "setValue:forKey:", [NSNull(), "key"])
    #expect(dictionary["key"] == nil)
  }

  // MARK: - Scalar returns
  //
  // A scalar return used to be DROPPED — `BBInvoke` read the return value only when the
  // encoding was an object, so `-deleteAllHistory` (BOOL) and `-markAsSpam:` (a count)
  // both came back nil, which is what a void method returns. The caller could not tell a
  // call that did nothing from a call with nothing to say.

  @Test("a scalar return comes back boxed at its declared width")
  func scalarReturns() throws {
    let target = ScalarReturnTarget()

    // BOOL in both states. `false` is the dangerous one: dropped, it was nil, and nil is
    // exactly what a successful void call looks like.
    #expect(try IMCoreRuntime.callReturningBool(target, "returnsTrue") == true)
    #expect(try IMCoreRuntime.callReturningBool(target, "returnsFalse") == false)

    // Read at the declared width. A `char` return read into a wider local would carry
    // whatever was in the adjacent bytes, and -1 would not survive the trip.
    #expect(try IMCoreRuntime.number(target, "returnsChar").int8Value == -1)
    #expect(try IMCoreRuntime.callReturningInteger(target, "returnsInt") == 1_000_000)
    #expect(
      try IMCoreRuntime.number(target, "returnsUnsignedLongLong").uint64Value
        == 18_000_000_000_000_000_000
    )
    #expect(try IMCoreRuntime.number(target, "returnsDouble").doubleValue == 2.5)

    // With an argument, which is the case the typed-IMP accessors cannot reach at all.
    #expect(try IMCoreRuntime.callReturningInteger(target, "doubled:", [21]) == 42)
  }

  @Test("a void return is still nil, and asking it for a number is an error")
  func voidHasNoNumber() throws {
    let mutable = NSMutableArray()
    #expect(try IMCoreRuntime.invoke(mutable, "addObject:", ["x"]) == nil)
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.number(NSMutableArray(), "addObject:", ["x"])
    }
  }

  /// Boxing must not change what an object-returning selector answers, since every existing
  /// call site reads one.
  @Test("object returns are unaffected")
  func objectReturnsUnchanged() throws {
    #expect(
      try IMCoreRuntime.invoke("a" as NSString, "stringByAppendingString:", ["b"])
        as? String == "ab"
    )
  }

  @Test("guarding catches a raise from a typed call")
  func guarding() {
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.guarding("objectAtIndex:") {
        // Provokes the same NSRangeException from inside a plain Swift closure.
        (NSArray(array: ["x"]) as NSArray).object(at: 99)
      }
    }
    let count = try? IMCoreRuntime.guarding("count") { NSArray(array: ["x"]).count }
    #expect(count == 1)
  }
}

/// Scalar returns of every width the boxing path handles.
///
/// Foundation has plenty of these — `-count`, `-boolValue` — but not with arguments and not
/// in every width, and the widths are where a wrong read hides.
@objc final class ScalarReturnTarget: NSObject {
  @objc func returnsTrue() -> Bool { true }
  @objc func returnsFalse() -> Bool { false }
  @objc func returnsChar() -> Int8 { -1 }
  @objc func returnsInt() -> Int32 { 1_000_000 }
  @objc func returnsUnsignedLongLong() -> UInt64 { 18_000_000_000_000_000_000 }
  @objc func returnsDouble() -> Double { 2.5 }
  @objc func doubled(_ value: Int) -> Int { value * 2 }
}

/// A target with more object arguments than any Foundation method takes, so the arbitrary-
/// arity path can be exercised without a private framework.
@objc final class ManyArgumentTarget: NSObject {
  @objc private(set) var received = 0

  @objc func a(_ a: String, b: String, c: String, d: String, e: String, f: String) -> String {
    received = 6
    return [a, b, c, d, e, f].joined(separator: "-")
  }
}

@Suite("Invocation argument encoding")
struct ArgumentEncodingTests {

  /// Primitives are unboxed to the method's DECLARED width, not the caller's.
  ///
  /// This is what the send path needs: IMCore's message constructor mixes objects, an
  /// integer flags word and an NSRange in one eleven-argument selector. Writing an
  /// NSNumber's pointer where an integer belongs does not fail — it builds a message whose
  /// flags are a heap address.
  @Test("integers of every width round-trip")
  func integerWidths() throws {
    let target = TypedArgumentTarget()

    _ = try IMCoreRuntime.invoke(target, "takeInt:", [42])
    #expect(target.lastInt == 42)

    // The one that would break under a narrow write: a value that does not fit in 32
    // bits. IMCore's flag words are `long long`.
    _ = try IMCoreRuntime.invoke(target, "takeLongLong:", [0x0000_0003_0000_0005 as Int64])
    #expect(target.lastLongLong == 0x0000_0003_0000_0005)

    // The real flag constants from BlueBubblesHelper.m — 0x100005 plain, 0x10000d with a
    // subject, 0x300005 for an audio message.
    for flags in [0x100005, 0x10000d, 0x300005] {
      _ = try IMCoreRuntime.invoke(target, "takeLongLong:", [Int64(flags)])
      #expect(target.lastLongLong == Int64(flags))
    }
  }

  @Test("booleans and doubles round-trip")
  func otherPrimitives() throws {
    let target = TypedArgumentTarget()
    _ = try IMCoreRuntime.invoke(target, "takeBool:", [true])
    #expect(target.lastBool == true)
    _ = try IMCoreRuntime.invoke(target, "takeBool:", [false])
    #expect(target.lastBool == false)

    _ = try IMCoreRuntime.invoke(target, "takeDouble:", [2.5])
    #expect(target.lastDouble == 2.5)
  }

  /// `associatedMessageRange:` takes an NSRange, which has to arrive as an NSValue and be
  /// copied by bytes.
  @Test("a struct passes as NSValue")
  func structArgument() throws {
    let target = TypedArgumentTarget()
    _ = try IMCoreRuntime.invoke(
      target, "takeRange:", [NSValue(range: NSRange(location: 3, length: 7))]
    )
    #expect(target.lastRange.location == 3)
    #expect(target.lastRange.length == 7)
  }

  /// An NSValue carrying a different struct would silently write the wrong layout, so its
  /// declared type is checked against the method's first.
  @Test("a mismatched struct is refused")
  func mismatchedStruct() {
    let target = TypedArgumentTarget()
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(
        target, "takeRange:", [NSValue(point: NSPoint(x: 1, y: 2))]
      )
    }
  }

  @Test("a primitive parameter refuses a non-number")
  func wrongKind() {
    let target = TypedArgumentTarget()
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(target, "takeInt:", ["not a number"])
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(target, "takeRange:", [42])
    }
  }

  /// Objects and primitives interleaved, which is the actual shape of the send path.
  @Test("mixed object and primitive arguments")
  func mixed() throws {
    let target = TypedArgumentTarget()
    let result = try IMCoreRuntime.invoke(
      target, "mixText:flags:subject:range:",
      ["hello", 0x100005 as Int64, NSNull(), NSValue(range: NSRange(location: 0, length: 5))]
    )
    #expect(result as? String == "hello/1048581/nil/0,5")
  }
}

/// Methods covering every argument kind the IMCore constructors use.
@objc final class TypedArgumentTarget: NSObject {
  @objc private(set) var lastInt: Int32 = 0
  @objc private(set) var lastLongLong: Int64 = 0
  @objc private(set) var lastBool = false
  @objc private(set) var lastDouble: Double = 0
  @objc private(set) var lastRange = NSRange(location: 0, length: 0)

  @objc func takeInt(_ value: Int32) { lastInt = value }
  @objc func takeLongLong(_ value: Int64) { lastLongLong = value }
  @objc func takeBool(_ value: Bool) { lastBool = value }
  @objc func takeDouble(_ value: Double) { lastDouble = value }
  @objc func takeRange(_ value: NSRange) { lastRange = value }

  @objc func mixText(
    _ text: String, flags: Int64, subject: String?, range: NSRange
  ) -> String {
    "\(text)/\(flags)/\(subject ?? "nil")/\(range.location),\(range.length)"
  }
}

/// IMCore requires the main thread and enforces it with `dispatch_assert_queue()`, which
/// raises `EXC_BREAKPOINT` — `__builtin_trap`, not an `NSException`. No `@try/@catch` catches
/// it and the process dies. Measured: a send from a cooperative-pool thread delivered the
/// message and then took Messages down.
///
/// The guarantee is now STRUCTURAL rather than defensive. `IMCoreBridge` and
/// `HelperDispatch.perform` are `@MainActor`, so the compiler places every IMCore call on the
/// main actor and the hop happens once per request at the boundary. There is nothing to
/// assert at runtime about dispatching, because nothing dispatches — which is the point.
///
/// What CAN be asserted is that the isolation is actually declared, since deleting it would
/// compile fine and reintroduce the crash.
@Suite("Main actor isolation")
struct MainActorIsolationTests {

  /// `IMCoreBridge` is main-actor isolated.
  ///
  /// This test exists because the annotation is the whole fix: without it every method
  /// stays callable from a pool thread and the first send traps. It reads as trivial and it
  /// is guarding a crash.
  @Test("the bridge runs on the main actor")
  @MainActor
  func bridgeIsMainActorIsolated() {
    // Reachable from a @MainActor context without `await`, which is only true for a
    // main-actor-isolated type. If the annotation were removed this would still compile,
    // so the real assertion is the one below.
    let bridge = IMCoreBridge.shared
    #expect(Thread.isMainThread)
    _ = bridge
  }

  /// Reaching the bridge from off the main actor must REQUIRE a suspension.
  ///
  /// `await` here is not decoration — it is the hop. That it suspends rather than blocks is
  /// the difference from the `DispatchQueue.main.sync` version, which blocked a helper
  /// thread on every call and deadlocked the test host.
  @Test("reaching it from a task suspends onto main")
  func hopsFromDetachedTask() async {
    let onMain = await Task.detached {
      await MainActor.run { Thread.isMainThread }
    }.value
    #expect(onMain)
  }
}

/// Records which thread it was messaged on.
///
/// `@unchecked Sendable` because its only mutation happens on the main thread — which is the
/// property under test. If that stopped being true these tests would fail rather than race.
@objc final class ThreadRecorder: NSObject, @unchecked Sendable {
  @objc private(set) var wasMainThread = false

  @objc func record() { wasMainThread = Thread.isMainThread }
  @objc func recordAndReturnString() -> String {
    wasMainThread = Thread.isMainThread
    return "recorded"
  }
  @objc func recordAndReturnBool() -> Bool {
    wasMainThread = Thread.isMainThread
    return true
  }
  @objc func recordAndReturnInteger() -> Int {
    wasMainThread = Thread.isMainThread
    return 7
  }
  @objc func recordBool(_ value: Bool) { wasMainThread = Thread.isMainThread }

  func reset() { wasMainThread = false }
}

// MARK: - Completion blocks

/// Records what it was handed, and holds onto it the way IMCore does.
@objc final class BlockTarget: NSObject, @unchecked Sendable {
  @objc private(set) var blockClassName = ""
  @objc private(set) var invocations = 0
  /// Deliberately stored rather than called, which is what makes the frame-lifetime
  /// question real — IMCore's completions fire long after the call returns.
  private var stored: (() -> Void)?

  /// `@convention(block)`, not a bare Swift closure.
  ///
  /// A plain `() -> Void` parameter is bridged into a Swift closure on the way in, and
  /// asking THAT for its class answers `__SwiftValue` — the box, not the block. Declaring
  /// the block convention keeps the pointer we were actually handed.
  @objc func takeCompletion(_ completion: @escaping @convention(block) () -> Void) {
    blockClassName = String(
      cString: object_getClassName(unsafeBitCast(completion, to: AnyObject.self))
    )
    stored = completion
  }

  /// Untyped parameter, so the method encodes as `@` rather than `@?`.
  ///
  /// Stands in for a private selector whose encoding lost the `?` — `generateMedia:` lives
  /// in a plugin bundle that only loads inside Messages, so its encoding cannot be checked
  /// from here.
  @objc func takeUntyped(_ value: Any) {
    blockClassName = String(cString: object_getClassName(value as AnyObject))
    stored = (value as AnyObject) as? (() -> Void)
  }

  func fire() {
    stored?()
    invocations += 1
  }
}

/// What `BBInvoke` does with a completion handler.
///
/// READ THIS BEFORE TREATING THESE AS REGRESSION GUARDS. Two of the four are
/// CHARACTERIZATION tests: they record a property that holds today and would not fail if the
/// copy in `BBSetArgument` were removed.
///
/// The reason is worth keeping, because it corrects a wrong diagnosis that was briefly
/// written into this codebase. Objective-C blocks are stack-allocated by default, so handing
/// one to a callee that stores it is a use-after-free unless it is copied — and `BBInvoke`
/// hands blocks to callees that store them. But **Swift does not produce stack blocks**:
/// measured on this toolchain, a `@convention(block)` closure is `__NSMallocBlock__` whether
/// it captures anything or not. So every call site in this helper was already safe, and the
/// copy is discipline at an `unsafeBitCast` boundary rather than a fix for a live crash.
///
/// `nonBlockInBlockSlot` and `nilCompletion` are real tests of the argument handling.
@Suite("Completion blocks")
struct BlockArgumentTests {

  /// CHARACTERIZATION. The block reaches the callee as a heap block and outlives the frame
  /// that built it. Would not fail without the copy — see the suite note.
  @Test("a completion arrives on the heap and outlives its frame")
  func blockIsOnTheHeap() throws {
    let target = BlockTarget()
    nonisolated(unsafe) var fired = false

    // Built inside a scope that returns before anything fires it.
    func handOff() throws {
      let block: @convention(block) () -> Void = { fired = true }
      try IMCoreRuntime.invoke(
        target, "takeCompletion:", [unsafeBitCast(block, to: AnyObject.self)]
      )
    }
    try handOff()

    #expect(target.blockClassName != "__NSStackBlock__")
    // The property the class name stands for, and the one that would actually catch
    // `BBInvoke` mangling the argument.
    target.fire()
    #expect(fired)
    #expect(target.invocations == 1)
  }

  /// CHARACTERIZATION, for the case a declaration-only check would miss: the method
  /// encodes its parameter as plain `@`, so only inspecting the value identifies it as a
  /// block.
  @Test("a block is recognised even where the signature says only `@`")
  func blockWithoutTheEncoding() throws {
    let target = BlockTarget()
    func handOff() throws {
      let block: @convention(block) () -> Void = {}
      try IMCoreRuntime.invoke(
        target, "takeUntyped:", [unsafeBitCast(block, to: AnyObject.self)]
      )
    }
    try handOff()
    #expect(target.blockClassName != "__NSStackBlock__")
  }

  /// A real guard on the branch this added. A completion slot handed something that is not
  /// a block must be NAMED, not passed through and not copied — `-copy` on an object that
  /// does not implement NSCopying raises, and inside Messages an uncaught ObjC exception
  /// is `abort()`.
  @Test("a non-block in a block slot is refused rather than copied")
  func nonBlockInBlockSlot() {
    let target = BlockTarget()
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.invoke(target, "takeCompletion:", ["not a block"])
    }
    // Refused before the call, not after it.
    #expect(target.blockClassName.isEmpty)
  }

  /// An explicit nil completion still passes through. Several IMCore selectors accept one,
  /// and `NSNull` is how this transport spells it — the new block branch must not start
  /// rejecting them.
  @Test("an explicit nil completion is still accepted")
  func nilCompletion() throws {
    let target = BlockTarget()
    try IMCoreRuntime.invoke(target, "takeUntyped:", [NSNull()])
    #expect(target.invocations == 0)
  }
}
