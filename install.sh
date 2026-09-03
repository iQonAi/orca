#!/bin/sh
set -eu

ORCA_URL="${ORCA_URL:-https://github.com/iQonAi/orca.git}"

# Parsed FIRST, before the bootstrap block below. Under `curl | sh -s --
# --uninstall` the piped copy is the ONLY copy that has seen the flag: if it
# re-executed the install.sh already on disk, an older one without this loop
# would silently ignore --uninstall and INSTALL instead - the documented
# uninstall command doing the exact opposite of what it says.
ACTION=install
for arg in "$@"; do
    case "$arg" in
        --uninstall) ACTION=uninstall ;;
        # Rejected rather than ignored: a typo'd flag must not silently run
        # the opposite action of the one that was asked for.
        *) echo "unrecognized option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$ACTION" = uninstall ]; then
    # Every uninstall target is built from $HOME, so it is normalized and
    # vetted HERE - before the bootstrap block below builds its first path
    # from it. `cd`+`pwd` collapses the spellings a pattern match misses
    # (`/.`, `/tmp/..`, a relative or non-existent $HOME) to one canonical
    # form; `//` survives it (POSIX leaves a leading `//` implementation-
    # defined) so it is rejected explicitly. Logical `pwd`, not `pwd -P`: a
    # symlinked $HOME reaches the same files, and rewriting it to the
    # physical path would only make the output unrecognizable to the user.
    # The -n test is load-bearing, not belt-and-braces: `cd ""` SUCCEEDS and
    # stays put, so an empty $HOME would resolve to the caller's cwd and sail
    # through every check below.
    # SC1007: see the CDPATH= note below.
    HOME_DIR=
    if [ -n "${HOME:-}" ]; then
        # shellcheck disable=SC1007
        HOME_DIR=$(CDPATH= cd -- "$HOME" 2>/dev/null && pwd) || HOME_DIR=
    fi
    case "$HOME_DIR" in
        ""|/|//)
            echo "refusing to uninstall: HOME must be a usable directory, not '${HOME-<unset>}'" >&2
            exit 1 ;;
    esac
    HOME=$HOME_DIR
fi

# Trust $0 only when it is a real file: under `curl | sh` $0 is the shell
# name, and resolving it to the cwd would let any directory that happens to
# contain agents/orca.md hijack the install source.
script_dir=
if [ -f "$0" ]; then
   # SC1007: `CDPATH=` is a deliberate env prefix scoped to this one `cd`, not a
   # botched assignment - it stops a user's CDPATH from making `cd` land (and
   # print) somewhere else. The space after `=` is what the idiom requires.
   # shellcheck disable=SC1007
   script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || script_dir=
fi
if [ -z "$script_dir" ] || [ ! -f "$script_dir/agents/orca.md" ]; then
   # Piped (or stray copy): bootstrap durable checkout, then re-execute from it.
   ORCA_REPO="${ORCA_REPO:-$HOME/.local/share/orca}"
   # A quoted ORCA_REPO="~/x" reaches us with a literal tilde - expand it.
   # SC2088 fires on the `"~"` and `"~/"*` case PATTERNS. It is spurious there:
   # a pattern is only ever matched against, never expanded, so there is no
   # expansion to fix. It sits on the `case` and not on the one branch because
   # ShellCheck rejects branch-level directives outright (SC1124).
   # The strip pattern in the second branch is quoted for the same reason the
   # patterns are: unquoted, `${ORCA_REPO#~/}` tilde-expands its OWN pattern to
   # `$HOME/`, never strips the literal `~/`, and resolves "~/x" to "$HOME/~/x"
   # - a directory literally named `~`. That was #24; test/run.sh now covers it.
   # shellcheck disable=SC2088
   case "$ORCA_REPO" in
       "~") ORCA_REPO="$HOME" ;;
       "~/"*) ORCA_REPO="$HOME/${ORCA_REPO#"~/"}" ;;
   esac
   if [ "$ACTION" = uninstall ]; then
       # A teardown never fetches and never re-executes. Not fetching,
       # because uninstall that needs the network (or git) is broken by
       # design, and because `pull` would mutate the very checkout that
       # copy-mode provenance compares against - silently turning orca's own
       # files into "not ours" and leaving them installed. Not re-executing,
       # because the copy on disk may predate --uninstall and would install.
       # The checkout is a read-only reference here, nothing more; without
       # one, links are still verifiable but copies are not.
       [ -f "$ORCA_REPO/agents/orca.md" ] || ORCA_REPO=
   else
       if [ ! -f "$ORCA_REPO/agents/orca.md" ]; then
           command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
           git clone --depth 1 "$ORCA_URL" "$ORCA_REPO"
       else
           # A piped install means "give me current orca" - refresh the clone.
           # A checkout that cannot fast-forward installs what it has.
           git -C "$ORCA_REPO" pull --ff-only -q 2>/dev/null \
             || echo "warn: could not update $ORCA_REPO; installing its current version"
       fi
       exec "$ORCA_REPO/install.sh" "$@"
   fi
