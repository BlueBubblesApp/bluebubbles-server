//  AuditLogManifest
//  The audit log, as the service the Integrations screen shows and the registry starts.
//
//  Every knob the feature has is a field in this manifest's own namespace, so the switch,
//  the retention, the read-recording toggle and the syslog receiver are configured where
//  every other integration is configured and reset by the same Reset button. There are no
//  core settings for it: nothing outside the audit log reads any of these.
//
//  The three TLS fields are SECRETS, so they live in the Keychain like every other credential
//  this server holds, and are never declarable by another service. They are `.paragraph`
//  fields because PEM is several lines: a one-line secure field would fold the newlines a
//  parser needs. The form never reads them back; it says whether one is stored.
//
//  The field keys are named here once, for the manifest and for the service, because a
//  relative key spelled in two files is the drift `SettingKeyLiteralTests` exists to catch
//  for the core registry and cannot see for a manifest.
//
//  See `docs/AUDIT_LOG.md`.

import BBServiceKit

/// The audit log's own field keys, relative to its namespace.
public enum AuditLogField {
  public static let retentionDays = "retention_days"
  public static let recordReads = "record_reads"
  public static let syslogEnabled = "syslog_enabled"
  public static let syslogHost = "syslog_host"
  public static let syslogPort = "syslog_port"
  public static let syslogTransport = "syslog_transport"
  public static let syslogFacility = "syslog_facility"
  public static let syslogTrustedCertificate = "syslog_ca_certificate"
  public static let syslogClientCertificate = "syslog_client_certificate"
  public static let syslogClientPrivateKey = "syslog_client_private_key"
}

extension BuiltInManifests {

  /// The condition that shows the syslog fields.
  private static let syslogIsOn = FieldCondition(field: AuditLogField.syslogEnabled, equals: "true")

  public static let auditLog = ServiceManifest(
    id: ID.auditLog,
    name: "Audit Log",
    summary: "Records every action, change and failed login, and can forward them to a SIEM.",
    details: """
      Keeps a tamper-evident record of what happened on this server: every state-changing \
      API request and who made it, every setting that changed and what it was before, every \
      service that started or stopped, and every authentication failure. Records never \
      contain message content or credentials. View them on the Audit Log page, export them \
      as CSV, or stream them to a syslog receiver such as Splunk, Elastic or Graylog over TLS.
      """,
    category: .system,
    symbol: "list.bullet.rectangle.portrait",
    entitlements: [
      // The receiver is whatever the operator names, so no host can be listed. Declared
      // even though forwarding is off by default: the permissions list describes what the
      // service CAN do once configured, which is the question a person is reading it for.
      .network(hosts: ["*"])
    ],
    settings: [
      .header("Retention"),
      .paragraph(
        "Records are kept in this server's own database and removed once they are older "
          + "than the retention period. The sweep runs when the server starts and once a day."
      ),
      .field(
        FieldDescriptor(
          key: AuditLogField.retentionDays,
          label: "Keep Records For (days)",
          help: "Records older than this are deleted. 0 keeps every record forever. The "
            + "default is 90.",
          kind: .number(range: 0...3650)
        )),
      .field(
        FieldDescriptor(
          key: AuditLogField.recordReads,
          label: "Record Read-Only Requests",
          help: "Also record GET requests. Every state-changing request is recorded "
            + "regardless; reads are off by default because clients poll constantly and "
            + "each one is a row.",
          kind: .toggle()
        )),

      .divider,
      .header("Syslog Forwarding"),
      .paragraph(
        "Stream every record to a syslog receiver as it is written, as RFC 5424 messages "
          + "whose body is the record as JSON. The local copy is kept either way."
      ),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogEnabled,
          label: "Forward to a Syslog Receiver",
          kind: .toggle()
        )),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogHost,
          label: "Receiver",
          help: "The receiver's hostname or address.",
          kind: .text(placeholder: "siem.example.com"),
          isRequired: true,
          visibleWhen: syslogIsOn
        )),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogTransport,
          label: "Transport",
          help: "TLS is the only one of the three a record should cross a network on. TCP "
            + "and UDP are for a receiver on this machine or a network you control.",
          kind: .select(options: [
            // First is the seeded default; see `ServiceSettingsBridge.seedDefaults`.
            FieldOption(value: "tls", label: "TLS (RFC 5425)"),
            FieldOption(value: "tcp", label: "TCP (RFC 6587)"),
            FieldOption(value: "udp", label: "UDP (RFC 5426)"),
          ]),
          visibleWhen: syslogIsOn
        )),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogPort,
          label: "Port",
          help: "Leave empty for the standard port: 6514 for TLS, 514 for TCP and UDP.",
          kind: .number(range: 1...65535),
          visibleWhen: syslogIsOn
        )),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogFacility,
          label: "Facility",
          help: "What the receiver files these under. local0 is what most receivers' "
            + "default rules pass through.",
          kind: .select(
            options: (0...7).map { "local\($0)" }.map { FieldOption(value: $0, label: $0) }),
          visibleWhen: syslogIsOn
        )),

      .collapsedHeader("TLS Certificates"),
      .paragraph(
        "Only for the TLS transport. Each is PEM text and is kept in the Keychain. Leave the "
          + "trusted certificate empty to accept any certificate the system already trusts; "
          + "set a client certificate and key only if the receiver requires senders to "
          + "authenticate."
      ),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogTrustedCertificate,
          label: "Trusted Certificate",
          help: "The CA that signed the receiver's certificate, or the receiver's own "
            + "self-signed certificate.",
          kind: .paragraph,
          isSecret: true,
          visibleWhen: syslogIsOn
        )),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogClientCertificate,
          label: "Client Certificate",
          help: "A certificate the receiver has been told to expect from this server.",
          kind: .paragraph,
          isSecret: true,
          visibleWhen: syslogIsOn
        )),
      .field(
        FieldDescriptor(
          key: AuditLogField.syslogClientPrivateKey,
          label: "Client Private Key",
          help: "The key for the client certificate above.",
          kind: .paragraph,
          isSecret: true,
          visibleWhen: syslogIsOn
        )),
    ]
  )
}
