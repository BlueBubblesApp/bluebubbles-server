# private-api tools

Five tools for reading Apple's private frameworks on the Mac you are sitting at.

```
dump-headers.sh    write docs/headers/macos-<version>/ from the classes on this Mac
probe.sh           search every loaded class for a name, or check what a class exposes
notifications.sh   list the NSNotification names a framework posts
trace.sh           read what a private method actually does, without its source
collect.sh         run the dump, describe this Mac, and produce an archive to send back
```

Every one is read-only. They introspect frameworks and disassemble; they never call an
Apple method, and they never open a file in your home directory.

To produce a header dump for the macOS release this Mac is running, one command:

```bash
./collect.sh
```

**Full documentation is in [`docs/private-api/`](../../docs/private-api/).**

| | |
|---|---|
| [Collecting headers](../../docs/private-api/collecting-headers.md) | what a header dump is, how to produce one, how to read it |
| [The host apps](../../docs/private-api/host-apps.md) | Messages, FaceTime, FindMy: sandbox, containers, injection |
| [Tool reference](../../docs/private-api/tools.md) | every tool, every flag, worked examples |
| [macOS version notes](../../docs/private-api/macos-versions.md) | what differs between Sonoma and Tahoe, and what breaks |

`hosts.conf` is the list of classes to dump. Adding one is a one-line change and needs no
shell — see the comment block at the top of the file.