else
   ORCA_REPO="$script_dir"
fi

resolve_style() {
    case "${ORCA_STYLE:-}" in claude|agents) STYLE=$ORCA_STYLE; return 0 ;; esac
    if [ -e /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
        printf 'Install orca for which configuration style?\n' >/dev/tty
        printf '  1) claude  - ~/.claude layout, settings.json hook wiring\n' >/dev/tty
        printf '  2) agents  - AGENTS.md convention (Codex/Cursor/Gemini-class)\n' >/dev/tty
        printf 'choice [1/2]: ' >/dev/tty
        read -r ans </dev/tty
        case "$ans" in
           1|claude) STYLE=claude ;;
           2|agents) STYLE=agents ;;
           *) echo "unrecognized choice: $ans" >&2; exit 2 ;;
        esac
    elif [  -d "$HOME/.claude" ]; then
        STYLE=claude
        echo "no tty; detected ~/.claude, installing claude style (set ORCA_STYLE to override)"
    else
        echo "no tty and ORCA_STYLE unset; re-run with ORCA_STYLE=claude or ORCA_STYLE=agents" >&2
        exit 2
    fi
}

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=

backup() { # move an existing target aside, once-per-run dir
    [ -e "$1" ] || [ -L "$1" ] || return 0
    [ -n "$BACKUP_DIR" ] || { BACKUP_DIR="$HOME/.orca-backups/$TS"; mkdir -p "$BACKUP_DIR"; }
    mv "$1" "$BACKUP_DIR/"
    echo "backup: $1 -> $BACKUP_DIR/"
}

install_one() { # $1 src, $2 dst - link by default, ORCA_MODE=copy to copy
    if [ "${ORCA_MODE:-link}" = link ] && [ -L "$2" ] && [ "$(readlink "$2")" = "$1" ]; then
        echo "    ok: $2 (already linked)"; return 0
    fi
    if [ "${ORCA_MODE:-link}" = copy ] && [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"; then
        echo "    ok: $2 (already current)"; return 0
    fi
   backup "$2"
  if [ "${ORCA_MODE:-link}" = link ]; then ln -s "$1" "$2"; else cp "$1" "$2"; fi
  echo "    installed: $2"
}

install_claude() {
    CH="${CLAUDE_HOME:-$HOME/.claude}"
    mkdir -p "$CH/agents" "$CH/hooks" "$CH/scripts"
    install_one "$ORCA_REPO/agents/orca.md"     "$CH/agents/orca.md"
    install_one "$ORCA_REPO/hooks/orca-start-watcher.sh" "$CH/hooks/orca-start-watcher.sh"
    install_one "$ORCA_REPO/scripts/gh-watch.sh" "$CH/scripts/gh-watch.sh"
    wire_claude_hook "$CH/settings.json"
}

wire_claude_hook() {
    # The default install keeps the ~ form so the entry matches (and dedupes
    # against) ones written by hand or by older installers; a custom
    # CLAUDE_HOME must be spelled out or the wired path points at nothing.
    if [ "$CH" = "$HOME/.claude" ]; then
        # SC2088: the tilde must survive UNEXPANDED - this string is written
        # into settings.json for the harness to read, and the `~` form is what
        # makes the entry dedupe against hand-written ones (see comment above).
        # shellcheck disable=SC2088
        hook_cmd='~/.claude/hooks/orca-start-watcher.sh'
    else
        hook_cmd="$CH/hooks/orca-start-watcher.sh"
    fi
    if ! command -v jq >/dev/null 2>&1; then
       echo "    ! jq not found - add this to $1 under hooks.SessionStart yourself:"
       echo "    {\"hooks\":[{\"type\":\"command\",\"command\":\"$hook_cmd\"}]}"
       return 0
    fi
    entry=$(jq -nc --arg c "$hook_cmd" '{hooks:[{type:"command",command:$c}]}')
   created=0
   [ -f "$1" ] || { printf '{}' > "$1"; created=1; }
   if jq -e --argjson e "$entry" '.hooks.SessionStart // [] | any(. == $e)' "$1" >/dev/null; then
      echo "    ok: SessionStart hook already wired"; return 0
   fi
  # backup() moved it; work on a restored copy. A file we just created has
  # nothing worth backing up.
  if [ "$created" = 0 ]; then backup "$1"; cp "$BACKUP_DIR/settings.json" "$1"; fi
 tmp=$(mktemp)
 jq --argjson e "$entry" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$e])' "$1" > "$tmp"
 mv "$tmp" "$1"
 echo "    wired: SessionStart hook in $1"
}

