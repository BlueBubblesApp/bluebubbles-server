//  LaunchOptions
//  Command-line arguments for the app bundle.
//
//  The app has to honour the same arguments the CLI does. It previously built
//  `ServerComposition.Options()` with nothing at all, so `--headless`, `--config` and `--set`
//  were accepted on the command line and silently ignored — the server came up on its stored
//  settings while the operator believed their override had applied.
//
//  That matters most for a login item, which is launched with arguments and has no other way
//  to be configured.
//
//  Deliberately hand-parsed rather than ArgumentParser: an `App` owns `main`, so there is no
//  `ParsableCommand` entry point to hang off, and this is a dozen lines.

import BBHandlers
import BBInterfaces
import BlueBubblesServerCore
import Foundation

struct LaunchOptions {

  var isHeadless = false
  var configPath: String?
  var overrides: [String: String] = [:]

  static func parse(_ arguments: [String] = CommandLine.arguments) -> LaunchOptions {
    var options = LaunchOptions()
    var index = 1

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--headless":
        options.isHeadless = true
        index += 1

      case "--config":
        // A missing value is ignored rather than treated as the next flag. `--config
        // --headless` would otherwise set the config path to "--headless" and fail
        // later with a confusing "no such file".
        if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
          options.configPath = arguments[index + 1]
          index += 2
        } else {
          index += 1
        }

      case "--set":
        if index + 1 < arguments.count {
          let entry = arguments[index + 1]
          // maxSplits: 1, so a value containing `=` survives — which passwords and
          // base64 tokens routinely do.
          let parts = entry.split(separator: "=", maxSplits: 1)
          if parts.count == 2 {
            options.overrides[String(parts[0])] = String(parts[1])
          }
          index += 2
        } else {
          index += 1
        }

      default:
        // Anything else is ignored. macOS passes its own arguments to a bundled app
        // — `-NSDocumentRevisionsDebugMode`, `-psn_0_…` when launched from Finder —
        // and treating an unrecognised one as an error would make the app refuse to
        // start when double-clicked.
        index += 1
      }
    }
    return options
  }

  var compositionOptions: ServerComposition.Options {
    ServerComposition.Options(
      headless: isHeadless,
      configPath: configPath,
      overrides: overrides
    )
  }
}
