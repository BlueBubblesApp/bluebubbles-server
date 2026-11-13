//  AppVersion
//  The version of the build that is running, read one way.
//
//  `CFBundleShortVersionString` was read at seven sites with three fallbacks, so a bare
//  `swift run` called itself "", "0.0.0-dev" or "unknown" depending on who asked. There are
//  two honest answers and no more: `bundled` is nil when there is no bundle, for a reader
//  for which absence means something (the sidebar prints no version rather than a fake one;
//  the syslog `origin` element is left out), and `current` is the development marker, for a
//  reader that needs SOME string (the update check, the export manifest, the licence
//  client).
//
//  Neither is what `GET /server/info` advertises as `server_version`: that is a client
//  feature level, decided in `ServerVersion.advertised` (`BBHandlers`).

import Foundation

public enum AppVersion {

  /// What a build that escaped the packaging step calls itself. Sorts below every release,
  /// so an unbundled build is always offered an update rather than told it is newer.
  public static let developmentMarker = "0.0.0-dev"

  /// The bundle's marketing version, or nil when there is no `Info.plist`.
  public static var bundled: String? {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }

  /// The bundle's marketing version, or `developmentMarker`.
  public static var current: String { bundled ?? developmentMarker }
}
