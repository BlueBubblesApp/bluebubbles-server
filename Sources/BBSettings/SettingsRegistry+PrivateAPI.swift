//  SettingsRegistry+PrivateAPI
//  The Private API switches, the FaceTime switches under them, and the helper paths.
//
//  Its own file so a reader of what the injected helpers are told opens these declarations
//  and not the rest of the registry. The lists that make a setting exist
//  (`Settings.renderable`, `Settings.hidden`) stay in `SettingsRegistry.swift`.

import Foundation

extension Settings {

  // MARK: - Private API

  public static let enablePrivateAPI = Setting<Bool>(
    "enable_private_api", default: false,
    presentation: .init(
      // Named for the APP it injects into, matching `FaceTime Private API` below. A bare
      // "Private API" beside "FaceTime Private API" invites the wrong reading: that the
      // first is the feature and the second an extra.
      label: "Messages Private API",
      help:
        "Enables reactions, edit/unsend, typing indicators and group management. Requires SIP to be disabled.",
      section: .messages, control: .toggle
    )
  )
  /// The FaceTime helper, injected into FaceTime.app.
  ///
  /// A real setting rather than a developer feature flag, and the sibling of the Messages
  /// toggle above: it turns a capability on for a user, and turning it on injects a helper
  /// and mounts routes exactly as `enable_private_api` does.
  public static let enableFaceTimePrivateAPI = Setting<Bool>(
    "enable_ft_private_api", default: false,
    presentation: .init(
      label: "FaceTime Private API",
      help: "Enables FaceTime link generation, outgoing calls and call hand-off. "
        + "Injects a helper into FaceTime.app, so FaceTime is restarted and kept "
        + "running. Independent of the Messages Private API: either can be used "
        + "without the other. Requires SIP to be disabled.",
      section: .faceTime, control: .toggle
    )
  )

  /// Whether a client may place an outgoing FaceTime call through this server.
  ///
  /// Separate from `enableFaceTimePrivateAPI`, which is the capability as a whole. This is the
  /// narrower question a person actually has an opinion about: links and call control are
  /// passive, but DIALLING makes this Mac ring somebody else's phone on a client's say-so.
  /// Someone can reasonably want FaceTime links without that.
  ///
  /// **Defaults ON, to preserve behaviour.** Outgoing calls have worked whenever the FaceTime
  /// Private API was on, and defaulting this off would silently break `POST facetime/call`
  /// for every existing install on upgrade.
  ///
  /// **NOT the legacy `facetime_calling`, which meant the opposite half of the feature.** In
  /// the Electron server that key gated INCOMING calls: the UI's own words were "the server
  /// will detect incoming FaceTime calls and forward a notification", and
  /// `PrivateApiFaceTimeStatusHandler` branched on it to pick the incoming event shape. Its
  /// nearest equivalent here is `faceTimeIncomingHandoff`. Reusing that key for outgoing calls
  /// would have handed an upgraded install a stored `true` meaning "I want incoming hand-off"
  /// and read it as "let clients dial out".
  public static let faceTimeOutgoingCalls = Setting<Bool>(
    "facetime_outgoing_calls", default: true,
    presentation: .init(
      label: "Let clients place calls",
      help: "Allows a client to start an outgoing FaceTime call from this Mac. Turn it off to "
        + "keep links and call control while never dialling anyone.",
      section: .faceTime, control: .toggle,
      requires: enableFaceTimePrivateAPI.key
    )
  )

  /// Whether the helper turns FaceTime's camera off while FaceTime is in the background.
  ///
  /// Injection RELAUNCHES FaceTime.app and FaceTime comes up previewing you, so enabling the
  /// FaceTime Private API lights the camera and the recording indicator with no call in
  /// progress. The helper undoes that whenever FaceTime is not the frontmost app: the rule
  /// is `NSApp.isActive`, so a user who brings FaceTime forward keeps their camera.
  ///
  /// **Defaults ON.** The camera is a side effect of something the SERVER did, and leaving a
  /// person's camera running as an opt-out is the wrong way round. Turning it off is for
  /// somebody who wants FaceTime.app to behave exactly as Apple ships it.
  ///
  /// Read by the Private API service and passed to the helper through the injection
  /// environment, so a change re-injects: the same as the toggles above it.
  public static let faceTimeIdleCameraOff = Setting<Bool>(
    "facetime_idle_camera_off", default: true,
    presentation: .init(
      label: "Turn the camera off in the background",
      help: "The server has to keep FaceTime running to use its Private API, and FaceTime "
        + "shows your camera when it is open. This turns it off whenever FaceTime is not the "
        + "app you are using. Bring FaceTime to the front and your camera works normally.",
      section: .faceTime, control: .toggle,
      requires: enableFaceTimePrivateAPI.key
    )
  )

