//  RequestValuesTests
//  That reading a request stayed lenient while its refusals became consistent.
//
//  The leniency is the part worth guarding. `RequestValues` exists instead of a `Codable`
//  struct per request precisely because `Codable` is strict about types and this is a v1
//  surface shipped clients have been talking to for years: a client sending a number as a
//  string has always worked, and making it stop working is not a fix. These tests are what
//  stops someone "tidying" the accessors into strictness later.
//
//  The other half is the required-field message. Eighteen of twenty-four hand-written guards
//  already said "`key` is required"; the rest said something slightly different. Standardising
//  on the majority spelling means the wire is unchanged for almost every route, and the three
//  that genuinely need more context pass their own message.

import BBCore
import BBHTTPAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Request values")
struct RequestValuesTests {

  private func values(_ object: [String: JSONValue]) -> RequestValues {
    RequestValues(.object(object))
  }

  // MARK: - Leniency

  /// A wrong-typed field reads as absent, so the route's default applies. Under `Codable`
  /// this would throw and a request that has worked for years would start failing.
  @Test("A field of the wrong type reads as absent rather than failing")
  func wrongTypeIsAbsentNotAnError() {
    let body = values(["limit": .string("100"), "flag": .string("true")])
    #expect(body.int("limit") == nil)
    #expect(body.bool("flag") == nil)
    // Which is what lets the call site fall back.
    #expect((body.int("limit") ?? 25) == 25)
  }

  /// The one place a string IS read as a number: a multipart form, which has no other way
  /// to carry one. Opt-in on the values, not a property of the key, so a JSON client's
  /// quoted number still falls back exactly as above.
  @Test("A form's string fields coerce to numbers and booleans when asked")
  func formStringsCoerce() {
    let form = RequestValues(
      .object(["limit": .string("100"), "flag": .string("true"), "x": .string("0.25")]),
      coercingStrings: true
    )
    #expect(form.int("limit") == 100)
    #expect(form.bool("flag") == true)
    #expect(form.double("x") == 0.25)
    #expect(form.bool("nope") == nil)
  }

  /// `truthy` is `isTruthyBool` for a body field: a string counts even in JSON, because the
  /// reference coerces those fields whatever carried them. Everything it cannot read is false.
  @Test("A truthy field reads a JSON true or a true string, and nothing else")
  func truthyFields() {
    let body = values([
      "bool": .bool(true), "one": .string("1"), "word": .string("True"),
      "off": .bool(false), "zero": .string("0"), "number": .int(1), "junk": .string("maybe"),
    ])
    #expect(body.truthy("bool"))
    #expect(body.truthy("one"))
    #expect(body.truthy("word"))
    #expect(!body.truthy("off"))
    #expect(!body.truthy("zero"))
    // `isTruthyBool` compares with `includes`, so the number 1 is not true there either.
    #expect(!body.truthy("number"))
    #expect(!body.truthy("junk"))
    #expect(!body.truthy("absent"))
  }

  // MARK: - A list is applied or refused

  /// `DELETE /facetime/link` reads nil as "invalidate every link". A client sending one URL
  /// as a bare string was read as nil, and every link it had handed out stopped working.
  @Test("A list sent as a bare string is refused, not read as absent")
  func stringWhereAListBelongsIsRefused() {
    let body = values(["urls": .string("https://facetime.apple.com/join#v=1&p=example")])
    #expect(throws: BadRequest.self) { try body.strings("urls") }
  }

  @Test("A list with an element of another type is refused, not shortened")
  func mistypedElementIsRefused() {
    let body = values(["options": .array([.string("a"), .int(2), .string("b")])])
    #expect(throws: BadRequest.self) { try body.strings("options") }
  }

