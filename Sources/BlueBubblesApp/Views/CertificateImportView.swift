//  CertificateImportView
//  Importing a TLS certificate by dropping it on the window.
//
//  The Electron server had the user place `server.pem` and `server.key` into an application
//  support folder by hand, which means finding a hidden directory in the Finder and naming
//  two files exactly right. This is the same operation with the file system taken out of it:
//  drop both files, or pick them.
//
//  Deliberately explicit about which file is which. A certificate and a key are both PEM and
//  look identical to anyone who has not seen one before, and installing them the wrong way
//  round produces a TLS handshake failure with no useful message anywhere. So the drop is
//  classified by INSPECTING the contents rather than by the order they arrived in or by
//  their extension, both of which are wrong often enough to matter.
//
//  **Where an imported certificate goes, and how the server knows it is yours.** Into the
//  Keychain, which is the only store: `Certs/` is read once to adopt whatever an older build
//  left there and is then removed, so this clears it rather than writing to it. On an Electron
//  install provenance is encoded by the ABSENCE of `expiration.txt`, which is written only
//  when the server generates a certificate. A store with no files cannot express that, so
//  `tls_certificate_origin` says
//  it explicitly, and the recorded expiry is deliberately ZERO, because that field is the
//  renewal clock and a real date on somebody else's certificate would invite the renewer to
//  act on it. See `CertificateKeychainStore` and `TLSProvisioning`.

import BBCore
import BBSettings
import BBSystem
import BlueBubblesServerCore
import SwiftUI

struct CertificateImportView: View {

  /// Needed only to reach the settings store and the Keychain. The file half of this view
  /// still works without a running server; the provenance half cannot, which is why the call
  /// site renders it only when the server is up.
  @Bindable var model: AppModel

  @State private var certificatePEM: String?
  @State private var privateKeyPEM: String?
  @State private var status: Status = .idle
  /// An install in flight. The button is disabled meanwhile: a second click would write
  /// the same material twice and clear the files under the first write.
  @State private var isInstalling = false
  /// Mirrors `tls_certificate_expires_at`. Held in state because the store is actor-isolated
  /// and `recordedExpiry()` is called from a synchronous rendering path.
  @State private var expiresAtSeconds: Int?

  private let store = CertificateStore()

  enum Status: Equatable {
    case idle
    case installed(expires: Date?)
    case failed(String)
  }

