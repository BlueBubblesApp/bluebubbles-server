#  swift-runtime.sh
#  Puts the Swift libraries a bundle needs, and the oldest supported macOS lacks, inside the
#  bundle, and fails the build on any dependency the bundle cannot satisfy by itself.
#  Sourced by the bundle scripts, never run.
#
#  The linker writes an ABSOLUTE `/usr/lib/swift/…` load command for every Swift library the
#  OS already has at the deployment target, and an `@rpath/…` one for a library that is newer
#  than the deployment target. Those are back-deployment libraries, and the app must ship them:
#  `libswiftCompatibilitySpan.dylib` is part of the OS from macOS 26, so on Sonoma and Sequoia
#  only the app itself can provide it. Xcode copies them in (its `swift-stdlib-tool` step);
#  SwiftPM does not, and these bundles are assembled from SwiftPM output. Without this step the
#  app and the CLI die in dyld on macOS 14 and 15 with "Library not loaded:
#  @rpath/libswiftCompatibilitySpan.dylib", before any of our code runs.
#
#  A build machine cannot show the failure, for two reasons. On macOS 26 and later the library
#  is in the shared cache at `/usr/lib/swift`, which is the first rpath. And SwiftPM also links
#  an rpath to the toolchain's own copy, so on any Mac with that Xcode installed dyld finds the
#  library there, whatever the OS version.
#
#  So `bb_bundle_swift_runtime` does two things to every Mach-O we built:
#    - copies every `@rpath/libswift*.dylib` it names from the toolchain into its enclosing
#      `.app`'s `Contents/Frameworks`. That binary's `@executable_path/../Frameworks` rpath
#      (Package.swift) finds the copy. `/usr/lib/swift` stays first, so macOS 26 and later
#      still load their own copy;
#    - deletes every absolute rpath other than `/usr/lib/swift`, since each one names a
#      directory on the build machine. Otherwise which copy loads depends on whether the user
#      has Xcode installed, and which version.
#  It then resolves every `@rpath/` dependency of every Mach-O in the bundle against the rpaths
#  that point INSIDE the bundle, and fails the build on any it cannot find. That check is the
#  point of the file. It reads the load commands, not a list of names, so the next
#  back-deployment library fails the same check.

# No shebang: this file is sourced, never executed.
# shellcheck shell=bash

# bb_bundle_swift_runtime APP
#
# Embeds, scrubs and checks APP as described above. Call it once every binary and framework is
# in place and before anything is signed: `install_name_tool` invalidates a signature.
# Sparkle.framework is left alone: it is a vendor build with no Swift runtime dependency, and
# rewriting it would break the vendor's seal for no gain. The self-containment check still
# covers it.
bb_bundle_swift_runtime() {
    local app="$1" file owner name source rpath built=()
    [ -d "$app" ] || { echo "error: bb_bundle_swift_runtime: no bundle at '$app'" >&2; return 1; }

    # Collected first, so the libraries copied below are not walked as if we had built them.
    while IFS= read -r file; do
        built+=("$file")
    done < <(_bb_macho_files "$app" | grep -v '/Sparkle\.framework/')

    # The `+` form because bash 3.2 under `set -u` calls an empty array unbound.
    for file in ${built[@]+"${built[@]}"}; do
        # The `.app` the binary belongs to: the outer one for the injected helpers, the
        # nested one for the CLI. Each `.app` has its own `Contents/Frameworks`, because
        # `@executable_path` is the running executable, not the outer app.
        owner="${file%/Contents/*}"
        for name in $(_bb_rpath_dependencies "$file" | sed -n 's|^@rpath/\(libswift[^/]*\.dylib\)$|\1|p'); do
            source="$(_bb_toolchain_swift_library "$name")" || {
                echo "error: ${file#"$app"/} needs @rpath/$name, and the toolchain has no macOS" >&2
                echo "error: copy of it to embed. On macOS 14 and 15 dyld would abort at launch." >&2
                return 1
            }
            mkdir -p "$owner/Contents/Frameworks" || return 1
            if [ ! -f "$owner/Contents/Frameworks/$name" ]; then
                cp "$source" "$owner/Contents/Frameworks/$name" || return 1
                chmod u+w "$owner/Contents/Frameworks/$name" || return 1
                echo "==> Bundled $name into ${owner#"$app"}/Contents/Frameworks"
            fi
        done
        while IFS= read -r rpath; do
            case "$rpath" in
                @* | /usr/lib/swift) continue ;;
            esac
            install_name_tool -delete_rpath "$rpath" "$file" 2>/dev/null || return 1
            echo "==> Removed the build-machine rpath $rpath from ${file#"$app"/}"
        done < <(_bb_rpaths "$file")
    done

    bb_assert_bundle_self_contained "$app"
}

