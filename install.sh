#!/bin/sh
set -eu

ORCA_URL="${ORCA_URL:-https://github.com/iQonAi/orca.git}"

# Trust $0 only when it is a real file: under `curl | sh` $0 is the shell
# name, and resolving it to the cwd would let any directory that happens to
# contain agents/orca.md hijack the install source.
script_dir=
if [ -f "$0" ]; then
   script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || script_dir=
fi
if [ -z "$script_dir" ] || [ ! -f "$script_dir/agents/orca.md" ]; then
   # Piped (or stray copy): bootstrap durable checkout, then re-execute from it.
   ORCA_REPO="${ORCA_REPO:-$HOME/.local/share/orca}"
   # A quoted ORCA_REPO="~/x" reaches us with a literal tilde - expand it.
   case "$ORCA_REPO" in
       "~") ORCA_REPO="$HOME" ;;
       "~/"*) ORCA_REPO="$HOME/${ORCA_REPO#~/}" ;;
   esac
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
ORCA_REPO="$script_dir"

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

resolve_style
echo "Installing orca ($STYLE style) from $ORCA_REPO"
case "$STYLE" in
   claude) install_claude ;;
   agents) install_agents ;;
esac
[ -n "$BACKUP_DIR" ] && echo "replaced files moved to $BACKUP_DIR"
echo "done."
