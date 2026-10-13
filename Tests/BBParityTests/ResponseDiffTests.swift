//  ResponseDiffTests
//
//  The comparison reports BOTH directions, and these pin that. A missing field is the
//  compatibility break; an added one is reported as a drift check, so a field that replaced
//  another cannot pass as an addition.

import Foundation
import Testing

@testable import BBParity

@Suite("ResponseDiff")
struct ResponseDiffTests {

  @Test("identical objects have no differences")
  func identical() {
    let object: [String: Any] = [
      "status": 200, "message": "Success",
      "data": ["guid": "A", "count": 3] as [String: Any],
    ]
    #expect(ResponseDiff.compare(expected: object, actual: object).isEmpty)
  }

  @Test("a missing key is reported")
  func missing() {
    let differences = ResponseDiff.compare(
      expected: ["status": 200, "data": "pong"], actual: ["status": 200]
    )
    #expect(differences.count == 1)
    #expect(differences.first?.kind == .missingKey)
    #expect(differences.first?.path == "data")
  }

  /// The direction a one-way diff misses.
  @Test("an added key is reported")
  func added() {
    let differences = ResponseDiff.compare(
      expected: ["status": 200], actual: ["status": 200, "title": "Extra"]
    )
    #expect(differences.count == 1)
    #expect(differences.first?.kind == .unexpectedKey)
    #expect(differences.first?.path == "title")
  }

  /// `data` and `metadata` are omitted when absent, never null. A strict parser treats the
  /// two differently, so the diff must too.
  @Test("explicit null is not the same as absent")
  func nullVersusAbsent() {
    #expect(
      !ResponseDiff.compare(
        expected: ["status": 200], actual: ["status": 200, "data": NSNull()]
      ).isEmpty)
    #expect(
      !ResponseDiff.compare(
        expected: ["status": 200, "data": NSNull()], actual: ["status": 200]
      ).isEmpty)
  }

  @Test("nested objects are compared")
  func nested() {
    let differences = ResponseDiff.compare(
      expected: ["data": ["handle": ["address": "a@example.com"]]],
      actual: ["data": ["handle": ["address": "b@example.com"]]]
    )
    #expect(differences.first?.path == "data.handle.address")
    #expect(differences.first?.kind == .valueDiffers)
  }

  @Test("array length and element differences are reported")
  func arrays() {
    let lengths = ResponseDiff.compare(
      expected: ["data": [1, 2, 3]], actual: ["data": [1, 2]]
    )
    #expect(lengths.first?.kind == .arrayLength)

    let elements = ResponseDiff.compare(
      expected: ["data": [["guid": "A"]]], actual: ["data": [["guid": "B"]]]
    )
    #expect(elements.first?.path == "data[0].guid")

    let scalars = ResponseDiff.compare(
      expected: ["data": ["x", "y"]], actual: ["data": ["x", "z"]]
    )
    #expect(scalars.first?.path == "data[1]")
  }

  // MARK: - Volatile fields

  @Test("a volatile field's value may differ")
  func volatileValues() {
    #expect(
      ResponseDiff.compare(
        expected: ["guid": "A", "dateCreated": 1_700_000_000_000],
        actual: ["guid": "A", "dateCreated": 1_800_000_000_000]
      ).isEmpty)
  }

  /// Only the VALUE is allowed to move. A timestamp that became a string, or null, is a
  /// real break, and being on the volatile list must not hide it.
  @Test("a volatile field's type may not differ")
  func volatileTypes() {
    let stringified = ResponseDiff.compare(
      expected: ["dateCreated": 1_700_000_000_000], actual: ["dateCreated": "2023-11-14"]
    )
    #expect(stringified.first?.kind == .typeDiffers)

    let nulled = ResponseDiff.compare(
      expected: ["dateCreated": 1_700_000_000_000], actual: ["dateCreated": NSNull()]
    )
    #expect(nulled.first?.kind == .typeDiffers)
  }

  /// `NSNumber` erases Bool, so `true` and `1` are the same Foundation type. Treating them
  /// as equal would hide a break that fails a client parsing a boolean.
  @Test("true is not 1")
  func boolIsNotNumber() {
    let differences = ResponseDiff.compare(
      expected: ["available": true], actual: ["available": 1]
    )
    #expect(differences.first?.kind == .typeDiffers)
    #expect(differences.first?.detail == "bool vs number")
  }

  @Test("a number is not its string form")
  func numberIsNotString() {
    let differences = ResponseDiff.compare(
      expected: ["total": 42], actual: ["total": "42"]
    )
    #expect(differences.first?.kind == .typeDiffers)
  }

  @Test("type differences are reported as type, not value")
  func typeBeforeValue() {
    let differences = ResponseDiff.compare(
      expected: ["data": ["a": 1]], actual: ["data": [1]]
    )
    #expect(differences.first?.kind == .typeDiffers)
    #expect(differences.first?.detail == "object vs array")
  }
}

