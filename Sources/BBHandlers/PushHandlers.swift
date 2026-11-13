//  PushHandlers
//  Controllers for FCM device registration and client configuration.

import BBCore
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
      let token = try values.requireString("identifier", or: "token")
      let name = values["name"]?.stringValue ?? "Unknown Device"

      try await context.devices.register(name: name, identifier: token)
      // The message and nothing else, as the reference sends. Echoing the registration
      // back was ours to add and ours to remove.
      return .data(nil)
    }

    /// The Firebase client configuration: the `google-services.json` itself, as
    /// `PushInterface.clientConfiguration` reads it.
    registry.register(.fcmClientConfig) { _ in
      // 404, not 503. A 503 is the better description (the server is fine, a thing it
      // needs was never uploaded) but the reference answers `NotFound` here, and a
      // client branching on the status sees a retryable outage where the reference tells
      // it to go and configure Firebase.
      guard let config = try await PushInterface.clientConfiguration(secrets: context.secrets)
      else {
        throw NotFound(ReferenceMessages.googleServicesNotFound)
      }
      return .data(config)
    }
  }
}
