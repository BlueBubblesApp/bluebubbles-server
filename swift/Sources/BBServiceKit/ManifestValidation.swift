//  ManifestValidation
//  Checking a manifest before anything it describes is allowed to run.
//
//  Every check here exists because the alternative is a failure that happens later and reads
//  as something else. A duplicate identifier silently steals another service's settings; a
//  cycle deadlocks startup; an entitlement naming a secret key is a credential leak that
//  looks like ordinary configuration. All of them are cheap to catch at load and expensive to
//  diagnose at runtime.
//
//  Validation is one function over data, deliberately: it has to run identically for a
//  built-in service compiled into the binary and for a third-party manifest parsed from JSON,
//  and anything that only ran for one of those would be a hole in whichever it skipped.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import Foundation

public enum ManifestProblem: Sendable, Equatable, CustomStringConvertible {
  case malformedIdentifier(ServiceIdentifier)
  case duplicateIdentifier(ServiceIdentifier)
  case unknownDependency(service: ServiceIdentifier, missing: ServiceIdentifier)
  case dependencyCycle([ServiceIdentifier])
  case dependsOnItself(ServiceIdentifier)
  /// An entitlement asked to read a key the host holds as a secret.
  case entitlementRequestsSecret(service: ServiceIdentifier, key: String)
  /// A third-party plugin asked for something only built-in services may have.
  case entitlementReservedForBuiltIns(service: ServiceIdentifier, entitlement: Entitlement)
  case duplicateFieldKey(service: ServiceIdentifier, key: String)
  case conditionReferencesUnknownField(service: ServiceIdentifier, field: String)
  case emptySelect(service: ServiceIdentifier, field: String)
  case hostTooOld(service: ServiceIdentifier, requires: Int, have: Int)
  /// Two services in a category that permits only one active member.
  case exclusiveCategoryConflict(category: ServiceCategory, services: [ServiceIdentifier])
  /// A migration claims to reach a version the manifest does not declare.
  case migrationBeyondVersion(service: ServiceIdentifier, migration: String, version: String)
  case duplicateMigration(service: ServiceIdentifier, version: String)
  /// A tool id that would not be safe as a directory name.
  case malformedToolIdentifier(service: ServiceIdentifier, tool: String)
  case duplicateTool(service: ServiceIdentifier, tool: String)
  /// A tool with no build for any architecture — nothing could ever be installed.
  case toolWithoutBuilds(service: ServiceIdentifier, tool: String)
  case duplicateToolBuild(service: ServiceIdentifier, tool: String, architecture: ToolArchitecture)
  /// A service that needs a program but never asked to run one.
  case toolWithoutSpawnProcess(service: ServiceIdentifier, tool: String)
  /// A tool that downloads from a host the service did not declare.
  case toolHostNotDeclared(service: ServiceIdentifier, tool: String, host: String)
  /// An unsigned tool with nothing else checking the bytes.
  case unverifiableTool(service: ServiceIdentifier, tool: String)
  /// A recommended version that the vendor offers no way to ask for.
  case recommendedVersionNotAddressable(service: ServiceIdentifier, tool: String)

