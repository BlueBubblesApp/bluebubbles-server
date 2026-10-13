//  HTTPListenerSummary
//  The sentence under Configure HTTP Settings, describing where the server listens.
//
//  Four bind addresses mean "everything" and two mean "this Mac only", and the difference is
//  the whole point of the setting: someone reading this line is deciding whether their
//  server is reachable from the network. It was a `private var` on `HTTPSettingsSection`.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

enum HTTPListenerSummary {

  /// - Parameter bindAddress: the stored value, which is EMPTY on a default install and
  ///   means the same as `0.0.0.0`: an unset bind address is not "nowhere", it is
  ///   "everywhere", and reading it as a literal address would have printed
  ///   "Listening on ".
  static func summary(bindAddress: String, servesHTTPS: Bool) -> String {
    let listening =
      switch bindAddress {
      case "", "0.0.0.0", "::": "Listening on every network on this Mac"
      case "127.0.0.1", "::1": "Listening on loopback only"
      default: "Listening on \(bindAddress)"
      }
    return listening + ", " + (servesHTTPS ? "over HTTPS." : "over plain HTTP.")
  }
}
