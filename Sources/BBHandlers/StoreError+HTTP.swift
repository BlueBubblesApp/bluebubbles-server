//  StoreError+HTTP
//  The app-database repositories' failures have an HTTP spelling too.
//
//  Same boundary and same reasoning as `InterfaceError+HTTP`, and held to exactly what these
//  cases produced before `BBAppStore` was split out of `BBInterfaces`: both were
//  `InterfaceError`, so the status, the error type and the envelope sentence are transcribed
//  from that file rather than chosen again here.
//
//  **That includes the pairing that looks wrong.** 404 reports `.databaseError`, not
//  `.notFound`, because that is what the reference sends and what clients have branched on
//  for years. A module boundary is not a reason for a client to see a different response.

import BBAppStore
import BBHTTPAPI
import BBSerialization
import Foundation

extension StoreError: HTTPError {
  public var status: Int {
    switch self {
    case .invalidRequest: 400
    case .notFound: 404
    }
  }

  public var errorType: ErrorType {
    switch self {
    case .invalidRequest: .validationError
    // Not `.notFound`: the reference pairs 404 with "Database Error". Odd, but shipped.
    case .notFound: .databaseError
    }
  }

  public var responseMessage: String {
    switch self {
    case .invalidRequest: BadRequest().responseMessage
    case .notFound: NotFound().responseMessage
    }
  }

  public var errorMessage: String { body }
}