  /// How long a server-created FaceTime link survives before the automatic sweep clears it.
  ///
  /// Only ever applies to links the SERVER minted: never one the user made in FaceTime.app,
  /// which the server records separately and never touches. Zero disables the sweep, leaving
  /// only the manual button.
  public static let faceTimeLinkTTLHours = Setting<Int>(
    "facetime_link_ttl_hours", default: 24,
    presentation: .init(
      label: "Clear server links after",
      help: "Hours before a link this server created is invalidated automatically. "
        + "Links you create yourself in FaceTime are never touched. 0 disables it.",
      section: .faceTime, control: .number(range: 0...720),
      requires: enableFaceTimePrivateAPI.key
    )
  )

  /// Answering an incoming call on a client's behalf.
  ///
  /// Separate from the toggle above because it is the most fragile of the FaceTime flows:
  /// it answers a LIVE call and must not drop until a client has really joined, or it hangs
  /// up on the caller. Off by default, and useless without `enable_ft_private_api`.
  public static let faceTimeIncomingHandoff = Setting<Bool>(
    "facetime_incoming_handoff", default: false,
    application: .composition,
    presentation: .init(
      label: "Incoming call hand-off",
      help: "Lets a client answer an incoming FaceTime call through the API and join "
        + "by link.",
      section: .faceTime, control: .toggle,
      requires: enableFaceTimePrivateAPI.key
    )
  )

  // There is deliberately NO setting for the helper transport, and adding one would be a
  // mistake worth naming here.
  //
  // `SocketTransport` is the only transport: a Unix socket inside the target app's own
  // container. The sandbox refuses a socket by LOCATION, not by kind: one in Application
  // Support or `/tmp` is refused, one inside the container connects, so there is no second,
  // closeable path and no legacy fallback to switch off. A setting here could only disable
  // the Private API outright.
  //
  // The concern such a setting would be reaching for: that a transport unable to identify
  // its peer lets any local process drive the Private API, is answered at connect time
  // instead: the peer's audit token is checked against the host app's code signature, and an
  // unverified peer is refused.
  //
  // See `.claude/docs/private-api.md` § "The sandbox, and where the socket must live".

  /// Where the helper dylib lives.
  ///
  /// Empty means "look inside the app bundle", which is where a released build finds it.
  /// A development server running from `.build` has no bundle to look in, so it points
  /// here, and it MUST point at an arm64e build on Apple Silicon, because Messages runs
  /// its arm64e slice and dyld silently declines a mismatched insert.
  public static let privateAPIHelperPath = Setting<String>(
    "private_api_helper_path", default: "",
    presentation: .init(
      label: "Helper dylib",
      help: "Leave empty to use the copy inside the app bundle.",
      section: .privateAPI, control: .path,
      // NOT USER-EDITABLE, but still a setting.
      //
      // Pointing this at the wrong file silently disables the Private API: dyld declines a
      // mismatched insert without a word, so the symptom is "reactions stopped working"
      // with nothing on screen connecting the two. A shipped install has exactly one
      // correct answer: the copy in its own bundle, so a file picker here is a way to
      // break it and nothing else.
      //
      // Still DECLARED, because a development build has no bundle to look in: running from
      // `.build`, this is the only way to name an arm64e helper. That case is served by
      // `--set private_api_helper_path=…` and the config file, both of which outrank the
      // stored value anyway, so hiding the field costs nothing.
      isInternal: true
    )
  )

  /// The FaceTime helper, injected into FaceTime.app rather than Messages.
  ///
  /// Separate from `privateAPIHelperPath` because they are DIFFERENT dylibs injected into
  /// DIFFERENT processes: FaceTime.app is its own sandboxed app with its own socket, and
  /// the Messages helper would be useless inside it. Same arm64e rule applies.
  public static let privateAPIFaceTimeHelperPath = Setting<String>(
    "private_api_facetime_helper_path", default: "",
    presentation: .init(
      label: "FaceTime helper dylib",
      help: "Leave empty to use the copy inside the app bundle.",
      section: .privateAPI, control: .path,
      // Hidden for the same reason as the Messages helper above.
      isInternal: true
    )
  )
}
