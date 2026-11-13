//  BlockingCallPolicyTests
//  Calls that block the calling thread stay off the cooperative pool.
//
//  The Swift concurrency runtime has as many cooperative threads as the machine has cores,
//  and a synchronous call that waits on another process holds one of them for as long as it
//  waits. `Subprocess` has no blocking form for a caller to reach for, and the Automation
//  consent request, which holds a thread until a person answers a dialog, has one sanctioned
//  shape, which this scan keeps.

import BBTestCore
import Testing

@Suite("Blocking calls stay off the cooperative pool")
struct BlockingCallPolicyTests {

  static let oneConsentCall = PolicyRule(
    rule: "The Automation consent check is called in `automationConsent` only, because it blocks "
      + "the calling thread on an XPC round trip and on a person.",
    fix: "Call `automationConsent` instead of `AEDeterminePermissionToAutomateTarget`.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  static let boundedProbe = PolicyRule(
    rule: "`automationConsent` runs only inside `boundedSyncProbe`, on a thread of its own, never "
      + "on the cooperative pool.",
    fix: "Wrap the call in `boundedSyncProbe { … }`.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  static let loginItemsOffThePool = PolicyRule(
    rule: "`SMAppService` is called from `LaunchAtLogin` only, and only inside `offThePool`, "
      + "because each call blocks its thread on Background Task Management.",
    fix: "Add a `LaunchAtLogin` method whose body runs inside `offThePool { … }` and call that.",
    home: "Sources/BBSystem/LaunchAtLogin.swift, its header")

  static let addressBookOffThePool = PolicyRule(
    rule: "The whole-address-book enumeration runs in `ContactsIngestor.stream`, and `stream` "
      + "runs only inside `onOwnThread`, because it holds its thread for the whole pass.",
    fix: "Enumerate inside `ContactsIngestor.stream`, and call it from `onOwnThread { … }`.",
    home: "Sources/BBCore/OwnThread.swift")

  /// A full pass takes tens of seconds on a slow disk, and on a two-core Mac it held half the
  /// pool, with every HTTP request and service start queued behind it.
  @Test("The address-book enumeration runs only on a thread of its own")
  func addressBookEnumerationIsOffThePool() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 500)
    let ingest = "Sources/BBContacts/ContactsIngest.swift"
    let elsewhere = SourceScanner.offences(in: files) { file, line in
      file.path != ingest && line.code.contains("enumerateContacts(")
    }
    #expect(elsewhere.isEmpty, Self.addressBookOffThePool.comment(elsewhere))

    let lines = try SourceScanner.file(ingest).lines
    guard let streamStart = lines.firstIndex(where: { $0.code.contains("static func stream(") })
    else {
      Issue.record("`ContactsIngestor.stream` not found in \(ingest)")
      return
    }
    // Every enumeration sits after `stream` opens: it is the last function in its block, and
    // nothing else in the file enumerates the address book.
    let outside = lines.enumerated()
      .filter { $0.element.code.contains("enumerateContacts(") && $0.offset < streamStart }
      .map { "\(ingest):\($0.element.number): \($0.element.text)" }
    #expect(outside.isEmpty, Self.addressBookOffThePool.comment(outside))

    let calls = lines.enumerated().filter {
      $0.element.code.contains("Self.stream(into:") || $0.element.code.contains(" stream(into:")
    }
    #expect(!calls.isEmpty, "expected `stream(into:)` to be called")
    let onThePool = calls.filter { call in
      let window = lines[max(0, call.offset - 3)...call.offset]
      return !window.contains(where: { $0.code.contains("onOwnThread") })
    }.map { "\(ingest):\($0.element.number): \($0.element.text)" }
    #expect(onThePool.isEmpty, Self.addressBookOffThePool.comment(onThePool))
  }

  /// One `status` read can take tens of seconds on a Mac with a spinning disk, and the
  /// pool has a thread per core: two such calls on it and nothing else in the server runs.
  @Test("Login item calls run only on a thread of their own")
  func loginItemCallsAreOffThePool() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 500)
    let elsewhere = SourceScanner.offences(in: files) { file, line in
      file.path != "Sources/BBSystem/LaunchAtLogin.swift" && line.code.contains("SMAppService")
    }
    #expect(elsewhere.isEmpty, Self.loginItemsOffThePool.comment(elsewhere))

    let system = try SourceScanner.file("Sources/BBSystem/LaunchAtLogin.swift")
    let lines = system.lines
    var calls = 0
    var onThePool: [String] = []
    for (index, line) in lines.enumerated() {
      let code = line.code
      let blocking =
        code.contains(".register()") || code.contains(".unregister()")
        || (code.contains("currentStatus()") && !code.contains("func currentStatus("))
      guard blocking else { continue }
      calls += 1
      // Inside the closure, which opens within a few lines above the call.
      let window = lines[max(0, index - 12)...index]
      if !window.contains(where: { $0.code.contains("offThePool {") }) {
        onThePool.append("\(system.path):\(line.number): \(line.text)")
      }
    }
    #expect(calls >= 4, "expected status, register and both unregisters to be found")
    #expect(onThePool.isEmpty, Self.loginItemsOffThePool.comment(onThePool))
    // `service.status` is read in one function, which the scan above holds to the thread.
    let statusReads = lines.filter { $0.code.contains("service.status") }
    #expect(statusReads.count == 1, Self.loginItemsOffThePool.comment(statusReads.map(\.text)))
  }

  /// The consent check is an XPC round trip to `tccd`, and with `askUserIfNeeded` it also
  /// waits for a person. One function makes it, and nothing calls that function except
  /// through `boundedSyncProbe`, which runs it on a thread of its own.
  @Test("The Automation consent check runs only on a thread of its own")
  func automationConsentIsOffThePool() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 500)
    let direct = SourceScanner.offences(in: files) { _, line in
      line.code.contains("AEDeterminePermissionToAutomateTarget(")
    }
    #expect(
      direct.map(\.path) == ["Sources/BBSystem/Permissions.swift"],
      Self.oneConsentCall.comment(direct))

    let permissions = try SourceScanner.file("Sources/BBSystem/Permissions.swift")
    let lines = permissions.lines
    var calls = 0
    var unbounded: [String] = []
    for (index, line) in lines.enumerated()
    where line.code.contains("automationConsent(") && !line.code.contains("func automationConsent(")
    {
      calls += 1
      // The call sits inside the probe closure, which opens within a few lines above it.
      let window = lines[max(0, index - 6)...index]
      if !window.contains(where: { $0.code.contains("boundedSyncProbe(") }) {
        unbounded.append("\(permissions.path):\(line.number): \(line.text)")
      }
    }
    #expect(calls >= 2, "expected the probe and the request to call `automationConsent`")
    #expect(unbounded.isEmpty, Self.boundedProbe.comment(unbounded))
  }
}
