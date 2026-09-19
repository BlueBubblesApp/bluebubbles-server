//  ProxyMethodSilenceTests
//  A connection method that declines to start says why.
//
//  `ProxyService.start` used to speak for every method that returned nil, and it said one
//  thing: "<name> is selected but not installed". That is true of exactly one of the reasons a
//  method returns nil, and false of the rest — so a zrok whose share could not be reserved
//  told a user with zrok installed and running to install zrok, 178 times, beside the accurate
//  alert the method itself had raised. It now says that only when the binary really is absent.
//
//  Which moves the burden here: nil means "I have explained myself" to everything downstream,
//  so a `catch` that returns nil without raising anything is now a connection method that
//  declines silently and leaves the user with a server nothing can reach and no reason given.
//  Two of them existed, one on each of zrok's setup paths.
//
//  A scan rather than a behavioural test: reaching the branch needs a whole host (settings, a
//  tool manager, an alert centre) and the rule is about what the SOURCE may not do.

import Foundation
import Testing

@Suite("Connection methods explain a refusal")
struct ProxyMethodSilenceTests {

  private static var directory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources/BlueBubblesServerCore/Composition/Services/Proxy")
  }

  @Test("No connection method swallows a failure and returns nil")
  func noSilentNilReturns() throws {
    var offenders: [String] = []
    var scanned = 0
    let files = try #require(FileManager.default.enumerator(atPath: Self.directory.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      let source = try String(
        contentsOf: Self.directory.appending(path: relative), encoding: .utf8)
      scanned += 1
      let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() where line.contains("catch {") {
        // The body of a `catch` that says nothing before giving up. Only the next few lines
        // are read: a catch that goes on to do real work is not what this is looking for.
        let body = lines[index...].prefix(6).joined(separator: "\n")
        guard body.contains("return nil") else { continue }
        let explanation = body.prefix(while: { _ in true })
        if !explanation.contains("complain"), !explanation.contains("logger.") {
          offenders.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
      }
    }
    // A FLOOR on what was scanned. A walk that finds nothing passes, and the rule then stops
    // being enforced while looking exactly like compliance.
    #expect(scanned >= 3, "only \(scanned) files scanned; the proxy directory moved")
    #expect(
      offenders.isEmpty,
      """
      A connection method returns nil without saying why, and nothing downstream says it \
      for them any more: \(offenders.joined(separator: "\n"))
      """)
  }
}