@Suite("Corpus")
struct CorpusTests {

  /// Nothing in the corpus may write. It runs against a real Mac with real conversations,
  /// and a corpus that sent anything would send it TWICE (once per server) to a real
  /// person.
  @Test("the corpus is read-only")
  func readOnly() {
    let writeVerbs = ["/new", "/send", "/react", "/edit", "/unsend", "/delete", "/typing"]
    for request in Corpus.readOnly {
      #expect(
        request.method == .get || request.path.hasSuffix("/query")
          || request.path.hasSuffix("/message"),
        "\(request.id) is a POST to something other than a query endpoint")
      for verb in writeVerbs {
        #expect(!request.path.contains(verb), "\(request.id) touches \(verb)")
      }
    }
  }

  @Test("requests needing a chat GUID are dropped when none is given")
  func withoutGUID() {
    let resolved = Corpus.resolved(chatGUID: nil)
    #expect(resolved.allSatisfy { !$0.needsChatGUID })
    #expect(resolved.count < Corpus.readOnly.count)
    #expect(!resolved.contains { $0.path.contains("{chatGuid}") })
  }

  /// A chat GUID is `iMessage;-;+15555550101`. Left raw in a path, the semicolons and plus
  /// are URL syntax to one server and data to the other, a "difference" that is entirely
  /// the harness's fault.
  @Test("a chat GUID is percent-encoded into the path")
  func encoding() {
    let resolved = Corpus.resolved(chatGUID: "iMessage;-;+15555550101")
    let find = resolved.first { $0.id == "chat.find" }
    let path = try! #require(find?.path)
    #expect(!path.contains(";"))
    #expect(!path.contains("+"))
    #expect(path.contains("iMessage"))

    // A query VALUE is not pre-encoded; URLComponents does that, and doing it twice
    // would send a literal `%3B`.
    let scoped = resolved.first { $0.id == "message.count.scoped" }
    #expect(scoped?.query["chatGuid"] == "iMessage;-;+15555550101")
  }

  @Test("every request has a unique id")
  func uniqueIDs() {
    let ids = Corpus.readOnly.map(\.id)
    #expect(Set(ids).count == ids.count)
  }
}

@Suite("Comparison reporting")
struct ReportingTests {

  private func result(
    _ id: String, differences: [BBParity.Difference] = [], status: (Int, Int) = (200, 200)
  ) -> BBParity.ComparisonResult {
    BBParity.ComparisonResult(
      id: id, referenceStatus: status.0, candidateStatus: status.1,
      differences: differences, error: nil
    )
  }

  @Test("a status mismatch is not a match")
  func statusMismatch() {
    #expect(!result("x", status: (200, 500)).isMatch)
    #expect(result("x", status: (200, 200)).isMatch)
  }

  @Test("the report counts matches")
  func counting() {
    let results = [
      result("a"),
      result("b", differences: [BBParity.Difference(kind: .missingKey, path: "data", detail: "")]),
    ]
    let text = results.report()
    #expect(text.contains("1/2 endpoints match."))
    #expect(text.contains("✗ b"))
    #expect(!results.allMatch)
  }

  /// Hiding the matching lines must not change the count. Filtering the array before
  /// reporting produced "0/1 endpoints match" for a run where eighteen of nineteen
  /// matched, which reads as total failure and is the opposite of what happened.
  @Test("hiding matches does not change the summary")
  func summaryCountsEverything() {
    let results = [
      result("a"), result("b"),
      result("c", differences: [BBParity.Difference(kind: .missingKey, path: "d", detail: "")]),
    ]
    let quiet = results.report(showingMatches: false)
    #expect(quiet.contains("2/3 endpoints match."))
    #expect(quiet.contains("✗ c"))
    #expect(!quiet.contains("✓ a"))

    #expect(results.report(showingMatches: true).contains("✓ a"))
  }

  @Test("a failed request is reported rather than counted as a match")
  func failedRequest() {
    let failed = BBParity.ComparisonResult(
      id: "a", referenceStatus: 0, candidateStatus: 0,
      differences: [], error: "connection refused"
    )
    #expect(!failed.isMatch)
    #expect([failed].report().contains("connection refused"))
  }
}

/// The scope of an accepted difference.
///
/// These entries were keyed by bare field name, so `install`, declared for one object on
/// `GET /server/update/check`, also accepted an `install` key on a message, a chat, a handle
/// and every other object in the API. An exception written for one route was a hole across
/// the whole surface, and nothing about the entry said so.
@Suite("Accepted differences are scoped to where they were declared")
struct AcceptedDifferenceScopeTests {

  private let accepted = [
    "data.install": "declared for the update check only",
    "**.scheduleType": "carried by the message serialiser, so it is everywhere",
  ]

