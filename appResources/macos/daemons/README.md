# Signature Verification

The `.md5` files within this directory contain a single string that is correlated to the official MD5 hash for each of the daemons. You can verify the signature by executing the following command:

`md5 /path/to/daemon/executable`

## Clourflared

This is the official cloudflare daemon, downloaded from: https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz

The dummy `cloufldared-config.yml` file is for the daemon to use as to not interfere with the default system configuration