  var body: some View {
    // The explanation goes in the section's subtitle, which is where every other group on
    // this screen puts it.
    SettingsSection(
      "TLS Certificate",
      subtitle: "Let this server terminate HTTPS itself, instead of a tunnel or reverse "
        + "proxy doing it. Leave this alone if you use Cloudflare, ngrok, zrok or Tailscale."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        dropZone
        if certificatePEM != nil || privateKeyPEM != nil { stagedFiles }
        statusLine
        actions
      }
      .padding(.vertical, 4)
    }
    .task { refreshStatus() }
  }

  // MARK: - Drop zone

  /// Not restricted by type: certificates arrive as .pem, .crt, .cer, .key, and frequently
  /// with no extension at all. The contents decide, not the name.
  private var dropZone: some View {
    DropZone(
      title: "Drop your certificate and private key here",
      caption: "Both are PEM files, usually .pem, .crt or .key",
      symbol: "lock.doc",
      chooserMessage: "Choose your certificate and private key."
    ) { urls in
      for url in urls { classify(url) }
    }
  }

  private var stagedFiles: some View {
    VStack(alignment: .leading, spacing: 4) {
      staged("Certificate", present: certificatePEM != nil)
      staged("Private key", present: privateKeyPEM != nil)
    }
  }

  private func staged(_ label: String, present: Bool) -> some View {
    Label {
      Text(label).font(.caption)
    } icon: {
      Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(present ? StatusTone.good.tint : Color.secondary)
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    switch status {
    case .idle:
      EmptyView()
    case .installed(let expires):
      Label {
        // A self-signed certificate this server generated records an expiry; one the
        // user installed does not, and saying so is how they can tell which is in use.
        Text(
          expires.map {
            "Installed. This server generated it; it expires "
              + $0.formatted(date: .abbreviated, time: .omitted) + "."
          } ?? "Installed. This is your own certificate; the server will not replace it."
        )
        .font(.caption)
      } icon: {
        Image(systemName: "checkmark.seal.fill").foregroundStyle(StatusTone.good.tint)
      }
    case .failed(let reason):
      ErrorLine(reason, size: .compact)
    }
  }

  private var actions: some View {
    HStack {
      Button("Install") { install() }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(certificatePEM == nil || privateKeyPEM == nil || isInstalling)

      Spacer()

      // No "Reveal in Finder". There is no file to reveal: the certificate lives in
      // the Keychain, and `Certs/` is read once to adopt what an older build left there and
      // then removed. A button that opened an empty folder would be worse than its absence.
    }
  }

  // MARK: - Handling files

  /// Decides which file is which by reading it.
  ///
  /// Not by extension and not by drop order. A certificate and a key are both PEM and look
  /// the same to anyone who has not seen one before; installing them the wrong way round
  /// fails the handshake with nothing useful reported anywhere.
  private func classify(_ url: URL) {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      status = .failed("\(url.lastPathComponent) could not be read.")
      return
    }
    if contents.contains("PRIVATE KEY-----") {
      privateKeyPEM = contents
    } else if contents.contains("BEGIN CERTIFICATE-----") {
      certificatePEM = contents
    } else {
      status = .failed(
        "\(url.lastPathComponent) is not a PEM file. It should start with -----BEGIN."
      )
    }
  }

  private func install() {
    guard let certificatePEM, let privateKeyPEM else { return }
    let material = CertificateStore.Material(
      certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM)

    // Refused rather than half-done. The Keychain is the only store, so with no
    // server there is nowhere to put this: writing the files instead would produce a
    // certificate that the next start adopts and the user never sees confirmed.
    guard let keychain = model.security.certificates, model.settings.isAvailable else {
      status = .failed(
        "The server is not running, so the certificate cannot be stored. Start it and "
          + "import again.")
      return
    }

    isInstalling = true
    Task {
      defer { isInstalling = false }
      do {
        // `install` verifies by reading back and throws otherwise, so reaching the next line
        // means the server will find this on its next start, which is what makes it safe to
        // clear the files below rather than leave a second copy nothing keeps current.
        try await keychain.install(material)

        // Anything an older build left in `Certs/` is superseded, including the
        // `expiration.txt` marker whose absence encodes "the user installed this".
        // Leaving it would let the adoption path read a stale certificate back in.
        store.clear()

        // Provenance last, once the material is definitely stored. Recording "the user's own"
        // before it is there would describe a certificate that does not exist, and the value
        // that matters is the one that stops the renewer replacing it.
        // `@Sendable` because the batch crosses into the store's actor. Zero for the expiry,
        // not the certificate's real one: this is the RENEWAL clock, and an imported
        // certificate is never renewed by us: watching its expiry is the user's job, and
        // writing a real date here would invite the renewer to act on it.
        let record: @Sendable (inout SettingsBatch) throws -> Void = { batch in
          try batch.set(
            BBSettings.Settings.tlsCertificateOrigin,
            to: TLSCertificateOrigin.imported.rawValue)
          try batch.set(BBSettings.Settings.tlsCertificateExpiresAt, to: 0)
        }
        try await model.settings.write(record)

        self.certificatePEM = nil
        self.privateKeyPEM = nil
        status = .installed(expires: nil)
      } catch {
        status = .failed(DiagnosticText.sentence(for: error))
      }
    }
  }

  private func refreshStatus() {
    // The Keychain is where the server reads from, so it decides whether a certificate is
    // installed. Disk is consulted only as the fallback: the same order `TLSProvisioning`
    // uses, so this screen cannot report "none" for a server that is happily serving TLS.
    Task {
      // A glance at the renewal date, not the content: with no server it is unknown, and the
      // status below says why on its own.
      expiresAtSeconds = try? await model.settings.get(
        BBSettings.Settings.tlsCertificateExpiresAt)
      if let keychain = model.security.certificates, await keychain.exists() {
        status = .installed(expires: recordedExpiry())
        return
      }
      guard store.exists else {
        status = .idle
        return
      }
      status = .installed(expires: recordedExpiry() ?? store.recordedExpiration())
    }
  }

  /// The renewal date, or nil for a certificate the user installed.
  ///
  /// Read from the recorded provenance rather than from `expiration.txt`: no marker file is
  /// written for material that lives in the Keychain, and nil is what the UI shows
  /// as "yours, and not ours to renew".
  private func recordedExpiry() -> Date? {
    guard let seconds = expiresAtSeconds, seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
  }
}
