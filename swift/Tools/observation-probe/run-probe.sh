#!/usr/bin/env bash
#
# Builds the observation probe, injects it into Messages.app, and tails its log.
#
# What this does to your machine, stated plainly:
#   - Quits Messages.app and relaunches it with DYLD_INSERT_LIBRARIES pointing at the probe.
#   - The probe OBSERVES ONLY. It installs no swizzles, mutates nothing, sends nothing, and
#     writes only to a log file under Messages.app's container.
#   - Quitting the relaunched Messages and opening it normally undoes everything. There is
#     nothing to uninstall.
#
# Requires SIP disabled, for the same reason the Private API does: library validation
# otherwise refuses to load an unsigned dylib into an Apple-signed process.
#
# Two things about this are non-obvious and cost an afternoon to find, so they are enforced
# here rather than left to the reader:
#
#   1. ARCHITECTURE. On Apple Silicon, Messages.app runs its arm64e slice. A plain arm64
#      dylib CANNOT be loaded into an arm64e process: dyld skips the inserted library,
#      prints one line to stderr, and lets the process run normally. The symptom is a probe
#      that appears to work and logs absolutely nothing. This is also why the shipping
#      BlueBubblesHelper.dylib is universal with an arm64e slice.
#
#   2. THE LOG PATH. Messages.app is sandboxed, so inside it "~/Library/Logs" resolves to
#      ~/Library/Containers/com.apple.MobileSMS/Data/Library/Logs. The probe's log is there,
#      not in the obvious place. Tailing the obvious place shows you an empty file forever.
#
# Usage:
#   ./run-probe.sh              build, inject, tail
#   ./run-probe.sh --build-only build and stop
#   ./run-probe.sh --summary    ask a running probe to write its summary now
#   ./run-probe.sh --log        print the path to the log and exit
#   ./run-probe.sh --restore    quit the instrumented Messages and reopen it normally

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESSAGES="/System/Applications/Messages.app/Contents/MacOS/Messages"

# Messages is sandboxed; its "~" is its container. See note 2 above.
CONTAINER="$HOME/Library/Containers/com.apple.MobileSMS/Data"
LOG="$CONTAINER/Library/Logs/bluebubbles-server/observation-probe.log"

# Where dyld's complaints go when the injection fails. Never /dev/null: the one line that
# explains an architecture mismatch is printed here and nowhere else.
STDERR_LOG="$HERE/.build/messages-stderr.log"

# The slice Messages will actually run as, which is the slice the probe must be built for.
case "$(uname -m)" in
  arm64)  PROBE_ARCH="arm64e" ;;
  x86_64) PROBE_ARCH="x86_64" ;;
  *)      echo "error: unsupported host architecture $(uname -m)" >&2; exit 1 ;;
esac
DYLIB="$HERE/.build/$PROBE_ARCH-apple-macosx/release/libObservationProbe.dylib"

fail() { echo "error: $*" >&2; exit 1; }

check_sip() {
  local status
  status="$(csrutil status 2>/dev/null || echo unknown)"
  if [[ "$status" == *"enabled"* ]]; then
    cat >&2 <<'EOF'
error: System Integrity Protection is enabled.

Library validation will refuse to load an unsigned dylib into Messages.app, so injection
cannot work. This is the same requirement the Private API has.

To disable it: boot into Recovery (hold the power button on Apple Silicon, Cmd-R on Intel),
open Terminal, run `csrutil disable`, and reboot. Re-enable with `csrutil enable` when you
are finished investigating.

Everything else in the server works with SIP enabled. Only this does not.
EOF
    exit 1
  fi
  echo "SIP: $status"
}