  @Test("A path-scoped entry accepts its own path and refuses the same name elsewhere")
  func pathScopedEntry() {
    let reference: [String: Any] = ["data": ["version": "1.0"]]
    let ours: [String: Any] = ["data": ["version": "1.0", "install": "downloading"]]
    #expect(
      ResponseDiff.compare(expected: reference, actual: ours, accepting: accepted).isEmpty)

    // The same field name on a different object is NOT what was declared.
    let elsewhere: [String: Any] = ["message": ["guid": "m1", "install": "downloading"]]
    let differences = ResponseDiff.compare(
      expected: ["message": ["guid": "m1"]], actual: elsewhere, accepting: accepted)
    #expect(
      differences.map(\.path) == ["message.install"],
      "an exception declared for data.install must not cover message.install")
  }

  @Test("A `**.` entry accepts the field wherever the serialiser puts it")
  func wildcardEntry() {
    let reference: [String: Any] = ["data": ["messages": [["guid": "m1"], ["guid": "m2"]]]]
    let ours: [String: Any] = [
      "data": ["messages": [["guid": "m1", "scheduleType": "send-later"], ["guid": "m2"]]]
    ]
    #expect(
      ResponseDiff.compare(expected: reference, actual: ours, accepting: accepted).isEmpty,
      "a field declared `**.` is accepted at any depth, including inside an array")
  }

  @Test("An array index is erased before matching, so one entry covers every element")
  func indicesAreErased() {
    #expect(ResponseDiff.normalise("data.messages[3].guid") == "data.messages.guid")
    #expect(ResponseDiff.normalise("data[0].handles[11].address") == "data.handles.address")
    #expect(ResponseDiff.normalise("data.install") == "data.install")
  }

  @Test("Every shipped entry is either a real path or an explicit `**.`")
  func shippedEntriesDeclareTheirScope() {
    for key in acceptedDifferences.keys {
      #expect(
        key.contains("."),
        Comment(
          rawValue: """
            `\(key)` is a bare field name, so it accepts that field on every object in \
            every response. Scope it to its path, or write it `**.\(key)` to say it is \
            deliberately everywhere.
            """))
    }
  }

  // MARK: - The envelope's wording

  /// v1 is frozen in its structure, not its prose. A reworded or more specific sentence is
  /// the same response to a client, in both modes.
  @Test(
    "a reworded message or error message is not a difference",
    arguments: [DiffMode.strict, .shape])
  func rewordedMessages(_ mode: DiffMode) {
    let reference: [String: Any] = [
      "status": 404, "message": "The requested resource was not found",
      "error": ["type": "Database Error", "message": "Chat does not exist!"] as [String: Any],
    ]
    let ours: [String: Any] = [
      "status": 404, "message": "No chat matches that GUID",
      "error": [
        "type": "Database Error", "message": "No chat matches any;-;someone@example.com",
      ] as [String: Any],
    ]
    #expect(ResponseDiff.compare(expected: reference, actual: ours, mode: mode).isEmpty)
  }

  /// Free in its words, not in its presence or its type.
  @Test(
    "a message that is missing, null or not a string is still a difference",
    arguments: [DiffMode.strict, .shape])
  func messageMustBeAString(_ mode: DiffMode) {
    let reference: [String: Any] = ["status": 200, "message": "Success"]
    for replacement in [NSNull(), 1 as Any] {
      let differences = ResponseDiff.compare(
        expected: reference, actual: ["status": 200, "message": replacement], mode: mode)
      #expect(differences.map(\.kind) == [.typeDiffers], "\(replacement)")
    }
    let missing = ResponseDiff.compare(
      expected: reference, actual: ["status": 200], mode: mode)
    #expect(missing.map(\.kind) == [.missingKey])
  }

  /// The words are free; the status and the error type are what a client branches on.
  @Test("a status or error type that moves is still a difference in shape mode")
  func statusAndTypeStayLiteral() {
    let reference: [String: Any] = [
      "status": 400, "message": "x",
      "error": ["type": "Validation Error", "message": "y"] as [String: Any],
    ]
    let ours: [String: Any] = [
      "status": 404, "message": "x",
      "error": ["type": "Database Error", "message": "y"] as [String: Any],
    ]
    let paths = ResponseDiff.compare(expected: reference, actual: ours, mode: .shape)
      .map(\.path)
    #expect(Set(paths) == ["status", "error.type"])
  }

  /// The relaxation is for the ENVELOPE. A field called `message` inside `data` is content:
  /// a scheduled message's text, compared literally under `.strict` as every value is.
  @Test("a content field named message is compared as content")
  func contentMessageIsContent() {
    let differences = ResponseDiff.compare(
      expected: ["status": 200, "message": "Success", "data": ["message": "BB test"]],
      actual: ["status": 200, "message": "Success", "data": ["message": "BB other"]],
      mode: .strict)
    #expect(differences.map(\.path) == ["data.message"])
    #expect(differences.first?.kind == .valueDiffers)
  }
}
