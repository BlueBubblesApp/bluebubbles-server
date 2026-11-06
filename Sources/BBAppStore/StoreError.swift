//  StoreError
//  What the `app.db` repositories refuse, in this module's own vocabulary.
//
//  Same shape and same reason as `BBMedia.UploadError`: these repositories used to throw
//  `InterfaceError`, which was free while they lived in `BBInterfaces` and is a dependency
//  inversion now that they do not — the domain layer depends on this module, so this module
//  cannot name the domain layer's error type without a cycle.
//
//  The alternative was to move `InterfaceError` down into `BBCore` so everyone could throw it.
//  That was rejected: `BBInterfaces/CLAUDE.md` makes "this layer has its own vocabulary" a
//  rule, and the answer to a new module boundary is a vocabulary for the new module, not one
//  shared type that every layer reaches for.
//
//  The translation lives in `BBHandlers/StoreError+HTTP.swift`, and is held to exactly the
//  responses these cases produced before the split — including the pairing that looks wrong
//  and is the contract: 404 reports "Database Error".

import BBCore
import Foundation

public enum StoreError: BBError, Equatable, CustomStringConvertible {
  case notFound(String)
  case invalidRequest(String)

  public var description: String { body }

  public var code: String {
    switch self {
    case .notFound: "store.not_found"
    case .invalidRequest: "store.invalid_request"
    }
  }

  public var domain: String { "Store" }

  public var title: String {
    switch self {
    case .notFound: "Not found"
    case .invalidRequest: "That request cannot be carried out"
    }
  }

  public var body: String {
    switch self {
    case .notFound(let message), .invalidRequest(let message): message
    }
  }
}
