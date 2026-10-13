//  ServiceHealthReportingTests
//  A service whose health reads state that moves on its own tells the registry when it does.
//
//  `health` is read on demand and PUBLISHED on report: the registry re-reads every service's
//  health after a transition it performs, on `noteHealthChanged(_:)`, and on its periodic sweep.
//  So a health computed from something that changes without the registry (a runtime's status,
//  a listener that died, a permission revoked in System Settings, a webhook added over the
//  API) stays stale on every screen until one of those happens, and the sweep is a safety net
//  measured in tens of seconds, not the answer. The licence service was the case that found
//  this: a key redeemed after a failed first check left Home saying "cannot reach the license
//  service" for the life of the server.
//
//  The scan cannot know what a getter's `await` reaches, so the rule is mechanical: a `health`
//  getter that awaits anything belongs to a file that reports, or to the allowlist below with
//  the reason it need not.

import BBTestSupport
import Foundation
import Testing

@Suite("Service health reporting")
struct ServiceHealthReportingTests {

  /// Services whose `health` awaits something and that deliberately do not report.
  private static let exempt: [String: String] = [
    // Reads two settings, and a change to either restarts it through `apply`, which is a
    // transition the registry performs and publishes.
    "NtfyDeliveryService.swift": "settings only; `apply` restarts",
    // Reads `SMAppService`'s status, which moves when the person approves the item in
    // System Settings, and macOS raises no event for that. The registry's sweep is the
    // only way to notice, and it does.
    "LaunchAtLoginService.swift": "Login Items approval has no event; the sweep catches it",
  ]

  @Test("A health that awaits state reports its changes, or says why it need not")
  func awaitingHealthReports() throws {
    let files = try SourceScanner.swiftFiles(
      under: "Sources/BlueBubblesServerCore/Composition/Services")

    var offenders: [String] = []
    var seenExempt: Set<String> = []
    for file in files {
      // Comments removed, so a getter's doc that says "awaits" is not an await.
      let source = file.code
      guard let getter = Self.healthGetter(in: source), getter.contains("await") else { continue }
      if Self.exempt[file.name] != nil {
        seenExempt.insert(file.name)
        continue
      }
      if !source.contains("serviceHealthDidChange(Self.id)") {
        offenders.append(file.path)
      }
    }
    let listed = offenders.joined(separator: ", ")
    #expect(
      offenders.isEmpty,
      "these services compute `health` from state that moves and never report a change: \(listed)")
    // An exemption for a file that no longer needs one is a stale claim.
    let stale = Set(Self.exempt.keys).subtracting(seenExempt)
    #expect(stale.isEmpty, "stale exemption: \(stale)")
  }

  /// The body of `var health: ServiceHealth { … }`, up to its closing brace at the same
  /// indentation, or nil for a file that declares none.
  private static func healthGetter(in source: String) -> String? {
    guard let start = source.range(of: "var health: ServiceHealth") else { return nil }
    let lines = source[start.lowerBound...].split(separator: "\n", omittingEmptySubsequences: false)
    var body: [Substring] = []
    for line in lines {
      body.append(line)
      // The declaration sits at two spaces inside the actor; its closing brace is the first
      // line after it that is exactly that.
      if body.count > 1, line == "  }" { break }
      // A one-line getter closes on its own line.
      if body.count == 1, line.hasSuffix("} }") || line.hasSuffix("}") && line.contains("{ .") {
        break
      }
    }
    return body.joined(separator: "\n")
  }
}
