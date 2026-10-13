//  EnrollmentErrorHTTPTests
//  What a token-auth failure looks like on the wire.
//
//  `EnrollmentError` had no HTTP mapping, so every case reached the renderer as an
//  unrecognised error and was answered with a 500 "An unhandled error has occurred!": a
//  refused enrolment code and a revoke naming a device nobody enrolled both read as the
//  server falling over. The auth routes are additive, so these pairings are ours; this pins
//  them, and that the renderer takes them rather than the fallback.

import BBAuth
import BBHTTPAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Enrollment error HTTP mapping")
struct EnrollmentErrorHTTPTests {

  @Test(
    "Each case maps to a status and error type",
    arguments: [
      (EnrollmentError.invalidEnrollmentCode, 401, ErrorType.authenticationError),
      (EnrollmentError.enrollmentCodeExpired, 401, ErrorType.authenticationError),
      (EnrollmentError.invalidClientCredentials, 401, ErrorType.authenticationError),
      (EnrollmentError.deviceRevoked, 401, ErrorType.authenticationError),
      (EnrollmentError.unknownDevice, 404, ErrorType.databaseError),
      (EnrollmentError.notEnabled, 503, ErrorType.serverError),
    ])
  func mapping(_ error: EnrollmentError, _ status: Int, _ type: ErrorType) {
    let (rendered, envelope) = ErrorRenderer.render(error, logger: .init(label: "test"))
    #expect(rendered == status)
    #expect(envelope.status == status)
    #expect(envelope.error?.type == type)
    // The case's own sentence as the detail, not the unhandled-error fallback's.
    #expect(envelope.error?.message == error.body)
    #expect(envelope.message != "An unhandled error has occurred!")
  }
}
