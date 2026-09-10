//  CustomSettingControl
//  The settings whose control cannot be generated from a static declaration.
//
//  `SettingRow` chose these by comparing `setting.key` to three constants inline, with a
//  `default` arm falling through to a read-only line. That default is the problem: a fourth
//  machine-dependent control means editing the one view every setting renders through, and a
//  key that loses its case (renamed, or a control not yet written) renders as grey text
//  with nothing failing anywhere. A case here does not compile until `SettingRow` draws it.
//
//  Not a View, so `CustomSettingControlTests` can assert that every `.custom` presentation in
//  the registry resolves to one; touching a SwiftUI `View` type from a test process traps.

import BBSettings

/// A setting the generated form cannot render, because its OPTIONS are runtime data.
enum CustomSettingControl: CaseIterable, Hashable {
  /// The installed services in the exclusive `reverse-proxy` category. Not enum cases,
  /// which is what lets a third-party tunnel appear without this file changing.
  case connectionMethod
  /// This machine's live network interfaces, which change when a cable is plugged in.
  case bindAddress
  /// The same event picker the webhook editor uses. Both sinks filter on one vocabulary,
  /// and two pickers would eventually offer two different ones.
  case ntfyEvents

  init?(key: String) {
    switch key {
    case Settings.connectionMethod.key: self = .connectionMethod
    case Settings.bindAddress.key: self = .bindAddress
    case Settings.ntfyEvents.key: self = .ntfyEvents
    default: return nil
    }
  }

  /// The setting this control renders, for the test that proves the two lists agree.
  var key: String {
    switch self {
    case .connectionMethod: Settings.connectionMethod.key
    case .bindAddress: Settings.bindAddress.key
    case .ntfyEvents: Settings.ntfyEvents.key
    }
  }
}
