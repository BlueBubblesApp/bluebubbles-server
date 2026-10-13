//  ServiceHostPolicyTests
//  What a service is handed: its manifest's settings scope, never the store, and no
//  capability it does not use.
//
//  `ScopedSettings` is what makes a manifest's settings entitlements mean anything: a read or
//  write the manifest did not declare throws. That holds only while a service has no other
//  way in, and every service used to be handed the store itself (`SettingsProviding`) and
//  build its scope from it by convention. ntfy read and wrote four undeclared core keys
//  straight through the store, the connection methods published `server_address` past their
//  own scope, and nothing could tell. The same manifests are meant to be the boundary for
//  third-party plugins, so a built-in that shows the bypass teaches it.
//
//  So a service is handed `ScopedSettingsProviding`, which answers with a scope and never the
//  store, and this scans `Composition/Services/` for the ways back:
//
//  - `SettingsProviding` or `SettingsStore` named at all;
//  - a `ScopedSettings(` built by hand, which needs the store to build;
//  - `context.settings`, the store read off the container in a host projection;
//  - a scope asked for with a manifest other than the asking service's own, which would
//    hand one service another's permissions.
//
//  And because `Host` IS a service's dependency list, a capability in it that the service
//  never touches is a false statement about what the service needs: three had drifted in
//  (`SettingsProviding` on the webhook sink, `AlertProviding` on ntfy, `LoggerProviding` on
//  the scheduler). The last test reads each capability's members out of the three files that
//  declare them and fails a `Host` naming one whose members its file never reaches and whose
//  name it never mentions again.
//
//  It skips comments, so a header may still name what it does not use.

import BBTestSupport
import Foundation
import Testing

@Suite("Service host policy")
struct ServiceHostPolicyTests {

  /// Every file that declares a capability a service can compose.
  private static let capabilityFiles = [
    "Sources/BBInterfaces/Capabilities.swift",
    "Sources/BBHandlers/HandlerCapabilities.swift",
    "Sources/BlueBubblesServerCore/Composition/Services/ServiceCapabilities.swift",
  ]

  /// A service source, as its repository path and its lines with comments removed, so a
  /// line that is only comment reads as empty and the numbering is kept.
  private struct ServiceSource {
    let path: String
    let lines: [String]
  }

  private static func sources() throws -> [ServiceSource] {
    try SourceScanner.swiftFiles(under: "Sources/BlueBubblesServerCore/Composition/Services")
      .map { ServiceSource(path: $0.path, lines: $0.lines.map(\.code)) }
  }

  @Test("No service names the raw settings store")
  func noRawStore() throws {
    let files = try Self.sources()

    let forbidden: [(Regex<Substring>, String)] = [
      (#/\bSettingsProviding\b/#, "takes `SettingsProviding`"),
      (#/\bSettingsStore\b/#, "names `SettingsStore`"),
      (#/\bScopedSettings\(/#, "builds a `ScopedSettings` from the store"),
      (#/\bcontext\.settings\b/#, "reads the store off the container"),
    ]
    for file in files {
      for (index, line) in file.lines.enumerated() {
        for (pattern, what) in forbidden where line.contains(pattern) {
          Issue.record(
            "\(file.path):\(index + 1): \(what); take `ScopedSettingsProviding` instead")
        }
      }
    }
  }

  @Test("A service asks for its own scope and nobody else's")
  func ownScopeOnly() throws {
    var requests = 0
    for file in try Self.sources() {
      // The services this file declares: a host projection beside its service names that
      // service's manifest rather than `Self.manifest`, and that is the same thing.
      let owners = Set(
        file.lines.compactMap { line in
          line.firstMatch(of: #/^\s*actor (\w+)/#).map { String($0.output.1) }
        }
      )
      for (index, line) in file.lines.enumerated() {
        for match in line.matches(of: #/scopedSettings\(for: ([\w.]+)\)/#) {
          requests += 1
          let manifest = String(match.output.1)
          let allowed = ["Self.manifest"] + owners.map { "\($0).manifest" }
          guard !allowed.contains(manifest) else { continue }
          Issue.record(
            "\(file.path):\(index + 1): asks for the scope of `\(manifest)`; a service is scoped to its own manifest"
          )
        }
      }
    }
    #expect(requests > 0, "no service asks for a scope; this test is no longer looking")
  }

  /// Each capability protocol's members, by name.
  private static func capabilityMembers() throws -> [String: [String]] {
    var members: [String: [String]] = [:]
    for file in capabilityFiles {
      var current: String?
      for line in try SourceScanner.file(file).lines.map(\.code) {
        if let declaration = line.firstMatch(of: #/^(?:public )?protocol (\w+)/#) {
          let name = String(declaration.output.1)
          members[name] = []
          current = line.contains("}") ? nil : name
        } else if line.hasPrefix("}") {
          current = nil
        } else if let current, let member = line.firstMatch(of: #/^\s+(?:var|func) (\w+)/#) {
          members[current, default: []].append(String(member.output.1))
        }
      }
    }
    return members
  }

  @Test("A service's Host names nothing it does not use")
  func noUnusedCapabilities() throws {
    let members = try Self.capabilityMembers()
    #expect(members["AlertProviding"] == ["alerts"], "the capability parse is not reading")
    var hosts = 0
    for file in try Self.sources() {
      guard let start = file.lines.firstIndex(where: { $0.contains("typealias Host = any ") })
      else { continue }
      hosts += 1
      var end = start + 1
      while end < file.lines.count,
        file.lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("&")
      {
        end += 1
      }
      let capabilities = file.lines[start..<end]
        .joined(separator: " ")
        .replacingOccurrences(of: "typealias Host = any ", with: "")
        .split(separator: "&")
        .map { $0.trimmingCharacters(in: .whitespaces) }
      let rest = file.lines.indices
        .filter { !(start..<end).contains($0) }
        .map { file.lines[$0] }
        .joined(separator: "\n")

      for capability in capabilities {
        guard let names = members[capability] else {
          Issue.record(
            "\(file.path): `Host` names `\(capability)`, which no capability file declares")
          continue
        }
        let reached = try names.contains { name in
          rest.contains(try Regex("\\.\(name)\\b"))
        }
        let mentioned = rest.contains(try Regex("\\b\(capability)\\b"))
        guard !reached, !mentioned else { continue }
        Issue.record(
          "\(file.path):\(start + 1): `Host` names `\(capability)` and the service never uses it"
        )
      }
    }
    #expect(hosts > 0, "no service declares a Host; this test is no longer looking")
  }
}
