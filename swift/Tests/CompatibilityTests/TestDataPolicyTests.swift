//  TestDataPolicyTests
//  CONTRIBUTING § "Test data: never real addresses", enforced instead of asked for.
//
//  The policy is unambiguous — no phone number, email, chat GUID or message body from
//  anyone's real chat.db, "not in a test, not in a fixture, not in a comment" — and it had
//  drifted anyway, because nothing checked it. A sweep found a real Gmail address serving as
//  a worked example in two source files and two tests, a second one in the FaceTime helper,
//  a maintainer's own address in the conformance recorder, and two phone numbers on live
//  area codes in wire-shape tests.
//
//  Those addresses are deliberately NOT quoted here. A file that enforces the rule must not
//  be the last place in the repository still breaking it — which it was, on the first run.
//
//  None of that is catchable by review at the moment it is written: an address in a comment
//  looks like documentation, and the reviewer has no way to know whose it is. So it is
//  checked here, in the same shape as `NamingConventionTests` — read the sources, assert the
//  rule.
//
//  WHAT COUNTS AS SAFE
//
//  The property that matters is that a committed value CANNOT REACH A PERSON, which is
//  slightly broader than the single example CONTRIBUTING gives:
//
//    * `NPA-555-0100`–`0199` — the block reserved for fiction, valid area code. The
//      documented form, and what new data should use.
//    * Area code 555 — not assignable to anyone, so `+1555…` cannot route whatever follows.
//      This is what the conformance recorder substitutes (`+15555550100`), and it is why
//      the recorded corpus passes without being rewritten.
//
//  Emails must sit on a domain that can never receive mail: the RFC 2606 `example.*` names
//  and the reserved TLDs.
//
//  EXEMPTIONS are listed explicitly below, each with the reason. They are all identifiers of
//  a SERVICE rather than of a person — `gmail.com` where the code infers a Google account
//  from it, Google's service-account domains, and the project's own published contact
//  address in the licence files.

import Foundation
import Testing

@Suite("Test data policy")
struct TestDataPolicyTests {

  // MARK: - What is allowed

  /// Domains that can never receive mail.
  private static let reservedDomains: Set<String> = [
    "example.com", "example.org", "example.net", "example.edu",
  ]
  private static let reservedTLDs: Set<String> = ["invalid", "test", "localhost", "example"]

  /// Addresses that name a SERVICE, not a person.
  ///
  /// Each is load-bearing where it appears: removing it does not tidy a test, it breaks one.
  private static let exemptAddresses: Set<String> = [
    // `ContactAccount.infer` keys on `lowered.contains("gmail")`, so the test that proves a
    // CardDAV container is a Google account has to use a Google address.
    "me@gmail.com",
    // The project's own published contact address, in the licence and CLA files.
    "bluebubblesapp@gmail.com",
  ]

  /// Domains that identify a service.
  private static let exemptDomains: Set<String> = [
    // Google service accounts. Synthetic project ids, and the shape is what the push
    // credential parser is being tested against.
    "iam.gserviceaccount.com",
    "appspot.gserviceaccount.com",
    // Git identities in commit trailers and workflow files.
    "users.noreply.github.com",
    "noreply.github.com",
    "anthropic.com",
  ]

  // MARK: - Detection
  //
  // Deliberately conservative: only strings WRITTEN AS a phone number are considered. A bare
  // run of ten digits is far more often a timestamp, a row id, a hash or a blurhash alphabet,
  // and a check that cries wolf on those gets disabled rather than obeyed.

  private static let phonePatterns = [
    #"\+\d{10,15}"#,  // E.164
    #"\(\d{3}\)\s?\d{3}-\d{4}"#,  // (202) 555-0143
    #"\b\d{3}-\d{3}-\d{4}\b"#,  // 202-555-0143
    #"\b\d{3}\.\d{3}\.\d{4}\b"#,  // 202.555.0143
  ]

  private static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#

  /// Whether a phone-shaped string is incapable of reaching anyone.
  static func isUnroutable(_ raw: String) -> Bool {
    var digits = raw.filter(\.isNumber)
    // Non-North-American numbers are judged by their own reserved ranges.
    if !raw.hasPrefix("+") || raw.hasPrefix("+1") {
      if digits.count == 11, digits.hasPrefix("1") { digits = String(digits.dropFirst()) }
      guard digits.count == 10 else {
        // Not an NANP number; fall through to the international ranges.
        return isReservedInternational(raw)
      }
      let npa = String(digits.prefix(3))
      let nxx = String(digits.dropFirst(3).prefix(3))
      let line = Int(String(digits.suffix(4))) ?? -1
      // Area code 555 is unassignable, so nothing behind it can route.
      if npa == "555" { return true }
      // The block reserved for fiction.
      return nxx == "555" && (100...199).contains(line)
    }
    return isReservedInternational(raw)
  }

  /// Ranges other regulators reserve for drama and documentation.
  private static func isReservedInternational(_ raw: String) -> Bool {
    let digits = raw.filter(\.isNumber)
    // Ofcom reserves these for drama and documentation: 07700 900000–900999 (mobile) and
    // 020 7946 0000–0999 (London), which are +447700900xxx and +442079460xxx in E.164.
    return digits.hasPrefix("447700900") || digits.hasPrefix("442079460")
  }

