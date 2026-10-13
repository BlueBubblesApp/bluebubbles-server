//  SocketTransport+Lifecycle
//  Binding one listener per app, and tearing every listener, connection and subscription
//  down again. A listener that fails to bind is reported and the others still come up, so
//  a Mac where FaceTime has no container still gets a working Messages helper.
//
//  One slice of `SocketTransport`; the type, its stored state and the subscriber streams are
//  in `SocketTransport.swift`.

import BBCore
import BBPrivateAPIContract
import Foundation
import NIOCore
import NIOPosix

extension SocketTransport {

  public func start() async throws {
    guard serverChannels.isEmpty else { return }

    // One listener per app. A failure to bind ONE is not fatal: a Mac where FaceTime
    // has no container yet must still get a working Messages helper, so the failure is
    // reported and the others still come up.
    for listener in listeners {
      let path = listener.path
      do {
        // A bootstrap per listener, so each accepted connection carries the app its socket
        // serves from the moment it exists; see `Listener`.
        let bootstrap = ServerBootstrap(group: group)
          .serverChannelOption(ChannelOptions.backlog, value: 64)
          .childChannelInitializer { [weak self] channel in
            guard let self else { return channel.eventLoop.makeSucceededVoidFuture() }
            let promise = channel.eventLoop.makePromise(of: Void.self)
            Task {
              do {
                try await self.accept(channel, servingHost: listener.host)
                promise.succeed(())
              } catch {
                // Closed before any frame is read, so an unauthorised peer never gets
                // to send us anything.
                try? await channel.close()
                promise.fail(error)
              }
            }
            return promise.futureResult
          }
        try prepareSocketDirectory(for: path)
        let channel = try await bootstrap.bind(unixDomainSocketPath: path).get()
        serverChannels.append(channel)
        // The socket itself is owner-only, whatever mode the directory was created
        // with; the peer check in `accept` is what the security rests on.
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: path
        )
        logger.info(
          "Private API socket listening", metadata: [.init("path"): .string(path)]
        )
      } catch {
        logger.warning(
          "Could not bind a Private API socket",
          metadata: [
            .init("path"): .string(path),
            .init("error"): .string(String(describing: error)),
          ])
      }
    }
    guard !serverChannels.isEmpty else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "no Private API socket could be bound (tried "
          + socketPaths.joined(separator: ", ") + ")"
      )
    }
  }

  /// Prepares the containing directory and clears any stale socket file.
  ///
  /// The directory is inside MESSAGES' container, not ours, and two things follow:
  ///
  ///   - Writing there requires Full Disk Access. The server already needs it to read
  ///     chat.db, so it is not a new prompt, but the Private API now depends on it, and a
  ///     refusal here must say so rather than surface as an opaque `bind` failure.
  ///   - The directory is Apple's. It is created if absent and its permissions are LEFT
  ///     ALONE: chmod-ing a system app's container to suit us would be overreach, and the
  ///     socket file's own `0600` is what protects it.
  ///
  /// A leftover socket from a crashed process makes `bind` fail with EADDRINUSE, which
  /// would otherwise look like "another server is running" when nothing is.
  private func prepareSocketDirectory(for socketPath: String) throws {
    guard SocketLocation.isUsableSocketPath(socketPath) else {
      throw PrivateAPIError.transportUnavailable(
        "the socket path is \(socketPath.utf8.count) bytes and the maximum is "
          + "\(SocketLocation.maximumSocketPathLength). This usually means a very "
          + "long user name or a network home directory. Set "
          + "BLUEBUBBLES_HELPER_SOCKET to a shorter path inside the app's container."
      )
    }

    let directory = (socketPath as NSString).deletingLastPathComponent
    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
      )
    } catch {
      throw PrivateAPIError.transportUnavailable(
        "could not create \(directory): " + DiagnosticText.sentence(for: error) + " The Private "
          + "API needs Full Disk Access to place its socket inside the target "
          + "app's container. Grant it in System Settings > Privacy & Security."
      )
    }

    if FileManager.default.fileExists(atPath: socketPath) {
      try FileManager.default.removeItem(atPath: socketPath)
    }
  }

  public func stop() async {
    // The lane first, so nothing arriving mid-teardown is handed to a half-stopped
    // transport. Finishing ends the drain loop on its own; the stop cancels it too, for the
    // case where it is parked on a `handle` that is itself awaiting something.
    frames?.finish()
    frames = nil
    await frameDrain.stop()

    await transactions.failAll(with: PrivateAPIError.notConnected)
    for channel in connections.all {
      try? await channel.close().get()
    }
    connections.removeAll()

    for channel in serverChannels {
      try? await channel.close().get()
    }
    serverChannels.removeAll()
    for path in socketPaths {
      try? FileManager.default.removeItem(atPath: path)
    }
    if ownsGroup {
      try? await group.shutdownGracefully()
    }

    // End every subscription rather than leaving its `for await` parked on a transport
    // that will never yield again. Callers cancel their own pumps too, but a stream that
    // outlives the thing feeding it is a leak waiting for the one caller that forgets.
    for continuation in subscribers.values {
      continuation.finish()
    }
    subscribers.removeAll()

    logger.info("Private API socket stopped")
  }
}
