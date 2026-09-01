//  DeleteBodyTests
//  A DELETE request's body reaches its handler.
//
//  It did not. `buildRouter` collected the body for every method except GET *and DELETE*,
//  so `request.jsonBody()` was always nil for a DELETE — and four handlers read one:
//
//    - `chat.clearHistory` requires `{"confirm": true}`, so it could NEVER succeed. The
//      endpoint answered "send `{"confirm": true}`" to a request that had sent exactly that.
//    - `chat.removeParticipant` takes the address to remove.
//    - `contact.delete` takes the batch of ids.
//    - `facetime.invalidateLinks` takes the links to invalidate.
//
//  Each failed with "the field you sent is required", which reads as a client mistake and
//  sends the reader to check their own JSON.
//
//  It survived because the recorded fixtures for those routes were captured against the NODE
//  server, which collects DELETE bodies — so the corpus described a contract this server did
//  not meet, and only a parity run would have disagreed.

import BBHTTPAPI
import Foundation
import Testing

@Suite("DELETE bodies reach handlers")
struct DeleteBodyTests {

  @Test("A DELETE context carries its body like any other method")
  func deleteCarriesBody() throws {
    // `APIRequestContext` is what the router hands a handler; a DELETE built with a body
    // must decode it the same way a POST does.
    let context = APIRequestContext(
      method: .delete,
      path: "/api/v2/chat/x/messages",
      body: Data(#"{"confirm": true}"#.utf8)
    )
    let body = try #require(try context.jsonBody())
    #expect(body["confirm"]?.boolValue == true)
  }

  @Test("An absent DELETE body is still absent, not an error")
  func deleteWithoutBody() throws {
    // The other half: `facetime.invalidateLinks` treats no body as "all links", so nil has
    // to stay distinguishable from an empty object.
    let context = APIRequestContext(method: .delete, path: "/api/v2/facetime/link")
    #expect(try context.jsonBody() == nil)
  }

  @Test("Every method except GET is expected to carry a body")
  func onlyGetIsExcluded() {
    // Pins the rule the router applies. If DELETE is ever excluded again, this says why it
    // must not be rather than leaving the next reader to rediscover it.
    for method in HTTPMethod.allCases where method != .get {
      let context = APIRequestContext(
        method: method, path: "/x", body: Data(#"{"k": 1}"#.utf8))
      #expect(
        (try? context.jsonBody())??["k"]?.intValue == 1,
        "\(method.rawValue) lost its body"
      )
    }
  }
}