  public var description: String {
    switch self {
    case .malformedIdentifier(let id):
      "'\(id)' is not a valid service identifier."
    case .duplicateIdentifier(let id):
      "Two services claim the identifier '\(id)'. Identifiers own a settings namespace, "
        + "so the second would read and overwrite the first's configuration."
    case .unknownDependency(let service, let missing):
      "\(service) depends on '\(missing)', which is not installed."
    case .dependencyCycle(let path):
      "Dependency cycle: \(path.map(\.rawValue).joined(separator: " -> "))."
    case .dependsOnItself(let id):
      "\(id) lists itself as a dependency."
    case .entitlementRequestsSecret(let service, let key):
      "\(service) asks to read '\(key)', which is a secret. Secrets are never handed "
        + "out — request the operation instead (for example authenticateRequests)."
    case .entitlementReservedForBuiltIns(let service, let entitlement):
      "\(service) is not a built-in service and may not request: "
        + entitlement.userFacingDescription
    case .duplicateFieldKey(let service, let key):
      "\(service) declares the field '\(key)' twice."
    case .conditionReferencesUnknownField(let service, let field):
      "\(service) has a field shown only when '\(field)' has a value, but declares no "
        + "field called '\(field)'."
    case .emptySelect(let service, let field):
      "\(service)'s field '\(field)' is a list with no options."
    case .hostTooOld(let service, let requires, let have):
      "\(service) needs plugin API version \(requires); this server provides \(have)."
    case .migrationBeyondVersion(let service, let migration, let version):
      "\(service) has a migration to \(migration), which is newer than its own version "
        + "\(version). It would never run."
    case .duplicateMigration(let service, let version):
      "\(service) declares two migrations to version \(version)."
    case .exclusiveCategoryConflict(let category, let services):
      "Only one \(category.displayName) can be active at a time, but these are all "
        + "enabled: \(services.map(\.rawValue).joined(separator: ", "))."
    case .malformedToolIdentifier(let service, let tool):
      "\(service) declares a program called '\(tool)', which is not a usable name. "
        + "A tool id becomes a directory name, so it may not contain separators."
    case .duplicateTool(let service, let tool):
      "\(service) declares the program '\(tool)' twice."
    case .toolWithoutBuilds(let service, let tool):
      "\(service) declares the program '\(tool)' with no build for any architecture, "
        + "so it could never be installed."
    case .duplicateToolBuild(let service, let tool, let architecture):
      "\(service)'s program '\(tool)' declares two \(architecture.displayName) builds."
    case .toolWithoutSpawnProcess(let service, let tool):
      "\(service) needs the program '\(tool)' but did not ask to run a program. "
        + "Add the spawnProcess entitlement so the permission is shown to the user."
    case .toolHostNotDeclared(let service, let tool, let host):
      "\(service) downloads '\(tool)' from \(host), which is not in the hosts it "
        + "declared. Every host a service reaches has to be on its permissions list."
    case .unverifiableTool(let service, let tool):
      "\(service)'s program '\(tool)' is neither signed nor published with checksums, "
        + "so nothing would check what was downloaded."
    case .recommendedVersionNotAddressable(let service, let tool):
      "\(service) recommends a version of '\(tool)', but that program is published as a "
        + "single URL that always serves the current build — there is no way to ask "
        + "for a particular version, so the recommendation could never be honoured."
    }
  }

  /// Whether this stops the service from loading.
  ///
  /// An exclusive-category conflict is the one that does NOT: it is a configuration state a
  /// user can be in and be asked to resolve, not a broken manifest. Refusing to start the
  /// server over it would turn "you picked two connection methods" into "your server will
  /// not boot".
  public var isFatal: Bool {
    if case .exclusiveCategoryConflict = self { return false }
    return true
  }
}

public enum ManifestValidator {

  /// Validates one manifest in isolation.
  ///
  /// - Parameter secretKeys: Keys the host stores as secrets. Passed in rather than imported
  ///   so this module keeps no dependency on the settings layer — and so a test can prove
  ///   the secret rule with a key of its own choosing.
  public static func validate(
    _ manifest: ServiceManifest,
    secretKeys: Set<String>,
    hostVersion: Int = ServiceManifest.hostAPIVersion
  ) -> [ManifestProblem] {
    var problems: [ManifestProblem] = []

    if !manifest.id.isWellFormed {
      problems.append(.malformedIdentifier(manifest.id))
    }
    if manifest.dependencies.contains(manifest.id) {
      problems.append(.dependsOnItself(manifest.id))
    }
    if manifest.minimumHostVersion > hostVersion {
      problems.append(
        .hostTooOld(
          service: manifest.id, requires: manifest.minimumHostVersion, have: hostVersion
        ))
    }

    problems.append(contentsOf: validateEntitlements(manifest, secretKeys: secretKeys))
    problems.append(contentsOf: validateForm(manifest))
    problems.append(contentsOf: validateMigrations(manifest))
    problems.append(contentsOf: validateTools(manifest))
    return problems
  }

