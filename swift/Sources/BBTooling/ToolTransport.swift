//  ToolTransport
//  The network, behind a protocol so the installer can be tested without one.
//
//  Three operations, which is all any of this needs: fetch a small document (a release list, a
//  checksums file), ask what a URL currently serves without downloading it (the only way to
//  check a vendor that publishes no versions), and stream a large file to disk with progress.
//
//  Streaming rather than `URLSession.data` is not an optimisation. cloudflared is 38 MB; a
//  `Data` in memory is 38 MB resident on a server whose whole idle budget is 60 MB, and it
//  would arrive with no progress to show for the thirty seconds it takes on a slow connection.

import Foundation

public struct ToolHTTPResponse: Sendable, Equatable {
  public let statusCode: Int
  public let headers: [String: String]

  public init(statusCode: Int, headers: [String: String] = [:]) {
    self.statusCode = statusCode
    self.headers = headers
  }

  /// The `ETag`, or failing that the `Last-Modified`.
  ///
  /// Either identifies "the bytes currently at this URL" well enough to notice a change,
  /// which is exactly what a rolling download needs and all it can get.
  public var validator: String? {
    header("ETag") ?? header("Last-Modified")
  }

  public func header(_ name: String) -> String? {
    // Case-insensitively: HTTP header names are, and `URLSession` normalises them
    // differently across versions.
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

public protocol ToolTransport: Sendable {
  /// A small document — a release list, a checksums file.
  func fetch(_ url: URL) async throws -> (Data, ToolHTTPResponse)
  /// What is currently at a URL, without transferring it.
  func head(_ url: URL) async throws -> ToolHTTPResponse
  /// Streams to `destination`, reporting completed fraction where the server said how big
  /// the body is.
  func download(
    _ url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ToolHTTPResponse
}

public struct URLSessionToolTransport: ToolTransport {

  private let session: URLSession
  private let userAgent: String

  /// GitHub refuses requests with no `User-Agent`, so this is not decoration.
  public init(session: URLSession = .shared, userAgent: String = "BlueBubbles-Server") {
    self.session = session
    self.userAgent = userAgent
  }

  public func fetch(_ url: URL) async throws -> (Data, ToolHTTPResponse) {
    let (data, response) = try await session.data(for: request(url, method: "GET"))
    return (data, Self.describe(response))
  }

  public func head(_ url: URL) async throws -> ToolHTTPResponse {
    // Some CDNs answer HEAD with a redirect chain and no validators; the response is
    // still what the caller asked for and a missing validator is handled upstream.
    let (_, response) = try await session.data(for: request(url, method: "HEAD"))
    return Self.describe(response)
  }

  public func download(
    _ url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ToolHTTPResponse {
    // A download task with a delegate, rather than `URLSession.bytes` or
    // `URLSession.download`. `bytes` yields ONE BYTE per `await` — 38 million suspensions
    // for cloudflared, which is tens of seconds of pure scheduling — and `download(for:)`
    // reports no progress at all, leaving a thirty-second wait with nothing on screen.
    // The delegate gives byte counts as they arrive and writes through the system's own
    // file handling.
    try await DownloadCoordinator.run(
      request: request(url, method: "GET"),
      destination: destination,
      progress: progress
    )
  }

  private func request(_ url: URL, method: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    // An update check that returns a cached answer for hours is not a check.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 30
    return request
  }

  private static func describe(_ response: URLResponse) -> ToolHTTPResponse {
    guard let http = response as? HTTPURLResponse else {
      return ToolHTTPResponse(statusCode: 0)
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      if let key = key as? String, let value = value as? String { headers[key] = value }
    }
    return ToolHTTPResponse(statusCode: http.statusCode, headers: headers)
  }
}

// MARK: - Download plumbing

/// A `URLSession` download driven to completion, with progress.
///
/// Its own session rather than a shared one: the delegate is set at session level, and a
/// session-level delegate is retained until the session is invalidated — sharing one would
/// leak a coordinator per download.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

  private let destination: URL
  private let progress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<ToolHTTPResponse, any Error>?
  private var moveError: (any Error)?
  private var lastReported = 0.0

  private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.progress = progress
  }

  static func run(
    request: URLRequest,
    destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ToolHTTPResponse {
    let coordinator = DownloadCoordinator(destination: destination, progress: progress)
    let session = URLSession(
      configuration: .ephemeral, delegate: coordinator, delegateQueue: nil
    )
    // Finishes outstanding tasks and then releases the delegate. Without it the session
    // holds the coordinator forever, which is the standard `URLSession` retain cycle.
    defer { session.finishTasksAndInvalidate() }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        coordinator.attach(continuation)
        session.downloadTask(with: request).resume()
      }
    } onCancel: {
      session.invalidateAndCancel()
    }
  }

  private func attach(_ continuation: CheckedContinuation<ToolHTTPResponse, any Error>) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
  }

  private func finish(_ result: Result<ToolHTTPResponse, any Error>) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let fraction = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    lock.lock()
    let shouldReport = fraction - lastReported >= 0.01 || fraction >= 1.0
    if shouldReport { lastReported = fraction }
    lock.unlock()
    // Stepped, because this crosses into the UI and a callback per packet is thousands
    // of hops for one download.
    if shouldReport { progress(fraction) }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // SYNCHRONOUSLY, and this is not a preference: the file at `location` is deleted the
    // moment this method returns. Moving it from a task would race the deletion and lose
    // the download roughly one time in ten, which is exactly the kind of failure that
    // gets reported as "the install sometimes doesn't work".
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
    } catch {
      lock.lock()
      moveError = error
      lock.unlock()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      finish(.failure(error))
      return
    }
    lock.lock()
    let failure = moveError
    lock.unlock()
    if let failure {
      finish(.failure(failure))
      return
    }

    var headers: [String: String] = [:]
    var status = 0
    if let http = task.response as? HTTPURLResponse {
      status = http.statusCode
      for (key, value) in http.allHeaderFields {
        if let key = key as? String, let value = value as? String { headers[key] = value }
      }
    }
    finish(.success(ToolHTTPResponse(statusCode: status, headers: headers)))
  }
}
