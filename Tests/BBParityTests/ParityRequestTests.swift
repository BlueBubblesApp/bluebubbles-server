//  ParityRequestTests
//  The one request builder the parity harness sends through.
//
//  Every driver (the fixture replay, the side-by-side runner, the replay suite's seeding)
//  turns its request into a `URLRequest` here, so what is pinned below is what every one of
//  them puts on the wire: the server's own password in place of the recorder's redaction,
//  the JSON content type only with a body, and a URL that will not build as a THROW.

import Foundation
import Testing

@testable import BBParity

@Suite("Parity request")
struct ParityRequestTests {

  private func fixture(
    _ method: String, _ path: String, body: RecordedFixture.Body = .empty
  ) -> RecordedFixture {
    RecordedFixture(
      name: "fixture.json",
      request: .init(method: method, path: path, headers: [:], body: body),
      response: .init(status: 200, headers: [:], body: .empty)
    )
  }

  private func items(_ request: URLRequest) -> [URLQueryItem] {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
      .queryItems ?? []
  }

  @Test("A recorded request carries the server's password, never the redaction")
  func passwordReplacesRedaction() throws {
    let request = try ParityRequest(
      fixture("GET", "/api/v1/chat/count?password=__REDACTED__&limit=5")
    ).urlRequest(baseURL: "http://127.0.0.1:1234/", password: "pw")

    #expect(request.url?.path == "/api/v1/chat/count")
    #expect(request.httpMethod == "GET")
    #expect(
      items(request) == [
        URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "password", value: "pw"),
      ])
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
  }

  @Test("A JSON body is sent with the JSON content type")
  func jsonBody() throws {
    let request = try ParityRequest(
      fixture("POST", "/api/v1/message/query", body: .json(#"{"limit":1}"#))
    ).urlRequest(baseURL: "http://127.0.0.1:1234", password: "pw")

    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == Data(#"{"limit":1}"#.utf8))
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  }

  @Test("A corpus entry's query is sent sorted, whatever order the dictionary holds")
  func corpusQueryIsSorted() throws {
    let entry = CorpusRequest(
      id: "x", path: "/api/v1/chat/x/message", query: ["offset": "0", "limit": "5"])
    let request = try ParityRequest(entry).urlRequest(baseURL: "http://h", password: "pw")
    #expect(items(request).map(\.name) == ["limit", "offset", "password"])
  }

  @Test("A URL that will not build throws rather than being skipped")
  func badURLThrows() {
    #expect(throws: ParityRequestError.self) {
      try ParityRequest(method: "GET", path: "/api/v1/ping")
        .urlRequest(baseURL: "http://[not a host", password: "pw")
    }
  }
}