  /// Validates a whole set together — the checks that only make sense across services.
  public static func validate(
    all manifests: [ServiceManifest],
    secretKeys: Set<String>,
    enabled: Set<ServiceIdentifier>? = nil,
    hostVersion: Int = ServiceManifest.hostAPIVersion
  ) -> [ManifestProblem] {
    var problems = manifests.flatMap {
      validate($0, secretKeys: secretKeys, hostVersion: hostVersion)
    }

    var seen: Set<ServiceIdentifier> = []
    for manifest in manifests {
      if !seen.insert(manifest.id).inserted {
        problems.append(.duplicateIdentifier(manifest.id))
      }
    }

    let known = Set(manifests.map(\.id))
    for manifest in manifests {
      for dependency in manifest.dependencies where !known.contains(dependency) {
        problems.append(.unknownDependency(service: manifest.id, missing: dependency))
      }
    }

    problems.append(contentsOf: cycles(in: manifests))
    problems.append(contentsOf: exclusivity(in: manifests, enabled: enabled))
    return problems
  }

  // MARK: - Pieces

  private static func validateEntitlements(
    _ manifest: ServiceManifest,
    secretKeys: Set<String>
  ) -> [ManifestProblem] {
    var problems: [ManifestProblem] = []

    for entitlement in manifest.entitlements {
      switch entitlement {
      case .readSettings(let keys), .writeSettings(let keys):
        // THE rule: no entitlement ever yields a credential. A service that needs to
        // check one asks the host to check it.
        for key in keys.sorted() where secretKeys.contains(key) {
          problems.append(.entitlementRequestsSecret(service: manifest.id, key: key))
        }

      case .readMessages, .sendMessages, .readContacts, .spawnProcess:
        // Available to built-ins now. A third-party plugin asking for these is not
        // refused because the request is unreasonable — a bridge legitimately needs
        // to read messages — but because how a user grants them is not yet decided,
        // and defaulting to "allowed" would decide it by accident.
        if !manifest.isBuiltIn {
          problems.append(
            .entitlementReservedForBuiltIns(
              service: manifest.id, entitlement: entitlement
            ))
        }

      case .receiveEvents, .network, .authenticateRequests, .ownStorage:
        break
      }
    }
    return problems
  }

  private static func validateForm(_ manifest: ServiceManifest) -> [ManifestProblem] {
    var problems: [ManifestProblem] = []
    let fields = manifest.fields
    var seen: Set<String> = []

    for field in fields {
      if !seen.insert(field.key).inserted {
        problems.append(.duplicateFieldKey(service: manifest.id, key: field.key))
      }

      switch field.kind {
      case .select(let options), .multiSelect(let options):
        if options.isEmpty {
          problems.append(.emptySelect(service: manifest.id, field: field.key))
        }
      default:
        break
      }

      // A condition naming a field that does not exist means the dependent field is
      // never shown — which looks exactly like a field someone forgot to implement.
      if let condition = field.visibleWhen,
        !fields.contains(where: { $0.key == condition.field })
      {
        problems.append(
          .conditionReferencesUnknownField(
            service: manifest.id, field: condition.field
          ))
      }
    }
    return problems
  }

  private static func validateMigrations(_ manifest: ServiceManifest) -> [ManifestProblem] {
    var problems: [ManifestProblem] = []
    var seen: Set<String> = []

    for migration in manifest.migrations {
      if !seen.insert(migration.toVersion).inserted {
        problems.append(.duplicateMigration(service: manifest.id, version: migration.toVersion))
      }
      // A migration past the manifest's own version can never run, because the migrator
      // stamps the manifest version when it finishes. Silently dead rather than wrong,
      // which is exactly the kind of thing nobody notices for a year.
      if ServiceMigrator.compare(migration.toVersion, manifest.version) == .orderedDescending {
        problems.append(
          .migrationBeyondVersion(
            service: manifest.id, migration: migration.toVersion, version: manifest.version
          ))
      }
    }
    return problems
  }

