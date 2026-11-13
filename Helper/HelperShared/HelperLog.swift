//  HelperLog
//  Logging that survives being inside someone else's sandboxed app, for either helper.
//
//  `NSLog` is the obvious choice and the wrong one: from an injected dylib it reaches
//  **stderr and nothing else**, and a GUI app launched by `open` has no stderr anywhere a
//  person can read, so a helper logging that way is indistinguishable from one not running.
//  Measured directly: injecting into `/bin/echo` printed the line, while `log show` could not
//  find that same line afterwards. `os` logging with a real subsystem is queryable:
//
//      log stream --predicate 'subsystem == "com.bluebubbles.helper"'
//      log stream --predicate 'subsystem == "com.bluebubbles.facetimehelper"'
//
//  Every line is logged `.public`, because os logging REDACTS interpolated strings by
//  default and a line reading `<private>` looks like a logging bug. That makes what goes INTO
//  a line the whole of the privacy story: a helper line carries no address, no message
//  content and no file path (a path names the person whose home directory it is in).
//  `LogRedactionPolicyTests` scans every helper log call for an interpolation that names one.
//
//  One type for both helpers, so the two cannot log differently.

import os

/// The helpers' log, under the subsystem of the helper that owns it.
public struct HelperLog: Sendable {

  private let logger: Logger

  public init(subsystem: String) {
    logger = Logger(subsystem: subsystem, category: "helper")
  }

  /// A state transition worth having in a support log: started, registered, gave up.
  public func info(_ line: String) {
    logger.log("\(line, privacy: .public)")
  }

  /// Something the helper could not do.
  public func error(_ line: String) {
    logger.error("\(line, privacy: .public)")
  }
}