case "${1:-}" in
  --summary)
    pid="$(pgrep -x Messages || true)"
    [[ -n "$pid" ]] || fail "Messages is not running"
    kill -USR1 "$pid"
    echo "Asked the probe to summarize. Check the tail of:"
    echo "  $LOG"
    exit 0
    ;;
  --log)
    echo "$LOG"
    exit 0
    ;;
  --restore)
    osascript -e 'quit app "Messages"' 2>/dev/null || true
    sleep 2
    open -a Messages
    echo "Messages relaunched without the probe."
    exit 0
    ;;
esac

echo "==> Building the probe for $PROBE_ARCH (the slice Messages runs)"
swift build --package-path "$HERE" -c release --arch "$PROBE_ARCH"
[[ -f "$DYLIB" ]] || fail "expected the dylib at $DYLIB"

# Assert rather than assume. A probe built for the wrong slice fails silently at inject time,
# which is the single most expensive failure mode this tool has.
built_arch="$(lipo -archs "$DYLIB")"
[[ "$built_arch" == *"$PROBE_ARCH"* ]] \
  || fail "built $built_arch but Messages needs $PROBE_ARCH"
echo "    $DYLIB ($built_arch)"

if [[ "${1:-}" == "--build-only" ]]; then
  exit 0
fi

check_sip

echo "==> Marking a run boundary in the log"
mkdir -p "$(dirname "$LOG")"
{
  echo ""
  echo "#################################################################"
  echo "# run started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "# probe  $PROBE_ARCH"
  echo "#################################################################"
} >> "$LOG"

echo "==> Quitting Messages"
osascript -e 'quit app "Messages"' 2>/dev/null || true
# Messages takes a moment to actually exit, and relaunching too early gets you the old
# process back without the probe loaded.
for _ in $(seq 1 20); do
  pgrep -x Messages >/dev/null || break
  sleep 0.5
done
pgrep -x Messages >/dev/null && fail "Messages would not quit; quit it by hand and retry"

echo "==> Relaunching with the probe injected"
DYLD_INSERT_LIBRARIES="$DYLIB" "$MESSAGES" >"$STDERR_LOG" 2>&1 &

# The check that matters. Messages running proves nothing: when dyld rejects an inserted
# library it carries on without it, so "the app launched" and "the probe is loaded" are
# entirely different claims.
#
# Polled rather than slept-on. vmmap has to attach to the target, and against a Messages that
# is still working through its own startup that attach can fail — which looks identical to a
# rejected library if you only ask once.
pid=""
loaded=""
for _ in $(seq 1 20); do
  sleep 1
  pid="$(pgrep -x Messages || true)"
  [[ -n "$pid" ]] || continue
  if vmmap "$pid" 2>/dev/null | grep -q libObservationProbe.dylib; then
    loaded="yes"
    break
  fi
done

if [[ -z "$pid" ]]; then
  echo "error: Messages exited immediately. Its output:" >&2
  sed 's/^/    /' "$STDERR_LOG" >&2
  exit 1
fi

if [[ -z "$loaded" ]]; then
  cat >&2 <<EOF
error: Messages is running but the probe was NOT loaded.

dyld declined the inserted library and let Messages start without it. Its output:
EOF
  sed 's/^/    /' "$STDERR_LOG" >&2
  cat >&2 <<EOF

Most likely causes, in order:
  - Architecture mismatch. Messages needs $PROBE_ARCH; the dylib is $(lipo -archs "$DYLIB").
  - Library validation. SIP must be disabled AND:
      sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist \\
        DisableLibraryValidation -bool true
EOF
  exit 1
fi

echo "    probe loaded into Messages (pid $pid)"

cat <<EOF

==> Probe is running.

Now perform the actions from docs/OBSERVATION_LADDER.md, noting the time of each:

  1. Have someone start typing to you, then stop.
  2. Send yourself a message from another device.
  3. Mark a conversation read on another device.
  4. If you use FindMy sharing, wait for a location update.

Then run:  $0 --summary
And read:  $LOG

Tailing now. Ctrl-C to stop tailing (the probe keeps running).

EOF

tail -f "$LOG"