  /// The external programs a service needs.
  ///
  /// Two of these checks are about the user rather than about correctness. A service that
  /// downloads and runs a 38 MB binary is doing the single most consequential thing in this
  /// model, and the permissions list is the only place a person sees it — so the entitlement
  /// and the download host have to be declared, or the list is a description of something
  /// other than what happens. The third is about the download itself: an unsigned binary
  /// with no published checksums is bytes off the internet that nothing verified.
  private static func validateTools(_ manifest: ServiceManifest) -> [ManifestProblem] {
    guard !manifest.tools.isEmpty else { return [] }

    var problems: [ManifestProblem] = []
    var seen: Set<String> = []

    // The union of every host the service said it would reach.
    var declaredHosts: Set<String> = []
    var spawnsProcesses = false
    for entitlement in manifest.entitlements {
      switch entitlement {
      case .network(let hosts): declaredHosts.formUnion(hosts)
      case .spawnProcess: spawnsProcesses = true
      default: break
      }
    }

    for tool in manifest.tools {
      if !tool.isWellFormed {
        problems.append(.malformedToolIdentifier(service: manifest.id, tool: tool.id))
      }
      if !seen.insert(tool.id).inserted {
        problems.append(.duplicateTool(service: manifest.id, tool: tool.id))
      }
      if tool.builds.isEmpty {
        problems.append(.toolWithoutBuilds(service: manifest.id, tool: tool.id))
      }

      var architectures: Set<ToolArchitecture> = []
      for build in tool.builds where !architectures.insert(build.architecture).inserted {
        problems.append(
          .duplicateToolBuild(
            service: manifest.id, tool: tool.id, architecture: build.architecture
          ))
      }

      if !spawnsProcesses {
        problems.append(.toolWithoutSpawnProcess(service: manifest.id, tool: tool.id))
      }

      for host in tool.networkHosts.sorted() where !declaredHosts.contains(host) {
        problems.append(
          .toolHostNotDeclared(
            service: manifest.id, tool: tool.id, host: host
          ))
      }

      if tool.signature == .unsigned && tool.checksums == nil {
        problems.append(.unverifiableTool(service: manifest.id, tool: tool.id))
      }

      // Refused rather than ignored. A recommendation that silently never applies is
      // indistinguishable from one that does, right up until someone compares the
      // installed version against the declared one by hand and finds they never matched.
      if tool.recommended != nil && !tool.supportsVersionSelection {
        problems.append(
          .recommendedVersionNotAddressable(
            service: manifest.id, tool: tool.id
          ))
      }
    }
    return problems
  }

  /// Depth-first cycle detection over declared dependencies.
  ///
  /// Duplicated from `ServiceRegistry.resolveStartOrder` deliberately: this runs at LOAD, on
  /// manifests, before any service is constructed, so a cycle is reported as a manifest
  /// problem alongside the others rather than as a thrown error during startup.
  private static func cycles(in manifests: [ServiceManifest]) -> [ManifestProblem] {
    let byID = Dictionary(manifests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var problems: [ManifestProblem] = []
    var visited: Set<ServiceIdentifier> = []
    var visiting: Set<ServiceIdentifier> = []

    func visit(_ id: ServiceIdentifier, path: [ServiceIdentifier]) {
      if visited.contains(id) { return }
      if visiting.contains(id) {
        problems.append(.dependencyCycle(path + [id]))
        return
      }
      visiting.insert(id)
      for dependency in byID[id]?.dependencies ?? [] {
        visit(dependency, path: path + [id])
      }
      visiting.remove(id)
      visited.insert(id)
    }

    for manifest in manifests.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
      visit(manifest.id, path: [])
    }
    return problems
  }

  private static func exclusivity(
    in manifests: [ServiceManifest],
    enabled: Set<ServiceIdentifier>?
  ) -> [ManifestProblem] {
    guard let enabled else { return [] }

    var byCategory: [ServiceCategory: [ServiceIdentifier]] = [:]
    for manifest in manifests where enabled.contains(manifest.id) && manifest.category.isExclusive {
      byCategory[manifest.category, default: []].append(manifest.id)
    }

    return
      byCategory
      .filter { $0.value.count > 1 }
      .map {
        .exclusiveCategoryConflict(
          category: $0.key, services: $0.value.sorted { $0.rawValue < $1.rawValue })
      }
  }
}
