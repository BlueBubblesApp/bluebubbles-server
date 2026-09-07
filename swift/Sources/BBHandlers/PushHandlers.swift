//  PushHandlers
//  Controllers for FCM device registration and client configuration.

import BBHTTPAPI
import BBInterfaces
import BBPersistence
import BBPushKit
import BBSerialization
import Foundation

public enum PushHandlers {

  public static func register(into registry: inout HandlerRegistry, context: some DeviceRegistering)
  {
    registry.register(.fcmRegisterDevice) { request in
      let values = try request.values()
      guard let token = values["identifier"]?.stringValue ?? values["token"]?.stringValue,
        !token.isEmpty
      else {
        throw BadRequest("The identifier field is required.")
      }
      let name = values["name"]?.stringValue ?? "Unknown Device"

      try await context.devices.register(name: name, identifier: token)
      // The message and nothing else, as the reference sends. Echoing the registration
      // back was ours to add and ours to remove.
      return .data(nil)
    }

    /// The Firebase client configuration — the `google-services.json` itself.
    ///
    /// Served from the STORED BYTES, not from a re-encoded model. A client builds its
    /// `FirebaseOptions` out of `client[].api_key[].current_key` and
    /// `client[].client_info.mobilesdk_app_id`; this server reads neither, so anything
    /// that round-trips the document through a type modelling only what the server needs
    /// hands back a file no client can use. It did exactly that, and the response looked
    /// perfectly well-formed while doing it.
    ///
    /// The one edit made on the way out is Google's missing `oauth_client`, restored the
    /// way the reference server restores it.
    registry.register(.fcmClientConfig) { _ in
      let store = PushCredentialStore(secrets: context.secrets)
      // 404, not 503. A 503 is the better description — the server is fine, a thing it
      // needs was never uploaded — but the reference answers `NotFound` here, and a
      // client branching on the status sees a retryable outage where the reference tells
      // it to go and configure Firebase.
      guard let raw = try await store.rawClientConfig() else {
        throw NotFound(ReferenceMessages.googleServicesNotFound)
      }
      return .data(patchOAuthClient(in: try JSONValue.parse(raw)))
    }
  }

  /// Restores the `oauth_client` entry Google stopped emitting in May 2023.
  ///
  /// Android clients read `oauth_client[0].client_id` and fail on an absent array rather
  /// than an empty one, so the reference server synthesizes the entry. The `client_id` is
  /// the project number — available directly under `project_info`, and recoverable from
  /// `mobilesdk_app_id` (`1:<projectNumber>:android:<hash>`) when it is not.
  ///
  /// A document that already HAS a populated `oauth_client` is returned untouched. Only
  /// the empty or absent case is filled in.
  static func patchOAuthClient(in document: JSONValue) -> JSONValue {
    guard case .array(let clients) = document["client"] ?? .null, !clients.isEmpty else {
      // Nothing to patch into. Rejected at import, so reaching here means credentials
      // predating that check — passed through as-is rather than fabricated over.
      return document
    }

    // Google writes the project number as a string, but files that have been through a
    // reformatter come back with it as a number, and reading only one form yields a
    // patch that silently does nothing.
    let projectInfo = document["project_info"]
    let projectNumber =
      projectInfo?["project_number"]?.stringValue
      ?? projectInfo?["project_number"]?.intValue.map(String.init)

    let patched = clients.map { client -> JSONValue in
      if case .array(let existing) = client["oauth_client"] ?? .null, !existing.isEmpty {
        return client
      }
      let appId = client["client_info"]?["mobilesdk_app_id"]?.stringValue
      let clientId =
        projectNumber
        ?? appId.flatMap { id -> String? in
          let parts = id.split(separator: ":")
          return parts.count > 1 ? String(parts[1]) : nil
        }
      guard let clientId else { return client }
      return client.merging([
        "oauth_client": .array([
          .object([
            "client_id": .string(clientId),
            // 3 is Google's "web/other" client type, which is what the reference
            // server writes and what the client expects to find.
            "client_type": .int(3),
          ])
        ])
      ])
    }

    return document.merging(["client": .array(patched)])
  }
}
