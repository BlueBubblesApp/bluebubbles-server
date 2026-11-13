//  SubscriptionSchemaTests
//  That the published 402 describes the 402 the server actually sends.
//
//  The reason strings are a frozen contract — once a client branches on one of them it cannot
//  be renamed — and they are written down twice: once on `LicenseRefusal`, which produces
//  them, and once in `OpenAPIDocument.refusalReasons`, which documents them. `LicenseRefusal`
//  is not `CaseIterable` and should not become so to serve a document generator, so the
//  transcription is deliberate and this is what stops it rotting.
//
//  It is not hypothetical. The `errorTypes` list in the same file is the same kind of
//  transcription and was one value short: the server could already answer `Payment Required`
//  while the document said that was not a legal value. Nothing caught it, because nothing
//  compared the two.
//
//  The enum below is the whole point of the suite: adding a case to `LicenseRefusal` fails to
//  compile HERE, in a file whose job is to notice, rather than shipping a documented enum that
//  silently omits it.

import Foundation
import Testing

@testable import BBLicense
@testable import BBOpenAPI

@Suite("Subscription refusal schema")
struct SubscriptionSchemaTests {

  /// Every case, with a representative value for the two that carry one.
  ///
  /// Exhaustive by construction: the `switch` is over `LicenseRefusal`, so a new case is a
  /// compile error here and not a documentation gap found by a client.
  static var everyRefusal: [LicenseRefusal] {
    let sample: [LicenseRefusal] = [
      .noLicense,
      .expired(at: Date(timeIntervalSince1970: 1_700_000_000)),
      .revoked,
      .insufficientTier(required: .pro, held: .pro),
      .machineMismatch,
      .unverifiable,
    ]
    // Forces the list above to be revisited when a case is added. The switch itself does
    // nothing; not compiling is its job.
    for refusal in sample {
      switch refusal {
      case .noLicense, .expired, .revoked, .insufficientTier, .machineMismatch, .unverifiable:
        continue
      }
    }
    return sample
  }

  @Test("Every refusal the server can send is documented, and nothing else is")
  func reasonsMatch() {
    let produced = Set(Self.everyRefusal.map(\.reason))
    let documented = Set(OpenAPIDocument.refusalReasons.map(\.0))

    #expect(
      produced == documented,
      Comment(
        rawValue: "the documented reasons and the ones `LicenseRefusal` produces differ.\n"
          + "undocumented: \(produced.subtracting(documented).sorted())\n"
          + "documented but never sent: \(documented.subtracting(produced).sorted())"))
  }

  /// A reason with no explanation is a reason a client author has to guess at, and the guess
  /// that matters is `validation_unavailable`, which looks like an expiry and is not.
  @Test("Each documented reason carries an explanation")
  func reasonsAreExplained() {
    for (reason, explanation) in OpenAPIDocument.refusalReasons {
      #expect(!explanation.isEmpty, "\(reason) has no explanation")
      #expect(explanation.count > 20, "\(reason)'s explanation is too short to help")
    }
  }

  /// The distinction the whole design exists to preserve. If these two ever read the same,
  /// a client author has no way to know that one of them means "we could not ask".
  @Test("Not knowing is documented differently from having expired")
  func unconfirmedIsNotExpired() {
    let byReason = Dictionary(uniqueKeysWithValues: OpenAPIDocument.refusalReasons)
    let unverifiable = byReason[LicenseRefusal.unverifiable.reason] ?? ""
    let expired = byReason[LicenseRefusal.expired(at: .now).reason] ?? ""

    #expect(unverifiable != expired)
    // Says what it is NOT, which is the part a client author skims past otherwise.
    #expect(unverifiable.localizedCaseInsensitiveContains("not the same"))
  }

  // MARK: - The emitted document

  /// The half that matters to a shipped client: a 402 appears on exactly the routes that can
  /// send one, and on none of the routes that cannot.
  ///
  /// The second clause is the load-bearing one. A 402 documented on a v1 path would tell
  /// every existing client author that the frozen surface can start refusing them, which is
  /// the opposite of the guarantee v1 carries — and a 402 actually reachable there would
  /// break clients that have been shipped for years.
  @Test("Every gated route documents a 402, and no v1 route does")
  func gatedRoutesDocumentPayment() throws {
    let document = try OpenAPIDocument.generate().serialized()
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any])
    let paths = try #require(json["paths"] as? [String: [String: Any]])

    var gated = 0
    for (path, operations) in paths {
      for (verb, raw) in operations {
        guard let operation = raw as? [String: Any],
          let responses = operation["responses"] as? [String: Any]
        else { continue }
        let documentsPayment = responses["402"] != nil
        let tier = operation["x-minimum-tier"] as? String
        let version = operation["x-api-version"] as? Int

        #expect(
          documentsPayment == (tier != nil),
          "\(verb.uppercased()) \(path): a 402 and `x-minimum-tier` must agree")
        if documentsPayment {
          gated += 1
          #expect(version != 1, "\(verb.uppercased()) \(path) is v1 and must never answer 402")
        }
      }
    }

    // A floor, so a walk that matched nothing cannot pass while enforcing nothing.
    #expect(gated > 20, "only \(gated) routes document a 402; the scan is not reading the tree")
  }

  /// `subscription_ended_at` is present only with `license_expired` — `PaymentRequired` sets
  /// it inside `if case .expired`. Documenting it as always-present would have clients render
  /// an epoch-zero date on every other refusal.
  @Test("Only the expired reason mentions the end date")
  func onlyExpiredCarriesTheDate() {
    for (reason, explanation) in OpenAPIDocument.refusalReasons {
      let mentions = explanation.contains("subscription_ended_at")
      #expect(
        mentions == (reason == "license_expired"),
        "\(reason) should \(reason == "license_expired" ? "" : "not ")name the end date")
    }
  }
}
