//  BlockingCallPolicyTests
//  Calls that block the calling thread stay off the cooperative pool.
//
//  The Swift concurrency runtime has as many cooperative threads as the machine has cores,
//  and a synchronous call that waits on another process holds one of them for as long as it
//  waits. Two such calls had been reached from async code: an unpack that could hold a thread
//  for five minutes, and the Automation consent request, which holds one until a person
//  answers a dialog. Each now has one sanctioned shape, and this scan keeps it that way.

import BBTestSupport
import Testing

@Suite("Blocking calls stay off the cooperative pool")
struct BlockingCallPolicyTests {

  /// `Subprocess.runSynchronously` exists for a caller that cannot suspend at all, and its
  /// own documentation says not to reach for it anywhere else. Each file here says why it
  /// cannot: a default argument (`MessagesScripts`) and a synchronous protocol requirement
  /// with a test double behind it (`DylibInjector.architectures`).
  @Test("The blocking subprocess form is used only where nothing can suspend")
  func runSynchronouslyIsConfined() throws {
    let allowed: Set<String> = [
      "Sources/BBAppleScript/MessagesScripts.swift",
      "Sources/BBPrivateAPI/DylibInjector.swift",
    ]
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 500)
      .filter { !allowed.contains($0.path) }
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains("Subprocess.runSynchronously(")
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a caller blocks its thread on a subprocess; use `Subprocess.run`:\n"
          + offences.report))
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
      Comment(
        rawValue: "the consent check is called outside `automationConsent`:\n" + direct.report))

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
    #expect(
      unbounded.isEmpty,
      Comment(
        rawValue: "`automationConsent` is called outside `boundedSyncProbe`:\n"
          + unbounded.joined(separator: "\n")))
  }
}
