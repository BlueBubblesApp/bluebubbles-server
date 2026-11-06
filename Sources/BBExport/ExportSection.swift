//  ExportSection
//  What an export may contain, declared once so the checkboxes and the command-line flags
//  cannot disagree about the list.
//
//  **Each case says what it holds and how private that is, because the person ticking the
//  box is deciding where their data goes.** "Settings and config" is an honest description
//  of two of these sections and a misleading one for the rest: scheduled messages are words
//  somebody wrote, contacts are names and phone numbers, the access control list is IP
//  addresses, and devices are push tokens. A checkbox list that says only "Scheduled
//  messages" invites somebody to tick everything and email the result.
//
//  **Three sections are not merely private but ACTIONABLE, and they are sealed.**
//  `secrets` is the server password, the licence key and each integration's tokens and
//  addresses; `firebaseCredentials` is the Firebase service account and the client
//  configuration; `tlsCertificate` is the certificate this server presents and its private
//  key. Together they are the server. Each is encrypted under the server password
//  (`SecretsEnvelope`) and none can be exported in the clear at all (`isSealed`).
//
//  The two credential sections are separate from `secrets`, and from each other, because
//  they live outside settings, in Keychain items of their own (`CredentialVault`), and
//  because they are independent decisions: somebody moving to a new hostname wants their
//  Firebase project and not the old certificate, and somebody whose phones are registered
//  against one project may want the certificate without replacing it.

import Foundation

/// One selectable part of an export.
///
/// The order of the cases is the order an archive is written and restored in, and it is
/// load-bearing for one pair: `devices` comes before `firebaseCredentials`, so a restore
/// knows whether the registered devices it holds came from the same archive as the
/// credentials. See `CredentialVault.restore(_:keepingDevices:)`.
public enum ExportSection: String, CaseIterable, Sendable, Codable, Identifiable {
  case settings
  case webhooks
  case scheduledMessages
  case devices
  case contacts
  case accessControl
  case clientBackups
  case secrets
  case firebaseCredentials
  case tlsCertificate

  public var id: String { rawValue }

  /// What a person sees on the checkbox.
  public var title: String {
    switch self {
    case .settings: "Settings"
    case .webhooks: "Webhooks"
    case .scheduledMessages: "Scheduled messages"
    case .devices: "Registered devices"
    case .contacts: "Contacts"
    case .accessControl: "Access control"
    case .clientBackups: "Client backups"
    case .secrets: "Passwords and keys"
    case .firebaseCredentials: "Firebase credentials"
    case .tlsCertificate: "TLS certificate"
    }
  }

  /// What it actually contains, in the terms that matter for deciding to include it.
  public var summary: String {
    switch self {
    case .settings:
      "Your port, connection method, integrations and preferences. Tokens, and addresses "
        + "that say how to reach this server, travel with passwords and keys."
    case .webhooks:
      "The URLs you registered and the events each one receives."
    case .scheduledMessages:
      "Messages waiting to be sent, and the record of ones already sent — including their text."
    case .devices:
      "The push registrations your phones made. These are credentials for notifying them."
    case .contacts:
      "The address book this server has indexed: names, phone numbers and email addresses."
    case .accessControl:
      "Which clients are allowed or blocked, by address."
    case .clientBackups:
      "Themes and client settings your apps stored on this server."
    case .secrets:
      "Your server password, licence key, and each integration's tokens and addresses."
    case .firebaseCredentials:
      "The service account key and google-services.json push notifications use. Whoever "
        + "holds them can send notifications as this server. Restored onto a server set up "
        + "with a different Firebase project, they replace it, and its registered devices "
        + "are removed unless they are restored too."
    case .tlsCertificate:
      "The certificate you imported for HTTPS, its private key and any chain. One this "
        + "server generated for itself is not exported: a new one is generated wherever "
        + "this is restored."
    }
  }

  /// Whether the section carries personal data or credentials rather than configuration.
  ///
  /// Drives emphasis in the UI. It is deliberately not the same question as `isSecret`:
  /// contacts are nobody's credential and still belong to people who did not choose this.
  public var isSensitive: Bool {
    switch self {
    case .settings, .webhooks, .clientBackups: false
    case .scheduledMessages, .devices, .contacts, .accessControl, .secrets,
      .firebaseCredentials, .tlsCertificate:
      true
    }
  }

  /// Whether the section is encrypted under the server password, and so needs it both to
  /// export and to import. See the header.
  public var isSealed: Bool {
    switch self {
    case .secrets, .firebaseCredentials, .tlsCertificate: true
    case .settings, .webhooks, .scheduledMessages, .devices, .contacts, .accessControl,
      .clientBackups:
      false
    }
  }

  /// The file this section is written to inside the archive.
  public var fileName: String {
    isSealed ? "\(rawValue).enc" : "\(rawValue).json"
  }

  /// What a person gets when they have not chosen.
  ///
  /// Configuration only. Everything holding somebody's messages, contacts or credentials is
  /// off until it is ticked, for the reason `Settings.searchIndexEnabled` is off: a default
  /// nobody chose must not be the one that moves personal data onto a disk.
  public static var defaultSelection: Set<ExportSection> {
    [.settings, .webhooks, .clientBackups]
  }
}