install_agents() {
    BIN="${ORCA_BIN:-$HOME/.local/bin}"
    mkdir -p "$BIN" "$HOME/.config/orca"
    install_one "$ORCA_REPO/scripts/gh-watch.sh" "$BIN/gh-watch"
    install_one "$ORCA_REPO/agents/orca.md" "$HOME/.config/orca/AGENTS.md"
    echo "  note: point your agent at ~/.config/orca/AGENTS.md (e.g. append it to ~/.codex/AGENTS.md)."
    echo "  note: the SessionStart autostart hook is Claude-specific and was not installed;"
    echo "        launch 'gh-watch <owner>/<repo>' yourself per the playbook."
}

# --- uninstall ---------------------------------------------------------------
#
# Reverses what this installer creates, and nothing else. Every path is
# provenance-checked before it is touched: anything that is not what the
# installer would have written is the user's, and is reported instead of
# removed. Both styles are swept on every run - each path is checked on its
# own merits, so uninstall needs no style prompt and is idempotent.

installer_made() { # $1 dst, $2 source path inside the repo
    #   0 = the installer made this   1 = not ours   2 = cannot tell
    if [ -L "$1" ]; then
        # link mode: ours only if it points at <an orca checkout>/$2. The
        # exact-$ORCA_REPO case is the normal install; the suffix case lets a
        # piped uninstall still recognize a link made from a different
        # checkout, without accepting a link that merely happens to sit here.
        target=$(readlink "$1")
        if [ -n "$ORCA_REPO" ] && [ "$target" = "$ORCA_REPO/$2" ]; then
            return 0
        fi
        case "$target" in
            # Anchored at `/`: install only ever writes ABSOLUTE links, and an
            # unanchored `*/"$2"` would resolve a relative target like
            # `./agents/orca.md` against the UNINSTALLER's cwd - so a user's
            # own relative link would be "verified" by the checkout the
            # command was merely run from, and deleted. Anchoring keeps the
            # test on the link itself, not on where we happen to stand.
            /*/"$2")
                root=${target%"/$2"}
                if [ -f "$root/agents/orca.md" ] && [ -f "$root/install.sh" ]; then
                    return 0
                fi
                return 1 ;;
        esac
        return 1
    fi
    # copy mode: ours only if byte-identical to the source it was copied from.
    # A file the user wrote or edited is theirs and stays.
    [ -f "$1" ] || return 1
    # No checkout to compare against (piped uninstall on a machine that has
    # none). Guessing either way is worse than saying so.
    [ -n "$ORCA_REPO" ] || return 2
    cmp -s "$ORCA_REPO/$2" "$1" 2>/dev/null
}

remove_installed() { # $1 dst, $2 source path inside the repo
    [ -e "$1" ] || [ -L "$1" ] || return 0
    installer_made "$1" "$2" && verdict=0 || verdict=$?
    case "$verdict" in
        0)
            # rm -f on a symlink unlinks the link, never its target.
            if rm -f "$1" 2>/dev/null; then
                echo "    removed: $1"
            else
                echo "    ! could not remove $1 - left in place"
                LEFT=$((LEFT + 1))
            fi ;;
        2)
            echo "    ! cannot verify $1 without a local orca checkout - left in place"
            echo "      (re-run --uninstall from a checkout, e.g. git clone && ./install.sh --uninstall)"
            LEFT=$((LEFT + 1)) ;;
        *)
            echo "    left alone: $1 (not what the installer creates - yours, or edited)" ;;
    esac
}

unwire_claude_hook() {
    if [ "$CH" = "$HOME/.claude" ]; then
        # SC2088: same as wire_claude_hook - this tilde is data written into
        # settings.json, not a path to expand. It must match byte-for-byte
        # what the installer wired, or the entry is not found and not removed.
        # shellcheck disable=SC2088
        hook_cmd='~/.claude/hooks/orca-start-watcher.sh'
    else
        hook_cmd="$CH/hooks/orca-start-watcher.sh"
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "    ! jq not found - remove this from $1 under hooks.SessionStart yourself:"
        echo "    {\"hooks\":[{\"type\":\"command\",\"command\":\"$hook_cmd\"}]}"
        return 0
    fi
    [ -f "$1" ] || return 0
    # A default install drops both spellings: the ~ form it writes, and the
    # expanded form a hand-edit may carry. A custom CLAUDE_HOME drops only its
    # own absolute form, so tearing it down never unwires a separate default
    # install that is still in place.
    if [ "$CH" = "$HOME/.claude" ]; then
        drop=$(jq -nc --arg a "$hook_cmd" --arg b "$CH/hooks/orca-start-watcher.sh" \
            '[$a,$b] | unique | map({hooks:[{type:"command",command:.}]})')
    else
        drop=$(jq -nc --arg a "$hook_cmd" '[{hooks:[{type:"command",command:$a}]}]')
    fi
    n=$(jq --argjson d "$drop" \
        '[(.hooks.SessionStart // [])[] | select(. as $e | $d | index($e))] | length' "$1" 2>/dev/null) \
        || { echo "    ! $1 is not valid JSON - left as-is"; LEFT=$((LEFT + 1)); return 0; }
    if [ "$n" = 0 ]; then
        # Nothing of ours in there: do not rewrite the file at all, so an
        # untouched settings.json keeps its own formatting byte-for-byte.
        echo "    ok: no orca SessionStart entry in $1"
    else
        tmp=$(mktemp)
        # Surgical: drop only entries equal to what the installer writes, then
        # clean up the containers that leaves empty. Every other key, hook and
        # entry is carried through by jq untouched.
        if jq --argjson d "$drop" '
              .hooks.SessionStart |= map(select(. as $e | $d | index($e) | not))
              | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
              | if (.hooks | length) == 0 then del(.hooks) else . end
            ' "$1" > "$tmp" && mv "$tmp" "$1"; then
            echo "    unwired: SessionStart hook in $1"
        else
            rm -f "$tmp"
            echo "    ! could not rewrite $1 - left as-is"
            LEFT=$((LEFT + 1))
            return 0
        fi
    fi
    # An entry the user merged our command INTO is not one we wrote, so it is
    # not removed - but say so rather than leaving a silent leftover.
    if jq -e '[(.hooks.SessionStart // [])[] | tostring
               | select(contains("orca-start-watcher"))] | length > 0' "$1" >/dev/null 2>&1; then
        echo "    note: another SessionStart entry in $1 still references orca-start-watcher.sh; left as-is"
    fi
}

uninstall_claude() {
    CH="${CLAUDE_HOME:-$HOME/.claude}"
    remove_installed "$CH/agents/orca.md"                agents/orca.md
    remove_installed "$CH/hooks/orca-start-watcher.sh"   hooks/orca-start-watcher.sh
    remove_installed "$CH/scripts/gh-watch.sh"           scripts/gh-watch.sh
    unwire_claude_hook "$CH/settings.json"
}

uninstall_agents() {
    BIN="${ORCA_BIN:-$HOME/.local/bin}"
    remove_installed "$BIN/gh-watch"                  scripts/gh-watch.sh
    remove_installed "$HOME/.config/orca/AGENTS.md"   agents/orca.md
    # Only this directory is orca's own; ~/.claude/* and ~/.local/bin belong to
    # the user. rmdir (never rm -r) so a non-empty one is left standing.
    rmdir "$HOME/.config/orca" 2>/dev/null || true
}

uninstall() {
    # $HOME was normalized and vetted at the top, before any path was built.
    #
    # BEST EFFORT, not fail-fast: `set -eu` would abort the whole sweep on the
    # first failed `rm` - leaving some files installed, the hook still wired,
    # and no summary - and the user would then have to re-run once per
    # failure to discover the rest. A teardown is exactly where partial
    # failure is normal (read-only mounts, permissions, files already moved),
    # so every step runs, everything left behind is named as it happens, and
    # the count is reported at the end. The exit status still tells the truth:
    # non-zero when anything remains, so a script can detect it, and the run
    # is idempotent so a re-run after fixing the cause finishes the job.
    LEFT=0
    if [ -n "$ORCA_REPO" ]; then
        echo "Uninstalling orca (comparing against $ORCA_REPO)"
    else
        echo "Uninstalling orca (no local checkout to compare against)"
    fi
    echo "  claude style:"
    uninstall_claude
    echo "  agents style:"
    uninstall_agents
    if [ -d "$HOME/.orca-backups" ]; then
        echo "  note: files the installer replaced are still in $HOME/.orca-backups/"
        echo "        (untouched by uninstall - restore the ones you want by hand)."
    fi
    if [ "$LEFT" -gt 0 ]; then
        echo "done, but $LEFT item(s) are still installed - see the ! lines above."
        return 1
    fi
    echo "done."
}

if [ "$ACTION" = uninstall ]; then
    # `|| exit 1` and not a bare call: `set -e` would abort on the non-zero
    # return before the exit status could be handed back deliberately.
    uninstall || exit 1
    exit 0
fi

resolve_style
echo "Installing orca ($STYLE style) from $ORCA_REPO"
case "$STYLE" in
   claude) install_claude ;;
   agents) install_agents ;;
esac
[ -n "$BACKUP_DIR" ] && echo "replaced files moved to $BACKUP_DIR"
echo "done."
