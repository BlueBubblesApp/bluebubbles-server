//  MalformedBodyTests
//  An absent body and a body that is not JSON are different answers.
//
//  `jsonBody()` returns nil for the first and throws for the second, and every handler's
//  `values()` leans on that split: the nil becomes an empty object so an optional body stays
//  optional, and the throw fails the request. A handler that wrapped the call in `try?`
//  merged the two; see `RequestBodyPolicyTests` in the handler tests for the scan that now
//  refuses it. This pins the split itself.

import BBHTTPAPI
import Foundation
import Testing

@Suite("Absent and malformed bodies are told apart")
struct MalformedBodyTests {

  @Test("An absent or empty body decodes to nil")
  func absentIsNil() throws {
    let none = APIRequestContext(method: .post, path: "/api/v1/facetime/link")
    #expect(try none.jsonBody() == nil)

    let empty = APIRequestContext(method: .post, path: "/api/v1/facetime/link", body: Data())
    #expect(try empty.jsonBody() == nil)
  }

  @Test("A body that is not JSON throws rather than reading as absent")
  func malformedThrows() {
    let context = APIRequestContext(
      method: .post,
      path: "/api/v1/facetime/link",
      body: Data(#"{"addresses": ["+1"#.utf8)
    )
    #expect(throws: (any Error).self) { try context.jsonBody() }
  }
}
