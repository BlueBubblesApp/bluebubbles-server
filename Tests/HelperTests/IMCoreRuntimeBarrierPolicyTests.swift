//  IMCoreRuntimeBarrierPolicyTests
//  Every call the helper makes into Objective-C runs inside the exception barrier.
//
//  Swift cannot catch an Objective-C `@throw`, and an uncaught one is `abort()` inside the
//  user's Messages. The failure this prevents is a door that LOOKS guarded: `send` and
//  `callBool` are used for writes (`addHandler:`, `setLocalUserIsTyping:`), and a raise from
//  one of those outside the barrier unwinds through Swift frames, abandons the dispatch task
//  after the write applied, and leaves the caller waiting out its timeout.
//
//  Two halves. The scan holds the shape: inside `IMCoreRuntime.swift`, a `perform` or a call
//  through a typed IMP (always bound as `imp`) sits inside a `guarding` closure, and nothing
//  outside that file takes an IMP for itself. The behavioural tests prove the barrier is
//  really there: each one raises from the callee, and without the barrier the test process
//  aborts rather than failing.

import BBTestSupport
import Foundation
import HelperShared
import Testing

@Suite("IMCoreRuntime barrier policy")
struct IMCoreRuntimeBarrierPolicyTests {

  private static let door = "Helper/HelperShared/IMCoreRuntime.swift"

  /// Whether a code line DISPATCHES: a `perform` or a call through a typed IMP.
  private static func dispatches(_ code: String) -> Bool {
    code.contains(".perform(selector") || code.contains("imp(target")
  }

  @Test("Inside IMCoreRuntime, every dispatch is inside `guarding`")
  func doorDispatchesAreGuarded() throws {
    let file = try SourceScanner.file(Self.door)
    let lines = file.codeLines
    var dispatches = 0
    var offences: [Offence] = []
    for (index, line) in lines.enumerated() where Self.dispatches(line.code) {
      dispatches += 1
      // Walk back to whichever comes first: the `guarding(` that opens the closure this
      // dispatch is in, or the declaration of the function it is in. Neither closure nor
      // function nests the other here, so the first one found decides.
      let opener = lines[...index].reversed().first {
        $0.code.contains("guarding(") || $0.code.contains(" func ")
      }
      if opener?.code.contains("guarding(") != true {
        offences.append(Offence(file, line))
      }
    }
    // Non-vacuity: `send` performs three ways, and seven typed IMP calls follow it.
    #expect(dispatches >= 10, "expected the door's dispatches; found \(dispatches)")
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "wrap the call in `try guarding(selectorName) { … }` so a raise is an "
          + "error rather than an abort inside Messages:\n" + offences.report))

    // A typed IMP bound under any other name would be invisible to the scan above.
    let unnamed = SourceScanner.offences(in: [file]) { _, line in
      line.code.contains("unsafeBitCast(") && !line.code.contains("let imp = ")
    }
    #expect(
      unnamed.isEmpty,
      Comment(rawValue: "bind a typed IMP as `let imp = …`:\n" + unnamed.report))
  }

  @Test("Nothing outside IMCoreRuntime calls an IMP or a C symbol unguarded")
  func nothingDispatchesAroundTheDoor() throws {
    let sources = try SourceScanner.swiftFiles(under: "Helper", minimum: 11)
      .filter { $0.path != Self.door }
    let rawIMPs = SourceScanner.offences(in: sources) { _, line in
      line.code.contains("method_getImplementation(")
        || (line.code.contains(".perform(") && line.code.contains("Selector"))
    }
    #expect(
      rawIMPs.isEmpty,
      Comment(rawValue: "go through IMCoreRuntime instead:\n" + rawIMPs.report))

    // A C function looked up by name is called through a `@convention(c)` cast, which no
    // door can reach; such a file must call it inside `IMCoreRuntime.guarding`.
    let unguarded = sources.filter {
      $0.code.contains("@convention(c)") && !$0.code.contains("IMCoreRuntime.guarding(")
    }
    #expect(
      unguarded.isEmpty,
      "call the symbol inside IMCoreRuntime.guarding: \(unguarded.map(\.path))")
  }
}

/// A target whose every method raises, one per dispatch shape the runtime has.
@objc final class RaisingTarget: NSObject {
  private func raise(_ name: String) -> Never {
    NSException(name: .invalidArgumentException, reason: name, userInfo: nil).raise()
    fatalError("unreachable")
  }
  @objc func noArguments() -> AnyObject? { raise("noArguments") }
  @objc func setValue(_ value: AnyObject?) { raise("setValue") }
  @objc func setFlag(_ flag: Bool) { raise("setFlag") }
  @objc func a(_ a: AnyObject?, b: AnyObject?, c: AnyObject?) { raise("a:b:c:") }
  @objc func a(_ a: AnyObject?, b: AnyObject?, c: AnyObject?, d: AnyObject?) {
    raise("a:b:c:d:")
  }
  @objc var flag: Bool { raise("flag") }
  @objc var count: Int { raise("count") }
  @objc var ratio: Double { raise("ratio") }
  @objc func matches(_ other: AnyObject?) -> Bool { raise("matches") }
}

@Suite("Every IMCoreRuntime door is behind the barrier")
struct IMCoreRuntimeDoorBarrierTests {

  /// Each of these would `abort()` the test process without the barrier, which is what a
  /// raise inside Messages does to the user's Messages.
  @Test("A raise through any door is an error, not an abort")
  func everyDoorCatches() {
    let target = RaisingTarget()
    #expect(throws: IMCoreLookupError.self) { try IMCoreRuntime.send(target, "noArguments") }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.send(target, "setValue:", "x")
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.callBool(target, "setFlag:", true)
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.callVoid(target, "a:b:c:", [nil, nil, nil])
    }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.callVoid(target, "a:b:c:d:", [nil, nil, nil, nil])
    }
    #expect(throws: IMCoreLookupError.self) { try IMCoreRuntime.bool(target, "flag") }
    #expect(throws: IMCoreLookupError.self) { try IMCoreRuntime.integer(target, "count") }
    #expect(throws: IMCoreLookupError.self) { try IMCoreRuntime.double(target, "ratio") }
    #expect(throws: IMCoreLookupError.self) {
      try IMCoreRuntime.bool(target, "matches:", with: nil)
    }
  }

  @Test("The error names the selector and the exception's reason")
  func errorNamesTheCall() {
    do {
      try IMCoreRuntime.callBool(RaisingTarget(), "setFlag:", false)
      Issue.record("expected a raise")
    } catch let error as IMCoreLookupError {
      guard case .raised(let selector, let reason) = error else {
        Issue.record("expected .raised, got \(error)")
        return
      }
      #expect(selector == "setFlag:")
      #expect(reason.contains("setFlag"))
    } catch {
      Issue.record("unexpected error type: \(error)")
    }
  }
}
