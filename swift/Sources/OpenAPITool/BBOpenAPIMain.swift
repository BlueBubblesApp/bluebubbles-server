//  bb-openapi
//  Generates the OpenAPI document, and reports fixture coverage.
//
//  Both subcommands have a `--check` mode that exits non-zero instead of writing. That is
//  what makes them usable in CI: `emit --check` fails when the committed document no longer
//  matches the route table, and `coverage --check` fails when a route loses its fixture or a
//  new undocumented route appears.
//
//  Usage:
//    swift run bb-openapi emit
//    swift run bb-openapi emit --check
//    swift run bb-openapi coverage
//    swift run bb-openapi coverage --check
//    swift run bb-openapi coverage --write-allowlist
//
//  See `.claude/docs/api.md`.

import ArgumentParser
import BBOpenAPI
import Foundation

@main
struct BBOpenAPICommand: ParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "bb-openapi",
    abstract: "Generate the OpenAPI document from the route table, and report fixture coverage.",
    subcommands: [Emit.self, Coverage.self, InferSchemas.self],
    defaultSubcommand: Emit.self
  )
}

// MARK: - Defaults

enum Paths {
  static let document = "docs/api/openapi.json"
  static let fixtures = "Fixtures/http"
  static let allowlist = "docs/api/uncovered-routes.txt"
  static let schemas = "Sources/BBOpenAPI/Resources/schemas.json"
}

// MARK: - emit

struct Emit: ParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "emit",
    abstract: "Write the OpenAPI document derived from RouteTable."
  )

  @Option(help: "Where to write the document.")
  var output: String = Paths.document

  @Option(help: "The value for `info.version`.")
  var apiVersion: String = "1.0.0"

  @Flag(
    help: "Compare against the committed document and exit non-zero if it differs. Writes nothing.")
  var check: Bool = false

  func run() throws {
    let document = try OpenAPIDocument.generate(
      options: .init(version: apiVersion)
    ).serialized()

    if check {
      let existing = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
      guard existing == document else {
        // Deliberately not printing a diff: the file is committed, so `git diff`
        // after a plain `emit` shows it better than anything reimplemented here.
        print(
          """
          \(output) is out of date with the route table.
          Regenerate it:  swift run bb-openapi emit
          """)
        throw ExitCode.failure
      }
      print("\(output) is up to date.")
      return
    }

    let directory = (output as NSString).deletingLastPathComponent
    if !directory.isEmpty {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
      )
    }
    try document.write(toFile: output, atomically: true, encoding: .utf8)

    let routes = RouteCatalog.routes
    print("Wrote \(output) — \(routes.count) routes across \(RouteCatalog.all.count) groups.")
  }
}

// MARK: - coverage