# bb_assert_bundle_self_contained APP
#
# Fails when a Mach-O anywhere in APP has an `@rpath/` dependency that no rpath pointing inside
# APP resolves. Absolute rpaths do not count, `/usr/lib/swift` included: anything the OS has at
# the deployment target is linked by absolute path, so an `@rpath/` dependency is by definition
# one the OS may not have. `@executable_path` is the file itself for an executable and the
# outer app's executable for a library, which is the process that loads every library here
# except the injected helpers, and neither helper has an `@executable_path` rpath.
bb_assert_bundle_self_contained() {
    local app="$1" file executable dependency rpath candidate found failures=0
    local main="$app/Contents/MacOS/BlueBubbles"
    while IFS= read -r file; do
        # A `case` on the output rather than a pipe into `grep -q`: under `pipefail` an
        # early-exiting `grep` can SIGPIPE `file` and turn a match into a failure.
        case "$(file -b "$file")" in
            *executable*) executable="$file" ;;
            *) executable="$main" ;;
        esac
        while IFS= read -r dependency; do
            [[ "$dependency" == @rpath/* ]] || continue
            found=0
            while IFS= read -r rpath; do
                case "$rpath" in
                    @executable_path*) candidate="$(dirname "$executable")${rpath#@executable_path}" ;;
                    @loader_path*) candidate="$(dirname "$file")${rpath#@loader_path}" ;;
                    *) continue ;;
                esac
                if [ -e "$candidate/${dependency#@rpath/}" ]; then
                    found=1
                    break
                fi
            done < <(_bb_rpaths "$file")
            if [ "$found" -eq 0 ]; then
                echo "error: ${file#"$app"/} needs $dependency, and nothing inside the bundle provides it." >&2
                failures=$((failures + 1))
            fi
        done < <(_bb_rpath_dependencies "$file")
    done < <(_bb_macho_files "$app")
    if [ "$failures" -gt 0 ]; then
        echo "error: $failures dependency(ies) resolve only on the build machine; on a Mac without" >&2
        echo "error: this Xcode, or on macOS 14 and 15, dyld aborts at launch. A Swift library is" >&2
        echo "error: embedded by bb_bundle_swift_runtime; a binary that needs one also needs the" >&2
        echo "error: @executable_path/../Frameworks rpath on its target in Package.swift." >&2
        return 1
    fi
    echo "==> Every @rpath dependency resolves inside the bundle"
}

# Every Mach-O file under DIR, one path per line.
_bb_macho_files() {
    local file
    while IFS= read -r file; do
        case "$(file -b "$file")" in
            *Mach-O*) printf '%s\n' "$file" ;;
        esac
    done < <(find "$1" -type f)
}

# The libraries FILE loads that are named relative to an rpath or a load path, one per line,
# without the version suffix `otool` prints. Read from the load commands rather than from
# `otool -L`, whose first line for a library is the library's OWN install name.
_bb_rpath_dependencies() {
    otool -l "$1" | awk '
        $1 == "cmd" { load = ($2 ~ /^LC_(LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD|LAZY_LOAD)_DYLIB$/); next }
        load && $1 == "name" {
            sub(/^[[:space:]]*name /, ""); sub(/ \(offset [0-9]+\)$/, "")
            if ($0 ~ /^@/) print
            load = 0
        }' | sort -u
}

# FILE's LC_RPATH entries, one per line. Deduplicated: a universal binary lists each per slice.
_bb_rpaths() {
    otool -l "$1" | awk '
        $1 == "cmd" { want = ($2 == "LC_RPATH"); next }
        want && $1 == "path" {
            sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, "")
            print
            want = 0
        }' | sort -u
}

# The selected toolchain's macOS copy of the Swift library NAME. The back-deployment libraries
# sit in `lib/swift-<version>/macosx`, the version being the release that added them to the OS.
_bb_toolchain_swift_library() {
    local usr dir
    usr="$(cd "$(dirname "$(xcrun --find swift)")/.." && pwd)" || return 1
    for dir in "$usr"/lib/swift-*/macosx "$usr/lib/swift/macosx"; do
        if [ -f "$dir/$1" ]; then
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done
    return 1
}