  @Test("An absent or null list is nil, and a list of strings is itself")
  func listReads() throws {
    #expect(try values([:]).strings("urls") == nil)
    #expect(try values(["urls": .null]).strings("urls") == nil)
    #expect(try values(["urls": .array([])]).strings("urls") == [])
    #expect(
      try values(["urls": .array([.string("a"), .string("b")])]).strings("urls") == ["a", "b"])
  }

  @Test("A missing field is simply nil")
  func missingIsNil() {
    let body = values([:])
    #expect(body.string("anything") == nil)
    #expect(body.int("anything") == nil)
    #expect(body.array("anything") == nil)
  }

  // MARK: - Aliases

  /// Two spellings reach the same field because the reference accepts both and both are in
  /// the wild. Dropping either would break whichever clients use it.
  @Test("An aliased field is read under either spelling")
  func aliasesResolve() {
    #expect(values(["filePath": .string("/a")]).string("filePath", or: "path") == "/a")
    #expect(values(["path": .string("/b")]).string("filePath", or: "path") == "/b")
    // The primary key wins when both are present.
    #expect(
      values(["filePath": .string("/a"), "path": .string("/b")])
        .string("filePath", or: "path") == "/a")
  }

  // MARK: - Required fields

  /// validatorjs's sentence, which is what the reference sends for a `required` rule.
  ///
  /// This asserted "`chatGuid` is required", a wording this server invented. The recorded
  /// corpus shows the reference answering "The after field is required." for the one
  /// required-field refusal it captured, and every `required` rule in `validators/*.ts`
  /// generates that same format.
  @Test("A required field that is absent gives the reference's sentence")
  func requiredMissingUsesStandardMessage() throws {
    do {
      _ = try values([:]).requireString("chatGuid")
      Issue.record("should have thrown")
    } catch let error as BadRequest {
      #expect(error.errorMessage == "The chatGuid field is required.")
      #expect(error.status == 400)
      // And the ENVELOPE carries the reference's sentence, not the short "Bad Request".
      #expect(
        error.responseMessage
          == "You've made a bad request! Please check your request params & body")
    }
  }

  /// Empty counts as missing for a required string. An empty GUID reaches the database as a
  /// lookup that cannot match rather than as a request anybody meant to send.
  @Test("A required string that is present but empty is still refused")
  func emptyCountsAsMissing() {
    #expect(throws: BadRequest.self) {
      try values(["chatGuid": .string("")]).requireString("chatGuid")
    }
  }

  /// Zero is a legitimate integer, and the required-int check must not treat it as absent;
  /// the filter-category route sends it.
  @Test("A required integer accepts zero")
  func zeroIsAValidInteger() throws {
    #expect(try values(["category": .int(0)]).requireInt("category") == 0)
  }

  /// An empty array is a legitimate value too, distinct from the key being absent.
  @Test("A required array accepts an empty one but not a missing one")
  func emptyArrayIsPresent() throws {
    #expect(try values(["parts": .array([])]).requireArray("parts").isEmpty)
    #expect(throws: BadRequest.self) { try values([:]).requireArray("parts") }
  }

  /// The three fields whose refusal needs more context than the key name.
  @Test("A custom message overrides the standard sentence")
  func customMessageWins() {
    do {
      _ = try values([:]).requireString(
        "chatGuid", message: "`chatGuid` is required on the final chunk")
      Issue.record("should have thrown")
    } catch let error as BadRequest {
      #expect(error.errorMessage == "`chatGuid` is required on the final chunk")
    } catch {
      Issue.record("threw \(type(of: error))")
    }
  }

  // MARK: - Pass-through

  /// Routes that hand the whole document onward (a contact to create, a backup to store)
  /// need it unchanged.
  @Test("The raw document is available unchanged")
  func rawIsUnchanged() {
    let object: [String: JSONValue] = ["a": .int(1), "b": .string("two")]
    #expect(values(object).raw == .object(object))
  }

  /// Path parameters arrive percent-encoded, and the optional accessor decodes them exactly
  /// as the required one does. koa-router decodes every param (`lib/layer.js:75`,
  /// `safeDecodeURIComponent`), so a contact id with a `:` reached the reference decoded.
  @Test("An optional path parameter is percent-decoded like a required one")
  func optionalPathParameterDecodes() throws {
    let request = APIRequestContext(
      method: .put, path: "/api/v1/contact/ABC%3AABPerson",
      pathParameters: ["id": "ABC%3AABPerson", "empty": ""])
    #expect(request.pathParameter("id") == "ABC:ABPerson")
    #expect(try request.requirePathParameter("id") == "ABC:ABPerson")
    #expect(request.pathParameter("empty") == nil)
    #expect(request.pathParameter("absent") == nil)
  }

  /// `?with=` goes through the one relations parser, trimmed and lowercased.
  @Test("The with query parameter is read by the shared relations parser")
  func withQueryParameter() {
    let request = APIRequestContext(
      method: .get, path: "/", queryParameters: ["with": " Chat , message.attributedBody"])
    #expect(request.relations().names == ["chat", "message.attributedbody"])
    #expect(request.relations().attributedBody)
    #expect(request.wants("chat"))
    #expect(!APIRequestContext(method: .get, path: "/").wants("chat"))
  }
}
