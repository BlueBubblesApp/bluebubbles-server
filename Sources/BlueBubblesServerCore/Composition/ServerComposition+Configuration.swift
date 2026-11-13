//  ServerComposition+Configuration
//  What a launch asks for: the options, `--set` parsing and the config file.
//
//  Both binaries read their arguments through these, so the CLI and the app cannot give
//  the same arguments two meanings. A value that cannot be read is skipped and reported,
//  never applied as a guess: a malformed `--set` entry is logged when the server starts,
//  and each config-file line that is not `key: value` is named by its line number.

import BBCore
import Foundation
import Logging

extension ServerComposition {

  public struct Options: Sendable {
    public var headless: Bool
    public var configPath: String?
    /// Overrides from the command line, which win over both the config file and the
    /// stored value.
    public var overrides: [String: String]
    /// `--set` entries that named nothing (no `=`, or no key), logged when the server starts.
    /// The CLI refuses one before it gets this far; the app cannot refuse its arguments.
    public var malformedOverrides: [String] = []
    /// Applies to both the file log and stdout.
    public var logLevel: Logger.Level

    public init(
      headless: Bool = false,
      configPath: String? = nil,
      overrides: [String: String] = [:],
      logLevel: Logger.Level = .info
    ) {
      self.headless = headless
      self.configPath = configPath
      self.overrides = overrides
      self.logLevel = logLevel
    }

    /// `--set key=value` entries, as both the CLI and the app read them.
    ///
    /// One parser for both binaries, so the same arguments cannot mean different things
    /// depending on which one a launch agent names.
    ///
    /// **An empty value is a value.** `split` omits empty subsequences by default, so
    /// `--set key=` produced a one-element array, failed the count check and was skipped:
    /// silently, because an entry this cannot read is dropped rather than reported. That
    /// made the documented rescue for a headless install that has switched off its own HTTP
    /// service, `bluebubbles-server --set disabled_services=`, do nothing at all. It is the
    /// one command someone runs when nothing else can reach the server, so failing quietly
    /// is the worst thing it could do. See `BuiltInManifests.alwaysOn`.
    ///
    /// Only the first `=` splits, so a value containing one survives, which passwords and
    /// base64 tokens routinely do. A missing `=` is skipped, and so is an empty KEY:
    /// `--set =value` names nothing. A repeated key takes the last value. Skipped, and
    /// never silently: the CLI refuses one before it starts (`malformedOverrides`), and the
    /// app, which cannot refuse its launch arguments, logs each when the server starts.
    public static func parseOverrides(_ entries: [String]) -> [String: String] {
      var overrides: [String: String] = [:]
      for entry in entries {
        guard let (key, value) = override(entry) else { continue }
        overrides[key] = value
      }
      return overrides
    }

    /// The entries `parseOverrides` skips, as given.
    public static func malformedOverrides(_ entries: [String]) -> [String] {
      entries.filter { override($0) == nil }
    }

    private static func override(_ entry: String) -> (String, String)? {
      let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, !parts[0].isEmpty else { return nil }
      return (String(parts[0]), String(parts[1]))
    }
  }
}

// MARK: - Adapters

/// Reads a YAML/env config file, if one is present.
public enum ConfigFile {

  /// What a read found, and what it could not use.
  struct Contents {
    var values: [String: String] = [:]
    /// A sentence per thing skipped: a line that is not `key: value`, or a file named with
    /// `--config` that is not there. Empty for the ordinary case.
    var problems: [String] = []
  }

  /// The values alone, for a caller with nowhere to report the rest.
  static func load(at path: String?) -> [String: String] { read(at: path).values }

  /// Absent is normal when NO path was given: most installs configure through the UI, and
  /// "no config file" is not an error. A path that was given and is not there is: somebody
  /// meant a file, and starting on defaults without saying so was how a typo in a launch
  /// agent went unnoticed.
  static func read(at path: String?) -> Contents {
    let resolved = path ?? ApplicationSupport.realHomeDirectory + "/bluebubbles.yml"
    var contents = Contents()
    let text: String
    do {
      text = try String(contentsOfFile: resolved, encoding: .utf8)
    } catch {
      if path != nil {
        contents.problems.append(
          "\(resolved) could not be read: \(DiagnosticText.sentence(for: error))")
      }
      return contents
    }

    // Deliberately a `key: value` reader rather than a YAML parser. The file exists for
    // headless and container deployments to set a handful of scalars; supporting nested
    // YAML would mean a dependency and a schema for something nothing needs.
    for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      let parts = trimmed.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else {
        // The line NUMBER, not its text: a line that failed to parse may hold a password.
        contents.problems.append("line \(number + 1) is not `key: value`, and was skipped")
        continue
      }
      contents.values[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
        String(parts[1])
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return contents
  }
}
