//  SplitModuleWireShapeTests
//  Splitting a module must not change a single byte a client sees.
//
//  `BBMedia` and `BBAppStore` were carved out of `BBInterfaces`, and both carried code that
//  threw `InterfaceError`. They cannot any more — the domain layer depends on them, so naming
//  its error type would be a cycle — so each got its own vocabulary: `UploadError` and
//  `StoreError`.
//
//  That is a refactor, and rule 1 says a refactor is not a reason for a client to see anything
//  different. The translations in `UploadError+HTTP` and `StoreError+HTTP` were transcribed
//  from `InterfaceError+HTTP` rather than decided again, and this asserts the transcription
//  against the original rather than against itself: every case is compared to the
//  `InterfaceError` case it replaced, so a divergence in status, error type or envelope
//  sentence fails here rather than in somebody's client.
//
//  It also pins the pairing that looks wrong and is the contract: 404 reports "Database
//  Error", not "Not Found".

import BBAppStore
import BBHTTPAPI
import BBInterfaces
import BBMedia
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Split-module wire shape")
struct SplitModuleWireShapeTests {

  /// Everything a client can observe about an error response.
  private struct Shape: Equatable, CustomStringConvertible {
    let status: Int
    let errorType: ErrorType
    let responseMessage: String
    let errorMessage: String

    init(_ error: any HTTPError) {
      status = error.status
      errorType = error.errorType
      responseMessage = error.responseMessage
      errorMessage = error.errorMessage
    }

    var description: String {
      "\(status) \(errorType) message=\(responseMessage) error=\(errorMessage)"
    }
  }

  @Test("An upload refusal is the 400 it was as an InterfaceError")
  func uploadRefusalIsUnchanged() {
    let sentence = "`filePath` must name a file returned by /api/v1/attachment/upload"
    #expect(
      Shape(UploadError.pathNotPermitted)
        == Shape(InterfaceError.invalidRequest(sentence)))
  }

  @Test("An out-of-order chunk is the 400 it was as an InterfaceError")
  func chunkRefusalIsUnchanged() {
    let error = UploadError.chunkOutOfOrder(index: 1, transferID: "t2")
    #expect(Shape(error) == Shape(InterfaceError.invalidRequest(error.body)))
    // The sentence itself, because it is what a client shows a person.
    #expect(error.body == "chunk 1 arrived before chunk 0 for transfer t2")
  }

  /// The one case with no `InterfaceError` predecessor: the chunked route had no size bound
  /// at all, so there is nothing to transcribe and the status is a decision rather than a
  /// transcription. A 413 because that is what `PayloadTooLarge` already answers for the
  /// per-request ceiling, and this is the same refusal about the same upload one scale up.
  ///
  /// Unreachable by a shipped client — the ceiling is ten times what the whole-file route
  /// accepts — which is what makes choosing a new status safe under rule 1.
  @Test("The transfer ceiling is a 413, beside the 400s it sits with")
  func transferCeilingIsPayloadTooLarge() {
    let error = UploadError.transferTooLarge(limit: 1024 * 1024 * 1024)
    let perRequest = PayloadTooLarge(limit: 1024 * 1024 * 1024)
    #expect(error.status == perRequest.status)
    #expect(error.errorType == perRequest.errorType)
    #expect(error.responseMessage == perRequest.responseMessage)
    // The SENTENCE differs, and has to: a client told "request body" about a 4 MB chunk that
    // was accepted would shrink its chunks forever against a limit on the whole transfer.
    #expect(error.errorMessage == "Upload exceeds the 1024 MB limit for a single transfer")
    #expect(error.status == 413)
    #expect(UploadError.pathNotPermitted.status == 400)
    #expect(UploadError.chunkOutOfOrder(index: 1, transferID: "t").status == 400)
  }

  @Test("A store not-found is the 404 it was, reporting Database Error")
  func storeNotFoundIsUnchanged() {
    let message = ReferenceMessages.webhookNotFound
    #expect(Shape(StoreError.notFound(message)) == Shape(InterfaceError.notFound(message)))
    // Stated separately as well as compared, because this is the pairing a reader will
    // assume is a mistake and correct: the reference sends "Database Error" with a 404 and
    // clients have branched on it for years.
    #expect(StoreError.notFound(message).status == 404)
    #expect(StoreError.notFound(message).errorType == .databaseError)
  }

  @Test("A store invalid-request is the 400 it was")
  func storeInvalidRequestIsUnchanged() {
    let message = "another webhook is already registered for that URL"
    #expect(
      Shape(StoreError.invalidRequest(message)) == Shape(InterfaceError.invalidRequest(message)))
  }

  @Test("Both new error types reach the renderer as HTTPError, not as a generic 500")
  func bothConformToHTTPError() {
    // The failure mode this guards: an error the renderer does not recognise comes back as a
    // generic `Server Error` 500. A 400 that silently became a 500 would be invisible to
    // every other test here, because the sentence would still be right.
    let errors: [any Error] = [
      UploadError.pathNotPermitted,
      UploadError.chunkOutOfOrder(index: 1, transferID: "t"),
      UploadError.transferTooLarge(limit: 1024),
      StoreError.notFound("x"),
      StoreError.invalidRequest("x"),
    ]
    for error in errors {
      #expect(error is any HTTPError, "\(type(of: error)) must carry its own status")
      #expect((error as? any HTTPError)?.status != 500)
    }
  }
}
