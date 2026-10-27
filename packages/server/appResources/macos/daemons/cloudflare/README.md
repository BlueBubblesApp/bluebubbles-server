# cloudflared

Bundled version: [2026.10.4](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.4).
This updates the bundled client following [Cloudflare's eMudhra advisory](https://blog.cloudflare.com/emudhra-certificate-compromise/).

The executables are extracted from Cloudflare's official macOS release archives:

- `arm64/cloudflared` (Apple Silicon): [cloudflared-darwin-arm64.tgz](https://github.com/cloudflare/cloudflared/releases/download/2026.10.4/cloudflared-darwin-arm64.tgz)
- `x86/cloudflared` (Intel x86_64): [cloudflared-darwin-amd64.tgz](https://github.com/cloudflare/cloudflared/releases/download/2026.10.4/cloudflared-darwin-amd64.tgz)

## Verification

From this directory, verify the extracted executables against `SHA256SUMS`:

```sh
shasum -a 256 -c SHA256SUMS
```

These SHA-256 values match the extracted executables, not the compressed archives.
They are published on the linked Cloudflare release under the archive filenames.
The archives' separate SHA-256 digests are available in GitHub's release asset metadata.
The existing `.md5` files are retained as legacy checksums; MD5 is not a signature or an authenticity check.

The executables retain Cloudflare's Developer ID signatures (team `68WVV388M8`).
On macOS, verify both the signature and signing team with:

```sh
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "68WVV388M8"' arm64/cloudflared
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "68WVV388M8"' x86/cloudflared
```

Both executables declare a macOS 15.0 minimum deployment target, as did the previously bundled 2025.5.0 executables.

The `cloudflared-config.yml` file isolates the bundled daemon from the user's default cloudflared configuration.
