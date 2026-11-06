//  CacheValidationTests
//  When a repeat request is a 304, and what every cached answer carries.
//
//  The failure that matters in each direction: a 304 for a tag the client does not hold
//  leaves it drawing nothing, with no error to show, and a tag that never matches costs a
//  full download on every sync. And a cached answer without `private` is one a shared cache
//  in front of a tunnel may keep for the next person.

import Foundation
import HTTPTypes
import Testing

@testable import BBHTTPAPI

@Suite("Cache validation")
struct CacheValidationTests {

  @Test("Tags are weak and quoted, and lose what cannot sit inside the quotes")
  func tagsAreWeak() {
    #expect(CacheValidation.revalidated("abc-1").entityTag == "W/\"abc-1\"")
    #expect(CacheValidation.immutable("a\"b\\c d").entityTag == "W/\"abcd\"")
  }

  @Test("Both directives are private")
  func directivesArePrivate() {
    #expect(CacheValidation.revalidated("x").cacheControl == "private, no-cache")
    #expect(
      CacheValidation.immutable("x").cacheControl == "private, max-age=31536000, immutable")
  }

  @Test("If-None-Match matches by weak comparison, in a list, or as a wildcard")
  func ifNoneMatch() {
    let validation = CacheValidation.revalidated("rev-0-100")
    for header in [
      "W/\"rev-0-100\"", "\"rev-0-100\"", "\"other\", W/\"rev-0-100\"", " W/\"rev-0-100\" ",
      "*",
    ] {
      #expect(validation.isSatisfied(byIfNoneMatch: header), "should match: \(header)")
    }
  }

  @Test("A tag the client does not hold is never a 304")
  func mismatchIsAFullAnswer() {
    let validation = CacheValidation.revalidated("rev-0-100")
    for header in [nil, "", "W/\"rev-0-50\"", "\"rev\"", "W/\"rev-0-100x\""] {
      #expect(
        !validation.isSatisfied(byIfNoneMatch: header), "should not match: \(header ?? "nil")")
    }
  }

  @Test("A cached answer keeps its body and gains the three headers")
  func cachedCarriesHeaders() throws {
    let validation = CacheValidation.immutable("tag")
    let response = try HTTPAPIBuilder.response(
      for: .cached(.bytes(Data([1, 2, 3]), contentType: "image/png"), validation), pretty: false)
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "image/png")
    #expect(response.headers[.eTag] == "W/\"tag\"")
    #expect(response.headers[.cacheControl] == validation.cacheControl)
    #expect(response.headers[.xContentTypeOptions] == "nosniff")
  }

  @Test("A JSON answer that is cached is still the envelope")
  func cachedJSONIsTheEnvelope() throws {
    let response = try HTTPAPIBuilder.response(
      for: .cached(.data(.object([:])), .revalidated("rev")), pretty: false)
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "application/json")
    #expect(response.headers[.eTag] == "W/\"rev\"")
  }

  @Test("Not modified is a 304 with the validators and no body")
  func notModified() throws {
    let validation = CacheValidation.revalidated("rev")
    let response = try HTTPAPIBuilder.response(for: .notModified(validation), pretty: false)
    #expect(response.status == .notModified)
    #expect(response.headers[.eTag] == "W/\"rev\"")
    #expect(response.headers[.cacheControl] == "private, no-cache")
    #expect(response.headers[.contentType] == nil)
  }
}
