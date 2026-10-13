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
//  `secrets` is the one that is not merely private but ACTIONABLE: the password, the tunnel
//  tokens, the Firebase service account and the TLS private key are, together, the server.
//  It is gated separately (`SecretsEnvelope`) and cannot be exported in the clear at all.

import Foundation

/// One selectable part of an export.
public enum ExportSection: String, CaseIterable, Sendable, Codable, Identifiable {
  case settings
  case webhooks
  case scheduledMessages
  case devices
  case contacts
  case accessControl
  case clientBackups
  case secrets

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
    }
  }

  /// What it actually contains, in the terms that matter for deciding to include it.
  public var summary: String {
    switch self {
    case .settings:
      "Your port, connection method, feature switches and preferences."
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
      "Your server password, tunnel tokens, Firebase key and TLS private key."
    }
  }

  /// Whether the section carries personal data or credentials rather than configuration.
  ///
  /// Drives emphasis in the UI. It is deliberately not the same question as `isSecret`:
  /// contacts are nobody's credential and still belong to people who did not choose this.
  public var isSensitive: Bool {
    switch self {
    case .settings, .webhooks, .clientBackups: false
    case .scheduledMessages, .devices, .contacts, .accessControl, .secrets: true
    }
  }

  /// The file this section is written to inside the archive.
  public var fileName: String {
    switch self {
    case .secrets: "secrets.enc"
    default: "\(rawValue).json"
    }
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