struct Coverage: ParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "coverage",
    abstract: "Report which routes have a recorded fixture."
  )

  @Option(help: "Directory of recorded HTTP fixtures.")
  var fixtures: String = Paths.fixtures

  @Option(help: "The ratchet file: routes known to have no fixture.")
  var allowlist: String = Paths.allowlist

  @Flag(help: "Emit the report as JSON instead of text.")
  var json: Bool = false

  @Flag(
    help:
      "Fail if an uncovered route is missing from the allowlist, or an allowlisted route is now covered."
  )
  var check: Bool = false

  @Flag(help: "Rewrite the allowlist from the current state. Use once, to establish the baseline.")
  var writeAllowlist: Bool = false

  func run() throws {
    let report = try FixtureCoverage.report(fixtureDirectory: fixtures)

    if writeAllowlist {
      try write(report)
      return
    }
    if check {
      try runCheck(report)
      return
    }
    json ? printJSON(report) : printText(report)
  }

  // MARK: Output

  private func printText(_ report: CoverageReport) {
    print("Fixture coverage — \(report.fixtureCount) recorded exchanges\n")

    for version in [1, 2] {
      let routes = report.routes(apiVersion: version)
      guard !routes.isEmpty else { continue }
      let covered = routes.filter(\.isCovered).count
      print("  v\(version):  \(covered)/\(routes.count) routes have a fixture")
    }

    let all = report.routes
    print("  total: \(all.filter(\.isCovered).count)/\(all.count)")
    // Stated separately, because a derived fixture cannot catch a divergence: it was written
    // from the same source the server was written from.
    let derived = report.derivedOnly
    if !derived.isEmpty {
      print("  (\(derived.count) of those are DERIVED from source, never observed)")
      for route in derived { print("      \(route.signature)") }
    }
    print("")

    // Grouped, because "which area is undocumented" is the question that decides what to
    // record next — a flat list of 100 paths does not answer it.
    var order: [String] = []
    var byGroup: [String: [RouteCoverage]] = [:]
    for route in all {
      let key = "\(route.group) (v\(route.apiVersion))"
      if byGroup[key] == nil { order.append(key) }
      byGroup[key, default: []].append(route)
    }

    for key in order {
      let routes = byGroup[key] ?? []
      let covered = routes.filter(\.isCovered).count
      print("\(key) — \(covered)/\(routes.count)")
      for route in routes {
        let mark = route.isCovered ? "ok  " : "MISS"
        let statuses =
          route.statuses.isEmpty
          ? ""
          : "  [\(route.statuses.map(String.init).joined(separator: " "))]"
        print("  \(mark) \(route.signature)\(statuses)")
      }
      print("")
    }

    if !report.unmatchedFixtures.isEmpty {
      print("Fixtures matching no route in the table (\(report.unmatchedFixtures.count)):")
      for line in report.unmatchedFixtures { print("  \(line)") }
      print("")
    }
  }

  private func printJSON(_ report: CoverageReport) {
    let routes = OrderedJSON.array(
      report.routes.map { route in
        .obj([
          ("method", .string(route.method)),
          ("path", .string(route.path)),
          ("group", .string(route.group)),
          ("apiVersion", .int(route.apiVersion)),
          ("availability", .string(route.availabilityID)),
          ("handlerId", .string(route.handlerID)),
          ("covered", .bool(route.isCovered)),
          ("statuses", .array(route.statuses.map { .int($0) })),
        ])
      })

    let document = OrderedJSON.obj([
      ("fixtureCount", .int(report.fixtureCount)),
      ("routeCount", .int(report.routes.count)),
      ("coveredCount", .int(report.covered.count)),
      ("routes", routes),
      ("unmatchedFixtures", .array(report.unmatchedFixtures.map { .string($0) })),
    ])
    print(document.serialized(), terminator: "")
  }

  // MARK: Ratchet

  private func write(_ report: CoverageReport) throws {
    // Reasons already written against a route are CARRIED OVER rather than regenerated
    // away. Losing them would make this command destructive to the one thing in the file a
    // human wrote, and the baseline gets re-established often enough that it would happen.
    let existing = annotatedAllowlist()
    let body = report.uncovered.map(\.signature).sorted()
      .map { signature -> String in
        guard let reason = existing[signature], !reason.isEmpty else { return signature }
        return "\(signature)  # \(reason)"
      }
      .joined(separator: "\n")
    let contents = """
      # Routes with no recorded fixture.
      #
      # A RATCHET, not a to-do list: `bb-openapi coverage --check` fails if a route not
      # listed here is uncovered, AND if a route listed here has since been covered. So
      # this file can only shrink. Record a fixture, delete the line.
      #
      # Regenerate the baseline (do this only to re-establish it, never to make a
      # failing check pass):
      #   swift run bb-openapi coverage --write-allowlist
      #
      # \(report.uncovered.count) of \(report.routes.count) routes.

      \(body)

      """
    let directory = (allowlist as NSString).deletingLastPathComponent
    if !directory.isEmpty {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
      )
    }
    try contents.write(toFile: allowlist, atomically: true, encoding: .utf8)
    print("Wrote \(allowlist) — \(report.uncovered.count) uncovered routes.")
  }

  private func runCheck(_ report: CoverageReport) throws {
    let listed = try loadAllowlist()
    let uncovered = Set(report.uncovered.map(\.signature))
    let covered = Set(report.covered.map(\.signature))

    let unlisted = uncovered.subtracting(listed).sorted()
    let nowCovered = listed.intersection(covered).sorted()
    // A signature in the file that matches no route at all — a route was renamed or
    // removed. Stale entries would otherwise keep the ratchet from ever tightening.
    let stale = listed.subtracting(uncovered).subtracting(covered).sorted()

    if !unlisted.isEmpty {
      print("These routes have no fixture and are not in \(allowlist):\n")
      for signature in unlisted { print("  \(signature)") }
      print(
        """

        Record a fixture for each, or add it to the allowlist with a reason.
        A fixture is what tells a client what the endpoint returns — an unlisted
        route here is an endpoint nobody can write a client against.

        """)
    }
    if !nowCovered.isEmpty {
      print("These routes now HAVE a fixture and must be removed from \(allowlist):\n")
      for signature in nowCovered { print("  \(signature)") }
      print("")
    }
    if !stale.isEmpty {
      print("These allowlist entries match no route — renamed or removed:\n")
      for signature in stale { print("  \(signature)") }
      print("")
    }

    guard unlisted.isEmpty, nowCovered.isEmpty, stale.isEmpty else {
      throw ExitCode.failure
    }
    print(
      "Coverage ratchet holds: \(report.covered.count)/\(report.routes.count) "
        + "routes covered, \(listed.count) known gaps.")
  }

  private func loadAllowlist() throws -> Set<String> {
    Set(annotatedAllowlist().keys)
  }

  /// The allowlist as signature -> reason.
  ///
  /// A trailing `# …` on an entry is the REASON that route has no fixture, and for some of
  /// them it is the only place that reason is written down: `POST /mac/lock` locks the
  /// screen, the restarts take the server away mid-request, and no amount of staring at the
  /// route table says so. Recording it here keeps the next person from assuming the gap is
  /// an oversight and "fixing" it by running the route.
  private func annotatedAllowlist() -> [String: String] {
    guard let contents = try? String(contentsOfFile: allowlist, encoding: .utf8) else {
      return [:]
    }
    var entries: [String: String] = [:]
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if let hash = line.firstIndex(of: "#") {
        let signature = line[..<hash].trimmingCharacters(in: .whitespaces)
        let reason = line[line.index(after: hash)...].trimmingCharacters(in: .whitespaces)
        if !signature.isEmpty { entries[signature] = reason }
      } else {
        entries[line] = ""
      }
    }
    return entries
  }
}

