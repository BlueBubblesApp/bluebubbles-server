//  UpdaterPolicy
//  Whether this build may run Sparkle, decided from the bundle and off the object.
//
//  Sparkle verifies every download against `SUPublicEDKey`. A bundle whose key is blank is
//  a local build: `Tools/dev-bundle.sh` blanks it and `build-app.sh` warns when it has
//  nothing to substitute. Started over a blank key, Sparkle either refuses (an ad-hoc signed
//  bundle, which is every dev bundle) or falls back to Apple code signing alone (a Developer
//  ID one). Neither is what a local build wants: the first is a "contact the developer"
//  alert on every launch, the second an updater that would accept a feed nobody signed.
//
//  So the app decides here, once, before Sparkle is asked anything. Unavailable means the
//  installer seam stays empty (the endpoint refuses, as it did before an updater existed)
//  and the menu item falls back to the plain feed check `UpdatesModel` already does.
//
//  An enum rather than a static on `SparkleUpdater` because a test cannot construct the
//  updater without `Bundle.main` being an app; the decision is what deserves the test.

enum UpdaterPolicy {

  enum Availability: Equatable {
    case available
    /// The sentence the log and the menu say instead. Written for the person reading a
    /// local build's log, who is the only one who will see it.
    case unavailable(reason: String)
  }

  /// `publicKey` is the bundle's `SUPublicEDKey`, or nil when the key is absent altogether.
  static func availability(publicKey: String?) -> Availability {
    let trimmed = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
      return .unavailable(
        reason:
          "This build carries no update signing key, so it cannot verify a download "
          + "and will not install updates. Release builds are signed by the release workflow.")
    }
    return .available
  }
}
