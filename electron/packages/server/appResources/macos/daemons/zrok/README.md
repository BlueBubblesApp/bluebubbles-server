# `zrok` daemon

This is version 1.0.2 of the official `zrok` daemon, which can be downloaded from [their GitHub repository](https://github.com/openziti/zrok/releases/tag/v1.0.2).

## Signature Verification

The `checksums.sha256.txt` files on the [zrok releases page](https://github.com/openziti/zrok/releases) cannot be directly used to verify the executables included in this project because the hashes are computed on the compressed release archive and not the executable. To verify these executables, download the [x86-1.0.2 release](https://github.com/openziti/zrok/releases/download/v1.0.2/zrok_1.0.2_darwin_amd64.tar.gz) and the [arm64-1.0.2 release](https://github.com/openziti/zrok/releases/download/v1.0.2/zrok_1.0.2_darwin_arm64.tar.gz) and extract them.

Next, compute the hashes for the executables included in this project.

```sh
sha256sum x86/zrok
sha256sum arm64/zrok
```

Finally, perform similar commands to compute the hashes for the official release executables and verify they are identical.
