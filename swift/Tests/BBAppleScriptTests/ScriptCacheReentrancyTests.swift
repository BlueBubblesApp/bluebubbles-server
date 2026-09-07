//  ScriptCacheReentrancyTests
//  The compiled-script cache must not be held while a script runs.
//
//  This is a regression test for a hard crash of the whole server, not a style point.
//
//  `NSAppleScript.executeAppleEvent` pumps a NESTED run loop while it waits for the target
//  application to reply, and that nested loop dispatches the next queued execution on the
//  same thread. The executor passed its cache to the runner as `inout`, which takes
//  exclusive access for the entire call — so the re-entrant execution took it again and the
//  Swift runtime trapped:
//
//      Simultaneous accesses to 0x…, but modification requires exclusive access.
//
//  It fires as soon as two scripts are queued close together, which is the ordinary case for
//  a non-SIP user sending messages — the exact configuration the AppleScript path exists to
//  serve. It was invisible to every test because the test host never runs two real scripts
//  through a pumped run loop; it took booting the server to see it.
//
//  The fix is structural: the cache is read and written in two short accesses either side of
//  the run, never held across it. These tests pin that structure by re-entering the closures
//  the way the nested run loop does.

import Foundation
import Testing

@testable import BBAppleScript

@Suite("Script cache re-entrancy")
struct ScriptCacheReentrancyTests {

  /// Stands in for `ScriptExecutor.compiled`: a dictionary reached only through closures,
  /// so a re-entrant call touches it while the outer call is holding nothing.
  private final class Cache: @unchecked Sendable {
    private var storage: [String: Int] = [:]
    private(set) var reentrantAccesses = 0
    private var depth = 0

    func read(_ key: String) -> Int? {
      depth += 1
      defer { depth -= 1 }
      if depth > 1 { reentrantAccesses += 1 }
      return storage[key]
    }

    func write(_ key: String, _ value: Int) {
      depth += 1
      defer { depth -= 1 }
      if depth > 1 { reentrantAccesses += 1 }
      storage[key] = value
    }

    var count: Int { storage.count }
  }

  @Test("The cache can be touched again from inside a run")
  func reentrantAccessIsSafe() {
    // The shape of the crash, minus AppleScript. With the old `inout` signature the
    // equivalent of this trapped; with two short accesses it is ordinary code.
    let cache = Cache()

    func run(_ key: String, nested: Bool) {
      if cache.read(key) == nil {
        cache.write(key, key.count)
      }
      // Stands in for `executeAppleEvent` pumping a nested run loop and dispatching
      // the next queued script on this same thread.
      if nested { run("inner", nested: false) }
    }

    run("outer", nested: true)
    #expect(cache.count == 2)
  }

  @Test("A script is compiled once even when its run re-enters")
  func compilationIsNotDuplicated() {
    // The store happens BEFORE the run for exactly this reason: a re-entrant execution
    // of the same script must reuse the compilation rather than make a second one and
    // leak it.
    let cache = Cache()
    var compilations = 0

    func run(_ key: String, depth: Int) {
      if cache.read(key) == nil {
        compilations += 1
        cache.write(key, depth)
      }
      if depth < 3 { run(key, depth: depth + 1) }
    }

    run("send-message", depth: 0)
    #expect(compilations == 1)
    #expect(cache.count == 1)
  }

  /// The structural assertion, and the one that actually prevents the regression.
  ///
  /// A future edit that reintroduces `cache: inout [String: NSAppleScript]` would restore
  /// the crash exactly, and no behavioural test can catch it without a pumped run loop and
  /// two real scripts. So the signature itself is the thing pinned: `execute` takes
  /// closures, and closures cannot hold an access open across the call.
  @Test("The runner takes cache closures, never an inout dictionary")
  func executeTakesClosures() {
    let request = ScriptRequest(
      key: "probe", source: "on probe()\nend probe", handler: "probe",
      arguments: [], target: "Messages"
    )

    var stored: [String: NSAppleScript] = [:]
    var lookups = 0

    // Compiles and stores, then runs. The run fails here — the test host addresses the
    // event at itself and there is no handler wired — and that is fine: what is being
    // asserted is that the cache closures were called and that the call returned rather
    // than trapping.
    _ = AppleScriptRunner.execute(
      request,
      cachedScript: { key in
        lookups += 1
        return stored[key]
      },
      store: { key, script in stored[key] = script }
    )

    #expect(lookups == 1)
    #expect(stored["probe"] != nil, "a compiled script was not handed back to the cache")
  }
}