// MARK: - infer-schemas

/// Rebuilds the payload schemas from the recorded corpus.
///
/// Separate from `emit` on purpose. `emit` must produce the same document from the same
/// source on any machine, and the corpus is not on every machine — it is not in the app
/// bundle at all. Inference is therefore a deliberate step whose output is committed, and
/// `emit` reads that committed output. See Sources/BBOpenAPI/FixtureSchemas.swift.
struct InferSchemas: ParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "infer-schemas",
    abstract: "Infer request/response payload schemas from the recorded corpus."
  )

  @Option(help: "Directory of recorded HTTP fixtures.")
  var fixtures: String = Paths.fixtures

  @Option(help: "Where to write the schema table.")
  var output: String = Paths.schemas

  @Flag(help: "Compare against the committed table and exit non-zero if it differs.")
  var check: Bool = false

  func run() throws {
    let table = try SchemaGeneration.generate(fixtureDirectory: fixtures).serialized()

    if check {
      let existing = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
      guard existing == table else {
        print(
          """
          \(output) is out of date with the recorded corpus.
          Regenerate it:  swift run bb-openapi infer-schemas

          Note this OVERWRITES hand corrections in that file.
          """)
        throw ExitCode.failure
      }
      print("\(output) is up to date.")
      return
    }

    let directory = (output as NSString).deletingLastPathComponent
    if !directory.isEmpty {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    }
    try table.write(toFile: output, atomically: true, encoding: .utf8)

    let described = FixtureSchemas.table.count
    print("Wrote \(output).")
    print("Run `swift run bb-openapi emit` to fold the schemas into the document.")
    _ = described
  }
}
