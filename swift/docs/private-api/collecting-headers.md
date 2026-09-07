# Collecting headers

How to produce a header dump for a macOS release, and what to do with it.

A dump takes about five minutes and requires no special configuration of the machine. The
result is a set of `.h` files describing the private Apple APIs available on that release,
checked in under `docs/headers/macos-<version>/`.

## Background

Skip this if you already know how Objective-C runtime introspection works.

BlueBubbles reaches iMessage features Apple never made public — reactions, editing, typing
indicators, group management — by loading a library into Messages.app and calling **IMCore**,
one of Apple's private frameworks. Private means undocumented and unstable: Apple adds,
renames and removes methods between macOS releases with no announcement.

There are no header files for these frameworks. But Objective-C keeps its type information
at runtime, and that information is queryable by any process that has the framework loaded:

```objc
Method *methods = class_copyMethodList(NSClassFromString(@"IMChat"), &count);
```

`dump-headers.m` does exactly that and formats the answer as a `.h` file. A few terms that
appear throughout:

| Term | Meaning |
|---|---|
| **selector** | a method name, e.g. `setDisplayName:`. The trailing colons count arguments |
| **class dump** | reconstructing a header from runtime type information, as here |
| **dyld shared cache** | one large file holding every system framework. Private frameworks have no separate binary on disk; they exist only here |
| **Mac Catalyst** | iOS frameworks running on macOS. Messages.app is built this way, which matters — see [macOS version notes](macos-versions.md#two-copies-of-imcore) |

What this gives you is a list of **names** — classes, methods, properties — that describe
macOS itself. There is no user data anywhere in the output.

## Requirements

- macOS **14 (Sonoma) or newer**, Intel or Apple Silicon
- Xcode, or the Command Line Tools: `xcode-select --install`

Not required: System Integrity Protection disabled, Full Disk Access, an installed copy of
BlueBubbles, or root. Nothing in this process modifies the system.

## Producing a dump

```bash
git clone https://github.com/BlueBubblesApp/bluebubbles-server.git
cd bluebubbles-server/swift/Tools/private-api
./collect.sh
```

Output:

```
==> Dumping headers for macOS 15.6.1 (arm64)
==> Writing environment.txt

Done. 63 headers, 84K.

  /Users/you/Desktop/bluebubbles-headers-macos-15.6.1-arm64.tar.gz
```

`collect.sh` runs `dump-headers.sh`, records what the machine is, and packages both. To
write straight into the repository instead of producing an archive, add `--keep`.

## What the archive contains

Everything in it is plain text and small enough to read.

```bash
tar -tzf ~/Desktop/bluebubbles-headers-macos-*.tar.gz     # list contents
tar -xzf ~/Desktop/bluebubbles-headers-macos-*.tar.gz     # extract
```

**`*.h`** — Objective-C class, method, property and protocol names from Apple's frameworks.
These describe macOS. A representative line:

```objc
- (void)setTranscriptBackgroundAndSendToChat:(id)arg0 transferID:(id)arg1;
```

**`environment.txt`** — macOS version and build, CPU architecture, Mac model, Xcode and
clang versions, and for each app examined: its version and whether it is a Catalyst or
native binary. It ends with the list of classes that do **not** exist on this release, which
is usually the most immediately useful part of a dump.

The tools read type information out of frameworks they load into their own short-lived
process. They do not open the Messages database, contacts, notes, attachments, location
data, or any file in a home directory, and they emit no file contents of any kind.

## Contributing a dump

Dumps are checked in one directory per release:

```bash
./collect.sh --keep
git add swift/docs/headers/macos-<version>
```

Commit the whole directory, `environment.txt` included — it records the machine the dump
came from, which is what makes the files interpretable later. Then open a pull request, or
attach the archive to a GitHub issue if you would rather not open one.

## Reading the result

The value of a dump is in the comparison, not the dump itself:

```bash
diff -r swift/docs/headers/macos-15.6.1 swift/docs/headers/macos-26.5.2
```

Every line of that diff is a place the Private API may behave differently between the two
releases. A selector present in one and absent in the other is precisely where a feature
breaks, and finding it this way takes minutes rather than the days it takes to work backwards
from a report of "reactions stopped working after I updated".

A class that does not exist is recorded rather than skipped:

```objc
// IMMutedChatList is NOT PRESENT on this system.
```

That line is an answer, not a failure. See [macOS version notes § When a class is
missing](macos-versions.md#when-a-class-is-missing) for how to tell a genuine removal from a
framework that simply was not loaded.

## Troubleshooting

**`error: could not build probe.m for Mac Catalyst`**

The Command Line Tools alone are sometimes insufficient. Install Xcode and point the
toolchain at it:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

**`error: macOS 13.x is older than the supported floor`**

macOS 14 (Sonoma) is the oldest release these tools are validated against. To run anyway:

```bash
PA_ALLOW_OLD_MACOS=1 ./collect.sh
```

Note the override when contributing the result, so the dump is not later read as validated.

**`warning: could not load …`**, possibly many

Expected. Apple moves and removes private frameworks between releases, so a framework that
is absent is itself a finding. The dump completes and records what was missing.

**Anything else**

The full terminal output is the useful part of a bug report here — a tool that fails on a
release is the thing worth knowing about.
