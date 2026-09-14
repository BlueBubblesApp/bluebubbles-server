//  QueryValidationTests
//  The query parameters that are validated rather than coerced, and why each one is.
//
//  The lenient accessors are the v1 compatibility contract and are tested elsewhere. These
//  cover the opposite case: parameters where the reference DOES validate, so rejecting
//  matches what a client has always been told, and where accepting anything reaches
//  arithmetic that traps.
//
//  `?quality=inf` is the one that mattered. It parsed as a `Double`, passed the resize
//  guard, reached `Int(inf * 100)` and trapped the process, so any authenticated client
//  could stop the server with one URL.

import BBHTTPAPI
import BBInterfaces
import Foundation
import Testing

@testable import BBHandlers

@Suite("Query parameter validation")
struct QueryValidationTests {

  private func request(_ query: [String: String]) -> APIRequestContext {
    APIRequestContext(
      method: .get,
      path: "/api/v1/attachment/x/download",
      queryParameters: query
    )
  }

  // MARK: - quality

  @Test(
    "Every quality the reference accepts is accepted here",
    arguments: AttachmentConversion.Options.Quality.allCases
  )
  func acceptsReferenceQualities(quality: AttachmentConversion.Options.Quality) throws {
    let parsed = try request(["quality": quality.rawValue])
      .enumeration(
        "quality",
        as: AttachmentConversion.Options.Quality.self,
        rejection: AttachmentConversion.Options.Quality.rejectionMessage
      )
    #expect(parsed == quality)
  }

  @Test(
    "A quality the reference rejects is a 400 here, not a crash and not silence",
    arguments: ["inf", "-inf", "nan", "1e20", "0.5", "1", "-1", "GOOD", "excellent"]
  )
  func rejectsEverythingElse(raw: String) {
    // `0.5` and `1` are in this list deliberately. Parsing quality as a number is what the
    // old code did, and a client sending one got a converted image at a quality nobody
    // asked for; the reference answers 400. `inf` and `nan` are the trap: they parse as
    // `Double` and survive every numeric guard short of `isFinite`.
    #expect(throws: BadRequest.self) {
      try request(["quality": raw]).enumeration(
        "quality",
        as: AttachmentConversion.Options.Quality.self,
        rejection: AttachmentConversion.Options.Quality.rejectionMessage
      )
    }
  }

  @Test("An absent quality is absent, not an error")
  func absentQualityIsNotAnError() throws {
    // None of the reference's `in:` rules are also `required`, so omitting one is the
    // route's default. Turning that into a 400 would break every client that never sends it.
    let parsed = try request([:]).enumeration(
      "quality",
      as: AttachmentConversion.Options.Quality.self,
      rejection: AttachmentConversion.Options.Quality.rejectionMessage
    )
    #expect(parsed == nil)
  }

  @Test("The rejection names all three spellings, as the reference's does")
  func rejectionWording() {
    // The reference builds this string from the same list it validates against
    // (`attachmentRouter.ts:86-89`), so a client surfacing it to a user sees the spellings
    // it can actually use.
    #expect(
      AttachmentConversion.Options.Quality.rejectionMessage
        == "Invalid quality specified! Must be one of: good, better, best"
    )
  }

  // MARK: - width and height

  @Test("A dimension of at least one is accepted", arguments: ["1", "100", "4032"])
  func acceptsPositiveDimensions(raw: String) throws {
    #expect(try request(["width": raw]).positiveInteger("width") == Int(raw))
  }

  @Test("A dimension below one is a 400", arguments: ["0", "-1", "-4032"])
  func rejectsNonPositiveDimensions(raw: String) {
    // `numeric|min:1` in `AttachmentValidator.downloadRules`. Zero and negatives reach
    // `CGImageSourceCreateThumbnailAtIndex` as a maximum pixel size, where they mean
    // something nobody intended.
    #expect(throws: BadRequest.self) {
      try request(["width": raw]).positiveInteger("width")
    }
  }

  @Test("A dimension that is not a number is a 400", arguments: ["wide", "1.5", "1e3", "∞"])
  func rejectsNonNumericDimensions(raw: String) {
    #expect(throws: BadRequest.self) {
      try request(["height": raw]).positiveInteger("height")
    }
  }

  @Test("An absent dimension is absent")
  func absentDimension() throws {
    #expect(try request([:]).positiveInteger("width") == nil)
  }

  // MARK: - the lenient accessor it sits beside

  @Test(
    "The lenient decimal accessor drops non-finite values",
    arguments: ["inf", "-inf", "nan", "NaN", "infinity"]
  )
  func decimalRejectsNonFinite(raw: String) {
    // Lenient means "fall back to the route's default", not "accept a value that traps".
    // Every one of these is accepted by `Double.init`.
    #expect(request(["scale": raw]).decimal("scale") == nil)
  }

  @Test("The lenient decimal accessor still accepts ordinary numbers")
  func decimalAcceptsFinite() {
    #expect(request(["scale": "0.5"]).decimal("scale") == 0.5)
    #expect(request(["scale": "-2"]).decimal("scale") == -2)
  }
}
