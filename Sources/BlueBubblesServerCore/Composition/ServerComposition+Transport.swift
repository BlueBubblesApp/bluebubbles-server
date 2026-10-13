//  ServerComposition+Transport
//  How a client reaches the server: codecs, authentication and the socket engine.
//
//  The socket engine is handed the same access controller and audit recorder the HTTP
//  stage uses, so one block list and one audit trail cover both transports. The password
//  is read through a closure per handshake rather than captured, so changing it takes
//  effect without a restart.

import BBAudit
import BBAuth
import BBBuiltIns
import BBEvents
import BBSettings
import BBSocketIO

extension ServerComposition {

  // MARK: - Transport

  /// How a client reaches the server: what it may speak, how it proves who it is, and the
  /// socket it speaks over.
  struct Transport: Sendable {
    let authMode: AuthMode
    let codecs: CodecNegotiator
    let tokenAuth: TokenAuthService
    let passwordDigests: PasswordDigestCache
    let events: EventBus
    let socketServer: SocketServer
    let engineIO: EngineIOServer
  }

  static func makeTransport(
    storage: Storage,
    accessControl: AccessControlService,
    auditLog: AuditRecorder
  ) async -> Transport {
    let settings = storage.settings

    // Codecs are registered, but the ceiling defaults to legacy-v1, so a client
    // advertising sealed-v2 still gets legacy-v1 until an operator raises it. Built to be
    // switchable, not switched.
    let codecPreference = await settings.get(Settings.eventPayloadCodec)
    let codecs = CodecNegotiator.full(preference: CodecIdentifier(codecPreference.rawValue))

    // Under `auth_mode = password` this constructs nothing: no signing key, no device
    // store, no bearer scheme.
    let authMode = await settings.get(Settings.authMode)
    let tokenAuth = TokenAuthService(
      configuration: TokenAuthConfiguration(mode: authMode),
      secrets: authMode == .password ? nil : storage.secrets
    )

    // Hashed once, not once per request. `SettingsPropagation` clears it when `password`
    // is written, so the "checked against the password as it is now" property below still
    // holds; see PasswordDigest.swift for why only successful reads are cached.
    let passwordDigests = PasswordDigestCache(
      load: { await settings.secret(Settings.password) }
    )

    let socketServer = SocketServer(negotiator: codecs)
    let engineIO = EngineIOServer(
      server: socketServer,
      // The auth chain is a CLOSURE rather than a value, so a handshake is checked against
      // the password as it is now. Capturing a chain here would keep authenticating
      // against whatever the password was at launch, and a password change would not lock
      // anybody out until the process restarted: the opposite of what changing it means.
      chain: { [tokenAuth] in
        await tokenAuth.chain(
          passwordProvider: { await passwordDigests.digest() }
        )
      },
      // THE SAME instance the HTTP middleware admits requests through, not a second one.
      // One block list across both transports is the point: a client that exhausts its
      // attempts over HTTP is blocked on the socket in the same moment, and the failures
      // it accumulates on either count toward one lockout. Two services would mean two
      // counters and twice the guesses. `SocketAccessControlWiringTests` asserts this
      // argument is here, because its absence is silent: handshakes keep working and
      // nothing is ever counted.
      accessControl: accessControl,
      // The same recorder the HTTP stage records into, so a wrong password over the socket
      // leaves the same audit record a wrong password over HTTP does.
      auditor: AuditAuthenticationBridge(recorder: auditLog),
      // A closure for the same reason the chain is one, and additionally because the
      // engine outlives every start and stop of the socket service. Reading the setting
      // per handshake is also what makes the answer right at BOOT: a socket switched off
      // before the server started never runs `SocketService.start`, so a flag that only
      // that method could set would say "accepting" forever.
      isAccepting: { [settings] in
        await ServiceEnablement.isEnabled(BuiltInManifests.ID.socket, settings: settings)
      }
    )

    return Transport(
      authMode: authMode,
      codecs: codecs,
      tokenAuth: tokenAuth,
      passwordDigests: passwordDigests,
      events: EventBus(),
      socketServer: socketServer,
      engineIO: engineIO
    )
  }
}
