//  InterfaceErrorHTTPTests
//  The one place the domain vocabulary's HTTP spelling is asserted.
//
//  `InterfaceError` is thrown by a layer that does not import BBHTTPAPI, so the mapping onto
//  status codes lives in a single extension. That makes the pairings easy to change by
//  accident and easy to check on purpose — which is what this is for.
//
//  Every other suite in the interfaces layer now asserts the DOMAIN case
//  (`.messagesFailed(…)`, `.invalidRequest(…)`) rather than re-deriving a status. That is the
//  point of the refactor: a caller that is not HTTP — the SwiftUI app — should be able to
//  switch on what went wrong without an envelope in the way. The wire contract is asserted
//  once, here.
//
//  Two pairings look wrong and are the client contract: 404 reports "Database Error", and a
//  Messages failure is a 500 rather than a 4xx.

import BBHTTPAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Interface error HTTP mapping")
struct InterfaceErrorHTTPTests {

  @Test(
    "Each case maps to the status and error type clients expect",
    arguments: [
      (InterfaceError.invalidRequest("no"), 400, ErrorType.validationError),
      (InterfaceError.notFound("no"), 404, ErrorType.databaseError),
      (InterfaceError.unavailable("no"), 503, ErrorType.serverError),
      (InterfaceError.messagesFailed("no"), 500, ErrorType.iMessageError),
      (InterfaceError.helperUnavailable(feature: "reactions"), 500, ErrorType.iMessageError),
      (
        InterfaceError.capabilityUnavailable("no", feature: "groups"), 500,
        ErrorType.iMessageError
      ),
    ])
  func mapping(_ error: InterfaceError, _ status: Int, _ type: ErrorType) {
    #expect(error.status == status)
    #expect(error.errorType == type)
  }

  /// The renderer has to pick the `HTTPError` branch for these, not the `BBError` fallback —
  /// otherwise every one of them would come back as a 500 regardless of its case.
  @Test("The renderer uses the mapped status rather than the BBError fallback")
  func rendererUsesTheMapping() {
    let (status, envelope) = ErrorRenderer.render(
      InterfaceError.invalidRequest("`chatGuid` is required"),
      logger: .init(label: "test")
    )
    #expect(status == 400)
    #expect(envelope.status == 400)
    #expect(envelope.error?.type == .validationError)
    #expect(envelope.error?.message == "`chatGuid` is required")
  }

  /// The gate's two fields, the way the reference fills them.
  ///
  /// `PrivateApiMiddleware` throws `new IMessageError({ message: "Please make sure you have
  /// completed the setup…", error: ex.message })`. So the long sentence is the ENVELOPE's
  /// `message` and the detail is which half of `checkPrivateApiStatus` failed — this server
  /// had the two the wrong way round, and sent a `data.feature` the reference does not send.
  /// Found by replaying the recorded corpus; see `FixtureReplayTests`.
  @Test("A missing helper fills the envelope the way the reference's gate does")
  func helperUnavailableMatchesTheGate() {
    let error = InterfaceError.helperUnavailable(feature: "reactions")
    #expect(
      error.responseMessage
        == "Please make sure you have completed the setup for the Private API, "
        + "and your helper is connected!"
    )
    #expect(error.errorMessage == "iMessage Private API Helper is not connected!")
    // No data. An added key fails the parity diff exactly like a dropped one, and the
    // feature name is in the log, where it is more use anyway.
    #expect(error.data == nil)
    // The domain `body` is the readable one and is deliberately NOT what goes on the wire.
    #expect(error.body != error.errorMessage)
  }

  /// The case that exists because `helperUnavailable` cannot carry a bespoke sentence.
  ///
  /// Unlike `helperUnavailable`, this one keeps its `data.feature`: the reference has no
  /// Shortcut path, so it never produces this response and there is nothing to diverge from.
  @Test("A missing capability sends its own message and still names the feature")
  func capabilityUnavailableCarriesBoth() {
    let error = InterfaceError.capabilityUnavailable(
      "Creating a group chat needs the Shortcut.", feature: "creating a group chat")
    #expect(error.errorMessage == "Creating a group chat needs the Shortcut.")
    #expect(error.data?["feature"]?.stringValue == "creating a group chat")
  }

  /// Only the two cases that name a feature carry a payload. A `data` key appearing where the
  /// reference sends none fails the compatibility diff exactly like a missing one.
  @Test(
    "Cases with nothing to report carry no data key",
    arguments: [
      InterfaceError.invalidRequest("no"), .notFound("no"), .unavailable("no"),
      .messagesFailed("no"),
    ])
  func noSpuriousDataKey(_ error: InterfaceError) {
    #expect(error.data == nil)
  }

  /// It is a `BBError` as well, so it reaches the alert and logging path with its structure
  /// intact rather than as a rendered string.
  @Test("It carries its diagnostic identity alongside the HTTP one")
  func alsoCarriesDomainIdentity() {
    let error = InterfaceError.notFound("no message with GUID x")
    #expect(error.code == "interface.not_found")
    #expect(error.domain == "Interfaces")
    // Raised in response to a request somebody is waiting on, so the answer goes to them
    // rather than into the server's notification list.
    #expect(error.isUserFacing == false)
  }
}