  static func isReservedEmail(_ raw: String) -> Bool {
    var lowered = raw.lowercased()
    if exemptAddresses.contains(lowered) { return true }

    // A recorded fixture is NAMED after the request it captured, so a filename like
    // `get_api_v1_contact_person@example.com_avatar-5baa61-200.json` looks to the pattern
    // like an address at the domain `example.com_avatar-5baa61-200.json`. Trimming the
    // fixture suffix judges the address itself, which is what this check is for — and it
    // judges it strictly, since what is left still has to be a reserved domain.
    if lowered.hasSuffix(".json"), let hyphen = lowered.lastIndex(of: "-"),
      let previous = lowered[..<hyphen].lastIndex(of: "-")
    {
      lowered = String(lowered[..<previous])
    }

    guard let domain = lowered.split(separator: "@").last.map(String.init) else { return false }
    if reservedDomains.contains(domain) { return true }
    if let tld = domain.split(separator: ".").last.map(String.init),
      reservedTLDs.contains(tld)
    {
      return true
    }
    return exemptDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) })
  }

  // MARK: - The check

  @Test("No committed email can reach a real mailbox")
  func emailsAreReserved() throws {
    let regex = try Regex(Self.emailPattern)
    var offenders: [String: Set<String>] = [:]

    for file in try Sources.scannable() {
      let text = try String(contentsOf: file, encoding: .utf8)
      for match in text.matches(of: regex) {
        let address = String(text[match.range])
        guard !Self.isReservedEmail(address) else { continue }
        offenders[address, default: []].insert(Sources.label(file))
      }
    }

    #expect(
      offenders.isEmpty,
      """
      Addresses outside the reserved domains — CONTRIBUTING § "Test data: never real \
      addresses". Use `someone@example.com`, or add a documented exemption to this file if \
      the domain names a SERVICE rather than a person:
      \(Self.describe(offenders))
      """
    )
  }

  @Test("No committed phone number can reach a real handset")
  func phoneNumbersAreUnroutable() throws {
    var offenders: [String: Set<String>] = [:]

    for pattern in Self.phonePatterns {
      let regex = try Regex(pattern)
      for file in try Sources.scannable() {
        let text = try String(contentsOf: file, encoding: .utf8)
        for match in text.matches(of: regex) {
          let number = String(text[match.range])
          guard !Self.isUnroutable(number) else { continue }
          offenders[number, default: []].insert(Sources.label(file))
        }
      }
    }

    #expect(
      offenders.isEmpty,
      """
      Numbers that could route to someone — CONTRIBUTING § "Test data: never real \
      addresses". Use `+12025550143` (NPA-555-0100..0199):
      \(Self.describe(offenders))
      """
    )
  }

  /// Guards the guard: a detector that stopped recognising anything would pass silently.
  @Test("The detector recognises what it is supposed to reject")
  func detectorWorks() {
    // Safe.
    #expect(Self.isUnroutable("+12025550143"))
    #expect(Self.isUnroutable("(202) 555-0143"))
    #expect(Self.isUnroutable("+15555550100"))  // area code 555
    #expect(Self.isUnroutable("+447700900123"))
    #expect(Self.isReservedEmail("someone@example.com"))
    #expect(Self.isReservedEmail("a@example.invalid"))

    // Not safe.
    #expect(!Self.isUnroutable("+16166342963"))
    #expect(!Self.isUnroutable("+12025551234"))  // 555 exchange, line outside 0100-0199
    #expect(!Self.isReservedEmail("someone@gmail.com"))
    #expect(!Self.isReservedEmail("nobody@not-a-reserved-domain.com"))
  }

  private static func describe(_ offenders: [String: Set<String>]) -> String {
    offenders.sorted { $0.key < $1.key }
      .map { "  \($0.key)  in \($0.value.sorted().joined(separator: ", "))" }
      .joined(separator: "\n")
  }
}

// MARK: - Reading the tree

private enum Sources {
  static var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CompatibilityTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
  }

  static func label(_ url: URL) -> String {
    url.path.replacingOccurrences(of: root.path + "/", with: "")
  }

  /// Everything a person writes. Excludes build products, vendored third-party bundles, and
  /// the recorded corpus — the corpus is scrubbed by the recorder, whose own self-test is
  /// where that behaviour is pinned.
  static func scannable() throws -> [URL] {
    let roots = ["Sources", "Tests", "Helper", "Tools"].map(root.appendingPathComponent)
    let extensions: Set<String> = ["swift", "mjs", "js", "py", "json", "md"]
    var files: [URL] = []
    for directory in roots {
      guard
        let walker = FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: nil)
      else { continue }
      for case let url as URL in walker {
        let path = url.path
        if path.contains("/.build/") || path.contains("/node_modules/")
          || path.contains("/Resources/APIDocs/")
          // This file states the rule, so it has to contain examples of what the rule
          // forbids — the exemption list and the detector's own negative cases. Scanning
          // it would make the check permanently red on its own contents.
          || url.lastPathComponent == "TestDataPolicyTests.swift"
        {
          continue
        }
        if extensions.contains(url.pathExtension) { files.append(url) }
      }
    }
    return files
  }
}
