//  FirebaseDocuments
//  Reading and writing the two documents clients care about, over REST.
//
//  `server/config` carries the server's address — clients read it to find this machine.
//  `server/commands` carries `nextRestart` — clients write it to ask for a restart.
//
//  Both are reached through the REST APIs rather than an SDK, because there is no Swift
//  `firebase-admin`. Firestore's REST shape is unusual enough to be worth stating: values are
//  wrapped in a type tag, so a string is `{"stringValue": "…"}` rather than a bare string.
//
//  See `docs/EVENTS.md`.

import Foundation
import Logging

/// Publishes the server's address where clients look for it.
public actor ServerURLPublisher {

  private let api: GoogleAPIClient
  private let projectId: String
  private let databaseURL: String?
  private let kind: FirebaseDatabaseKind
  private let logger: Logger
  /// The last value written, so an unchanged address costs nothing.
  private var lastPublished: String?

  public init(
    api: GoogleAPIClient,
    projectId: String,
    kind: FirebaseDatabaseKind,
    databaseURL: String? = nil,
    logger: Logger = Logger(label: "bluebubbles.push.serverurl")
  ) {
    self.api = api
    self.projectId = projectId
    self.kind = kind
    self.databaseURL = databaseURL
    self.logger = logger
  }

  /// Writes the address if it has changed.
  ///
  /// - Parameter force: Writes regardless. Used after a project change, where the local
  ///   memory of what was published belongs to a different project entirely.
  public func publish(serverURL: String, force: Bool = false) async throws {
    guard !serverURL.isEmpty else { return }
    guard force || serverURL != lastPublished else { return }

    switch kind {
    case .firestore: try await publishToFirestore(serverURL)
    case .realtime: try await publishToRealtime(serverURL)
    }

    lastPublished = serverURL
    logger.info("Published the server address to Firebase")
  }

  private func publishToFirestore(_ serverURL: String) async throws {
    // `updateMask` makes this a merge rather than a replace. Without it the write would
    // delete any other field on the document — which is what `{merge: true}` guards
    // against in the current implementation.
    let url =
      "https://firestore.googleapis.com/v1/projects/\(projectId)"
      + "/databases/(default)/documents/server/config?updateMask.fieldPaths=serverUrl"
    let body = try JSONSerialization.data(withJSONObject: [
      "fields": ["serverUrl": ["stringValue": serverURL]]
    ])
    try await api.send(method: "PATCH", url: url, body: body)
  }

  private func publishToRealtime(_ serverURL: String) async throws {
    guard let databaseURL, !databaseURL.isEmpty else {
      throw GoogleAPIError.decodingFailed(reason: "no Realtime Database URL is configured")
    }
    // PATCH so sibling keys under `config` survive — notably `nextRestart`, which a PUT
    // would wipe and thereby break the restart button.
    let url =
      "\(databaseURL.hasSuffix("/") ? String(databaseURL.dropLast()) : databaseURL)/config.json"
    let body = try JSONSerialization.data(withJSONObject: ["serverUrl": serverURL])
    try await api.send(method: "PATCH", url: url, body: body)
  }

  /// Forgets what was published. Called when the project changes.
  public func reset() {
    lastPublished = nil
  }
}

// MARK: - Remote restart

/// Reads the restart command document.
public actor RestartCommandReader {

  private let api: GoogleAPIClient
  private let projectId: String
  private let databaseURL: String?
  private let kind: FirebaseDatabaseKind

  public init(
    api: GoogleAPIClient,
    projectId: String,
    kind: FirebaseDatabaseKind,
    databaseURL: String? = nil
  ) {
    self.api = api
    self.projectId = projectId
    self.kind = kind
    self.databaseURL = databaseURL
  }

  /// The `nextRestart` value, or nil when unset.
  ///
  /// Epoch milliseconds. Clients have written it as both a number and a string over the
  /// years, so both are accepted — rejecting the string form would silently break the
  /// restart button for older clients.
  public func nextRestart() async throws -> Int64? {
    switch kind {
    case .firestore: try await firestoreNextRestart()
    case .realtime: try await realtimeNextRestart()
    }
  }

  private func firestoreNextRestart() async throws -> Int64? {
    let url =
      "https://firestore.googleapis.com/v1/projects/\(projectId)"
      + "/databases/(default)/documents/server/commands"
    let data: Data
    do {
      data = try await api.send(method: "GET", url: url)
    } catch let error as GoogleAPIError {
      // A project that has never had a restart requested has no document, and that is
      // a normal state rather than a failure.
      if case .requestFailed(let status, _, _) = error, status == 404 { return nil }
      throw error
    }

    struct Document: Decodable {
      struct Value: Decodable {
        let stringValue: String?
        let integerValue: String?
        let doubleValue: Double?
      }
      let fields: [String: Value]?
    }
    guard
      let value = try? JSONDecoder().decode(Document.self, from: data)
        .fields?["nextRestart"]
    else { return nil }

    // Firestore returns integers as STRINGS in JSON, which is easy to miss and yields a
    // silently absent value if only `integerValue` as a number is handled.
    if let integer = value.integerValue { return Int64(integer) }
    if let string = value.stringValue { return Int64(string) }
    if let double = value.doubleValue { return Int64(double) }
    return nil
  }

  private func realtimeNextRestart() async throws -> Int64? {
    guard let databaseURL, !databaseURL.isEmpty else { return nil }
    let base = databaseURL.hasSuffix("/") ? String(databaseURL.dropLast()) : databaseURL
    let data = try await api.send(method: "GET", url: "\(base)/config/nextRestart.json")

    let text = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))
    guard text != "null", !text.isEmpty else { return nil }
    return Int64(text) ?? Int64(Double(text) ?? 0)
  }
}
