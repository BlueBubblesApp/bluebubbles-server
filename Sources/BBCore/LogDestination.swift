//  LogDestination
//  Where the server's log file lives.
//
//  In BBCore rather than beside the logging stack because two processes need the path and only
//  one of them has a logger. `BlueBubblesLauncher` depends on BBCore alone — deliberately, it
//  is an AppKit shim with no logging stack — and it has exactly one line to write: the notice
//  saying it has stopped relaunching a server that keeps dying. That line used to go to
//  `NSLog`, which reaches the unified system log and NOT this file, so the log bundle a user
//  emails in ended abruptly with no explanation of why the server never came back.
//
//  A second copy of the path in the launcher would have been the obvious way to do it, and
//  would drift the first time either moved.

import Foundation

public enum LogDestination: Sendable {
  /// The path the Electron server writes to. Unchanged deliberately.
  public static var fileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/bluebubbles-server/main.log")
  }
}
