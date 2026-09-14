//  SendLaterGuidance
//  What the Scheduled Messages page says about Apple's own Send Later.
//
//  The page is the server's timer: it holds a message in `app.db` and sends it when the clock
//  comes round, which means this Mac has to be awake and the server running at the time.
//  Messages has had its own scheduling since macOS 15, Send Later, where iMessage holds the
//  message and delivers it whether or not this Mac is up. For anyone who can use that it is
//  the better tool, and the page should say so rather than let them find out from a message
//  that waited on a sleeping Mac. It needs the Private API, and it sends once: a recurring
//  message is the one thing only this page does, and every answer below says that.
//
//  Three answers, keyed on the two facts the features card already uses: the macOS major
//  and whether the Private API is on. The minimum version is read from the capability
//  catalog, which is the one place that number lives, so a corrected floor there corrects
//  this sentence too. Not a View, so the sentences can be asserted from a test; see
//  `SendLaterGuidanceTests`.

import BBPrivateAPICatalog

enum SendLaterGuidance: Equatable {
  /// This Mac predates Send Later. Scheduling here is the only option, and it is fine.
  case unavailable(macOSMajor: Int)
  /// Send Later would work on this Mac, but the Private API is off.
  case needsPrivateAPI
  /// Send Later works on this Mac and should be the first choice.
  case recommended

  init(macOSMajor: Int, privateAPI: PrivateAPIPresence) {
    guard Self.capability.isAvailable(on: macOSMajor) else {
      self = .unavailable(macOSMajor: macOSMajor)
      return
    }
    // `enabledButNotWorking` counts as on. The switch is set, and the status card on the
    // Private API tab is where a helper that is not answering gets diagnosed; this notice
    // is about which tool to reach for, not whether it is healthy this minute.
    self = privateAPI == .notEnabled ? .needsPrivateAPI : .recommended
  }

  private static let capability = PrivateAPICapability.sendLater

  /// The first macOS with Send Later, from the catalog rather than restated here.
  static var minimumMacOS: Int { capability.minimumMacOS }

  private static var minimumRelease: String {
    PrivateAPICapability.releaseName(minimumMacOS)
  }

  var title: String {
    switch self {
    case .unavailable: "Scheduling here is the right tool on this Mac"
    case .needsPrivateAPI, .recommended: "Send Later in Messages is the better way to schedule"
    }
  }

  /// One entry per paragraph, in the order they are read.
  var messages: [String] {
    switch self {
    case .unavailable(let macOSMajor):
      [
        "Messages has its own Send Later from \(Self.minimumRelease), and this Mac is on "
          + "\(PrivateAPICapability.releaseName(macOSMajor)). Until it is upgraded, "
          + "scheduling here is the way: the server holds the message and sends it at the "
          + "time, so this Mac has to be awake and the server running."
      ]
    case .needsPrivateAPI:
      [
        Self.howItDiffers,
        "Send Later needs the Private API, which is not turned on. Scheduling here works "
          + "without it.",
        Self.onlyHereRepeats,
      ]
    case .recommended:
      [
        Self.howItDiffers,
        "The Private API is on, so a client can schedule with Send Later, and the message "
          + "shows in Messages until it goes out.",
        Self.onlyHereRepeats,
      ]
    }
  }

  /// Whether the notice should offer a way to the Private API tab.
  var offersPrivateAPISetup: Bool { self == .needsPrivateAPI }

  private static var howItDiffers: String {
    "On \(minimumRelease) and later, Messages can hold a message and deliver it at a chosen "
      + "time itself, whether or not this Mac is awake or the server is running. A message "
      + "scheduled here is sent by the server's own timer, so both have to be up."
  }

  private static let onlyHereRepeats =
    "One thing that only this feature does is scheduling recurring messages. Send Later sends "
    + "once, so a message that goes out hourly, daily, weekly, monthly or yearly is scheduled here."
}
