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

And three more for the releases this Mac is not running, which are dumped in a VM:

```
vm-share.sh        build the folder a VM runs the dump out of
dump-headers-vm.sh the runner that folder gets; not run from here
import-dump.sh     file what the VM produced under docs/headers/
```

A dump taken on this Mac and filed as Sonoma is worse than no dump at all, so the release is
checked twice: `dump-headers-vm.sh` refuses to run on a machine that is not the one its
folder names, and `import-dump.sh` takes the release from the dump's own `environment.txt`
rather than from the directory it arrived in. The round trip:

```bash
./vm-share.sh Sonoma Sequoia                    # here, before every dump
# in each VM: open the shared folder, then  bash dump-headers-vm.sh
./import-dump.sh                                # here, afterwards
```

`vm-share.sh` is not optional housekeeping. The share holds a **copy** of `hosts.conf`, and a
copy that predates a class you added dumps the old list: the new class comes back with no
header, which is indistinguishable from a class the release does not have.

**Full documentation is in [`docs/private-api/`](../../docs/private-api/).**

| | |
|---|---|
| [Collecting headers](../../docs/private-api/collecting-headers.md) | what a header dump is, how to produce one, how to read it |
| [The host apps](../../docs/private-api/host-apps.md) | Messages, FaceTime, FindMy: sandbox, containers, injection |
| [Tool reference](../../docs/private-api/tools.md) | every tool, every flag, worked examples |
| [macOS version notes](../../docs/private-api/macos-versions.md) | what differs between Sonoma and Tahoe, and what breaks |

`hosts.conf` is the list of classes to dump. Adding one is a one-line change and needs no
shell; see the comment block at the top of the file.
