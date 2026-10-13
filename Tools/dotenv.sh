#  dotenv.sh
#  Loads `.env` from the CURRENT WORKING DIRECTORY into the environment. Sourced, never run.
#
#  A `.env` file is a convention, not a shell feature: nothing loads it unless something is
#  written to load it. That is worth stating because the failure is silent in both directions.
#  `Tools/dev-bundle.sh` reads `${DEV_SIGNING_IDENTITY:--}` and falls back to ad-hoc signing,
#  so a `.env` nobody read produced an ad-hoc signature, which invalidates every TCC grant on
#  every rebuild — Full Disk Access, Automation, Contacts, all re-prompted — while the build
#  itself succeeded and said nothing a reader would stop at.
#
#  THE CWD, NOT THE SCRIPT'S DIRECTORY. `Packaging/sign-app.sh` and `Tools/dev-bundle.sh` live
#  in different directories and are run from the repository root, so resolving against
#  `${BASH_SOURCE[0]}` would look for `Packaging/.env` and `Tools/.env` and find neither. It
#  also means the file is chosen by where you stand, which is what makes a second checkout
#  able to carry its own.
#
#  THE ENVIRONMENT WINS OVER THE FILE, which is the one rule here that is a decision rather
#  than a convention. `DEV_SIGNING_IDENTITY="…" Tools/dev-bundle.sh` is the documented
#  per-invocation override (`CLAUDE.local.md`), and a file quietly replacing it would break
#  that form for everyone who has ever written a `.env` and forgotten it. A name already
#  present in the environment — even set to empty — is left exactly as it is.
#
#  WHAT IT PARSES: `KEY=value`, with an optional `export ` prefix, `#` comments, blank lines,
#  and one layer of matching single or double quotes. Quoting is what a value containing
#  spaces or parentheses needs: zsh reads `(WPV275H8W7)` in an unquoted value as a glob and
#  aborts the assignment, leaving the variable EMPTY rather than failing, which is the second
#  way this has already gone wrong.
#
#  `$VAR` AND `${VAR}` ARE EXPANDED in unquoted and double-quoted values, and left alone in
#  single-quoted ones, which is what the shell itself does with the same three spellings. Not
#  a flourish: `BB_VM_SHARE="$HOME/Documents/VM Shared"` is the first real line anyone wrote
#  in this file, and exporting `$HOME` literally sent `vm-share.sh` looking for a directory
#  with a dollar sign in its name and reporting the share as missing when it was there.
#
#  Expansion is done by hand, NEVER by `eval`. A `.env` is edited by people and arrives from
#  other machines, and `eval` on its contents would run whatever `$(…)` it happened to
#  contain — a foot-gun that buys nothing, since the only thing wanted here is a variable
#  reference. `$(…)` and backticks are therefore left exactly as written, unexecuted.
#
#  WHAT IT DOES NOT PARSE: multi-line values, and `\n` escapes inside double quotes. Use
#  single quotes for a literal `$`, the same as in a shell.

# No shebang: this file is sourced, never executed.
# shellcheck shell=bash

# `$VAR` and `${VAR}` against the current environment. No `eval`; see the header.
#
# An unset name expands to empty, matching the shell. A `$` that begins no name — the `$(`
# of a command substitution, a bare trailing `$` — is emitted literally, which is what keeps
# this from being an execution path.
bb__expand() {
    local rest="$1" out="" name
    while [ -n "$rest" ]; do
        case "$rest" in
            *'$'*) ;;
            *) break ;;
        esac
        out="$out${rest%%\$*}"
        rest="${rest#*\$}"
        name=""
        case "$rest" in
            '{'*)
                rest="${rest#\{}"
                case "$rest" in
                    *'}'*) name="${rest%%\}*}"; rest="${rest#*\}}" ;;
                    # No closing brace: not a reference, so put it back as written.
                    *) out="$out\${"; continue ;;
                esac
                ;;
            *)
                while [ -n "$rest" ]; do
                    case "$rest" in
                        [A-Za-z0-9_]*) name="$name${rest%"${rest#?}"}"; rest="${rest#?}" ;;
                        *) break ;;
                    esac
                done
                ;;
        esac
        if [ -z "$name" ]; then
            out="$out\$"
        else
            out="$out${!name-}"
        fi
    done
    printf '%s' "$out$rest"
}

# Exports every name in `./.env` that is not already set. Silent when there is no file.
bb_load_dotenv() {
    local file=".env"
    [ -f "$file" ] || return 0

    local line key value
    local exported=0
    local kept=()

    # `|| [ -n "$line" ]` so a final line with no trailing newline is still read. The `.env`
    # that prompted this had exactly that shape.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '' | '#'*) continue ;;
        esac
        case "$line" in
            'export '*) line="${line#export }" ;;
        esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"

        # Not a shell identifier, so there is nothing we could export it as.
        case "$key" in
            '' | [0-9]* | *[!A-Za-z0-9_]*) continue ;;
        esac

        # Single quotes are literal, everything else expands. The shell's own rule.
        case "$value" in
            "'"*"'")
                value="${value#\'}"; value="${value%\'}"
                ;;
            '"'*'"')
                value="${value#\"}"; value="${value%\"}"
                value="$(bb__expand "$value")"
                ;;
            *)
                value="$(bb__expand "$value")"
                ;;
        esac

        # Already in the environment: left alone. See the header.
        if [ -n "${!key+set}" ]; then
            kept+=("$key")
            continue
        fi

        export "$key=$value"
        exported=$((exported + 1))
    done < "$file"

    # A COUNT FOR WHAT LOADED, NAMES FOR WHAT DID NOT. The line exists at all because "my
    # .env is not being picked up" is otherwise invisible: a missing variable and a loaded
    # one look identical right up until something signs ad-hoc.
    #
    # But listing every name on every build publishes an inventory of a file holding a
    # Sparkle signing key and an API key into any log someone pastes into an issue, and the
    # names that loaded are the ones nobody needs to be told about. The names worth printing
    # are the KEPT ones: "I put it in .env and nothing changed" is that case, the shell
    # having exported it earlier, and those names are already in the reader's environment so
    # printing them discloses nothing new. Values are never printed either way.
    if [ "$exported" -gt 0 ] || [ ${#kept[@]} -gt 0 ]; then
        local note="==> .env: exported $exported"
        [ ${#kept[@]} -gt 0 ] && note="$note, kept ${kept[*]} from the environment"
        echo "$note"
    fi
}
