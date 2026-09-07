//  SideBySideRunner
//  Drives two servers with identical requests and diffs the answers.
//
//  The last check before cutover: both servers against the same Mac, same messages, same
//  questions. Recorded fixtures prove the Swift server matches what the Node server said at
//  recording time; this proves it matches what the Node server says NOW, against the same
//  live database.
//
//  See `docs/TESTING.md`.

import Foundation

public struct ServerEndpoint: Sendable {
  public let name: String
  public let baseURL: String
  public let password: String

  public init(name: String, baseURL: String, password: String) {
    self.name = name
    // Trailing slashes would produce `//api/v1/...`, which some routers accept and
    // others 404 — an asymmetry that would look like a real difference.
    self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    self.password = password
  }
}

public struct ComparisonResult: Sendable {
  public let id: String
  public let referenceStatus: Int
  public let candidateStatus: Int
  public let differences: [Difference]
  public let error: String?

  public var isMatch: Bool {
    error == nil && referenceStatus == candidateStatus && differences.isEmpty
  }
}

public struct SideBySideRunner: Sendable {

  private let reference: ServerEndpoint
  private let candidate: ServerEndpoint
  private let session: URLSession

  public init(reference: ServerEndpoint, candidate: ServerEndpoint) {
    self.reference = reference
    self.candidate = candidate

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    // No caching. A cached answer from one server compared against a live answer from
    // the other is not a comparison at all.
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    self.session = URLSession(configuration: configuration)
  }

  public func run(_ requests: [CorpusRequest]) async -> [ComparisonResult] {
    var results: [ComparisonResult] = []
    for request in requests {
      results.append(await compare(request))
    }
    return results
  }

  private func compare(_ request: CorpusRequest) async -> ComparisonResult {
    do {
      // Sequential, not concurrent. Both servers read the same live chat.db, and a
      // message arriving between two parallel requests would show up as a difference
      // in counts that is real but meaningless. Back to back is as close as this can
      // get, and the volatile-field rules absorb the rest.
      let left = try await fetch(request, from: reference)
      let right = try await fetch(request, from: candidate)

      return ComparisonResult(
        id: request.id,
        referenceStatus: left.status,
        candidateStatus: right.status,
        differences: ResponseDiff.compare(expected: left.json, actual: right.json),
        error: nil
      )
    } catch {
      return ComparisonResult(
        id: request.id, referenceStatus: 0, candidateStatus: 0,
        differences: [], error: String(describing: error)
      )
    }
  }

  private func fetch(
    _ request: CorpusRequest,
    from endpoint: ServerEndpoint
  ) async throws -> (status: Int, json: [String: Any]) {
    var components = URLComponents(string: endpoint.baseURL + request.path)
    var items = request.query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "password", value: endpoint.password))
    components?.queryItems = items.sorted { $0.name < $1.name }

    guard let url = components?.url else {
      throw RunnerError.badURL(endpoint.baseURL + request.path)
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method.rawValue
    if let body = request.body {
      urlRequest.httpBody = Data(body.utf8)
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await session.data(for: urlRequest)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

    // A non-JSON body is reported as one difference rather than throwing: an HTML error
    // page from a proxy in front of one server is a finding, not a crash.
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return (status, object ?? ["__nonJSONBody": String(data: data, encoding: .utf8) ?? "<binary>"])
  }

  public enum RunnerError: Error, Sendable, LocalizedError {
    case badURL(String)
    public var errorDescription: String? {
      switch self {
      case .badURL(let url): "Could not build a URL from \(url)"
      }
    }
  }
}

extension Array where Element == ComparisonResult {

  /// A readable report. Matches are one line; differences are listed in full, because the
  /// moment this output matters is the moment something disagrees.
  ///
  /// - Parameter showingMatches: When false, only failures are listed — but the SUMMARY
  ///   still counts every result. Filtering the array before calling this produced
  ///   "0/1 endpoints match" for a run where eighteen of nineteen matched, which reads as
  ///   total failure and is the opposite of what happened.
  public func report(showingMatches: Bool = true) -> String {
    var lines: [String] = []
    let matched = filter(\.isMatch).count

    for result in self where showingMatches || !result.isMatch {
      if let error = result.error {
        lines.append("✗ \(result.id) — request failed: \(error)")
        continue
      }
      if result.referenceStatus != result.candidateStatus {
        lines.append(
          "✗ \(result.id) — status \(result.referenceStatus) vs \(result.candidateStatus)"
        )
      }
      if result.differences.isEmpty {
        if result.referenceStatus == result.candidateStatus {
          lines.append("✓ \(result.id) (\(result.referenceStatus))")
        }
      } else {
        lines.append("✗ \(result.id) — \(result.differences.count) difference(s):")
        for difference in result.differences.prefix(25) {
          lines.append("    \(difference)")
        }
        if result.differences.count > 25 {
          lines.append("    … and \(result.differences.count - 25) more")
        }
      }
    }

    lines.append("")
    lines.append("\(matched)/\(count) endpoints match.")
    return lines.joined(separator: "\n")
  }

  public var allMatch: Bool { allSatisfy(\.isMatch) }
}
