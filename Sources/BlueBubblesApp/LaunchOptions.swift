//  LaunchOptions
//  Command-line arguments for the app bundle.
//
//  The app has to honour the same arguments the CLI does. Building
//  `ServerComposition.Options()` with nothing means `--headless`, `--config` and `--set` are
//  accepted on the command line and silently ignored: the server comes up on its stored
//  settings while the operator believes their override applied.
//
//  That matters most for the launch agent, which starts the app with arguments and has no
//  other way to configure it.
//
//  Deliberately hand-parsed rather than ArgumentParser: an `App` owns `main`, so there is no
//  `ParsableCommand` entry point to hang off, and this is a dozen lines.

import BBCore
import BBInterfaces
import BlueBubblesServerCore
import Foundation

struct LaunchOptions {

  /// The options this process was launched with.
  ///
  /// A `static let`, so `argv` is read once. The `App` reads it for the activation policy
  /// and `AppModel.start` for the composition; two parsers would be two answers to a question
  /// with one answer.
  static let current = LaunchOptions.parse()

  var isHeadless = false
  var configPath: String?
  var overrides: [String: String] = [:]
  /// `--set` entries that were not `key=value`, for the server to log when it starts.
  var malformedOverrides: [String] = []

  /// Whether the launch agent started this process rather than a person.
  ///
  /// Not a composition option: nothing on the server cares who opened the app. It decides
  /// two app-level behaviours that only make sense unattended, the startup delay and
  /// starting minimised, and `AppBehaviourPolicy` is where that decision lives.
  /// `LaunchAgentContract.automaticLaunchArgument` carries the why.
  var wasLaunchedAutomatically = false

  /// Whether a person asked for anything on the command line.
  ///
  /// A copy launched with options of its own is never handed to the launch agent, which
  /// starts the app with fixed arguments: handing over `--headless --set …` would drop what
  /// was asked for. `LaunchAtLogin.shouldHandOver` reads this.
  var hasCommandLineOptions: Bool {
    isHeadless || configPath != nil || !overrides.isEmpty || !malformedOverrides.isEmpty
  }

  static func parse(_ arguments: [String] = CommandLine.arguments) -> LaunchOptions {
    var options = LaunchOptions()
    var setEntries: [String] = []
    var index = 1

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--headless":
        options.isHeadless = true
        index += 1

      case LaunchAgentContract.automaticLaunchArgument:
        options.wasLaunchedAutomatically = true
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
        // Collected and handed to the CLI's parser below, so `--set key=` means the same
        // thing whichever binary was launched.
        if index + 1 < arguments.count {
          setEntries.append(arguments[index + 1])
          index += 2
        } else {
          index += 1
        }

      default:
        // Anything else is ignored. macOS passes its own arguments to a bundled app
        // such as `-NSDocumentRevisionsDebugMode`, `-psn_0_…` when launched from Finder,
        // and treating an unrecognised one as an error would make the app refuse to
        // start when double-clicked.
        index += 1
      }
    }
    options.overrides = ServerComposition.Options.parseOverrides(setEntries)
    options.malformedOverrides = ServerComposition.Options.malformedOverrides(setEntries)
    return options
  }

  var compositionOptions: ServerComposition.Options {
    var options = ServerComposition.Options(
      headless: isHeadless,
      configPath: configPath,
      overrides: overrides
    )
    options.malformedOverrides = malformedOverrides
    return options
  }
}
