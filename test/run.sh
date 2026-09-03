#!/usr/bin/env bash
#
# run.sh — test suite for orca's watcher components.
#
# Covers:
#   hooks/orca-start-watcher.sh  (SessionStart directive injection)
#   scripts/gh-watch.sh          (single-instance-per-repo watcher)
#
# Hermetic: temp git repos stand in for workspaces, a stub `gh` on PATH
# replaces the network, and GH_WATCH_STATE_DIR redirects pidfiles into a
# temp dir so a real watcher on this machine is neither seen nor disturbed.
#
# Usage:
#   bash test/run.sh
#
# Exit code: 0 if every case passes, 1 if any case fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/hooks"

if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq is required to run the test suite\n' >&2
  exit 1
fi

pass=0
fail=0

# ---------------------------------------------------------------------------
# orca-start-watcher.sh (SessionStart)
#
# This hook is not a blocking gate: it reads the SessionStart JSON payload on
# stdin, gates on `agent_type == "orca"`, resolves the repo LOCALLY from the
# git remote of the payload's `cwd`, prints its directive to STDOUT, and always
# exits 0. So it needs a runner that feeds a JSON payload on stdin and asserts
# stdout, not exit-code + stderr.
#
# The injection path is hermetic: real temp git repos (with a configured
# `remote.origin.url`) stand in for the workspace, so there is no network call
# and no real GitHub repo required.

WATCHER_HOOK="$HOOKS_DIR/orca-start-watcher.sh"
BASH_BIN="$(command -v bash)"

# Temp git repos: one with an SSH remote, one with an HTTPS remote (to exercise
# both URL-normalization paths), and one plain dir with no git remote.
WATCHER_TMP="$(mktemp -d)"
trap 'rm -rf "$WATCHER_TMP"' EXIT
REPO_SSH="$WATCHER_TMP/ssh"; REPO_HTTPS="$WATCHER_TMP/https"; REPO_NONE="$WATCHER_TMP/none"
mkdir -p "$REPO_SSH" "$REPO_HTTPS" "$REPO_NONE"
git -C "$REPO_SSH"   init -q
git -C "$REPO_SSH"   remote add origin 'git@github.com:octocat/hello-world.git'
git -C "$REPO_HTTPS" init -q
git -C "$REPO_HTTPS" remote add origin 'https://github.com/octocat/hello-world.git'
git -C "$REPO_NONE"  init -q   # no remote configured

# run_watcher <expected_exit> <stdout_substr|EMPTY> <desc> <json_payload>
#   stdout_substr  substring that must appear on stdout, or the literal
#                  token EMPTY to assert stdout is empty (a no-op / no inject)
run_watcher() {
  local expected_exit="$1" stdout_expect="$2" desc="$3" payload="$4"
  local out actual
  out="$(printf '%s' "$payload" | "$BASH_BIN" "$WATCHER_HOOK" 2>/dev/null)"
  actual=$?

  if [[ "$actual" != "$expected_exit" ]]; then
    printf 'FAIL: %s\n      expected exit %s, got %s\n' \
      "$desc" "$expected_exit" "$actual" >&2
    fail=$((fail + 1))
    return
  fi

  if [[ "$stdout_expect" == "EMPTY" ]]; then
    if [[ -n "$out" ]]; then
      printf 'FAIL: %s\n      expected empty stdout, got: %s\n' "$desc" "$out" >&2
      fail=$((fail + 1))
      return
    fi
  elif [[ "$out" != *"$stdout_expect"* ]]; then
    printf 'FAIL: %s\n      stdout missing substring: %s\n      got: %s\n' \
      "$desc" "$stdout_expect" "$out" >&2
    fail=$((fail + 1))
    return
  fi

  printf 'ok:   %s\n' "$desc"
  pass=$((pass + 1))
}

# non-orca session (a subagent carrying its own type): no directive, exit 0
run_watcher 0 EMPTY \
  'no-op: subagent (agent_type=implementer) injects nothing' \
  "{\"agent_type\":\"implementer\",\"cwd\":\"$REPO_SSH\"}"

# no agent_type field at all (plain session): no directive
run_watcher 0 EMPTY \
  'no-op: session with no agent_type injects nothing' \
  "{\"cwd\":\"$REPO_SSH\"}"

# fail-open: malformed (non-JSON) stdin still exits 0 with no directive
run_watcher 0 EMPTY \
  'fail-open: malformed stdin injects nothing, exits 0' \
  'not json at all'

# orca session, cwd has no git remote: no directive (repo unresolved)
run_watcher 0 EMPTY \
  'no-op: orca session whose cwd has no git remote' \
  "{\"agent_type\":\"orca\",\"cwd\":\"$REPO_NONE\"}"

# orca session, SSH remote: injects the watcher directive with the repo
run_watcher 0 'gh-watch.sh octocat/hello-world' \
  'inject: orca session (SSH remote) emits the watcher directive with the repo' \
  "{\"agent_type\":\"orca\",\"cwd\":\"$REPO_SSH\"}"
run_watcher 0 'run_in_background' \
  'inject: directive names run_in_background (agent-launched, harness-tracked)' \
  "{\"agent_type\":\"orca\",\"cwd\":\"$REPO_SSH\"}"

# orca session, HTTPS remote: normalized to the same owner/repo
run_watcher 0 'octocat/hello-world' \
  'inject: orca session (HTTPS remote) normalizes to owner/repo' \
  "{\"agent_type\":\"orca\",\"cwd\":\"$REPO_HTTPS\"}"

# ---------------------------------------------------------------------------
# gh-watch.sh — single-instance-per-repo guard
#
# Idempotency lives IN the script (per-repo pidfile), so these cases drive the
# script directly. Hermetic: a stub `gh` on PATH replaces the network, and
# GH_WATCH_STATE_DIR redirects the pidfiles into a temp dir so a real watcher
# on this machine is neither seen nor disturbed.
#
# Trick used throughout: with the stub returning EMPTY output the baseline
# fetch fails, so a run that GETS PAST the guard exits 1 ("baseline fetch
# failed") within milliseconds, while a run REFUSED by the guard exits 3. That
# makes "did it acquire?" a fast, deterministic assertion.

WATCH_SCRIPT="$REPO_ROOT/scripts/gh-watch.sh"
GH_TMP="$(mktemp -d)"
LIVE_WATCHERS=()
# Stubbed watchers are REAL processes that live ~55min. Reaping them must be in
# the EXIT trap, or an aborted/early-failing run leaks them; and children go
# first, because once the parent is dead its `sleep` is reparented and no
# longer matchable by `pgrep -P`.
reap_live_watchers() {
  local p c
  for p in ${LIVE_WATCHERS[@]+"${LIVE_WATCHERS[@]}"}; do
    for c in $(pgrep -P "$p" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
    kill -9 "$p" 2>/dev/null
  done
  LIVE_WATCHERS=()
}
# replaces the WATCHER_TMP-only trap
trap 'reap_live_watchers; chmod u+rwx "$GH_TMP/nowrite" 2>/dev/null; rm -rf "$WATCHER_TMP" "$GH_TMP"' EXIT
export GH_WATCH_STATE_DIR="$GH_TMP/state"
STUB_BIN="$GH_TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${GH_STUB_OUT-[]}"
STUB
chmod +x "$STUB_BIN/gh"

watch_pidfile() { printf '%s/%s.pid' "$GH_WATCH_STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }

# run_watch_in <state_dir> <expected_exit> <stdout_substr|EMPTY> <desc>
#              <stub_out> <argv...>   — full control over state dir and argv
run_watch_in() {
  local state_dir="$1" expected_exit="$2" substr="$3" desc="$4" stub_out="$5"
  shift 5
  local out actual
  out="$(PATH="$STUB_BIN:$PATH" GH_STUB_OUT="$stub_out" GH_WATCH_STATE_DIR="$state_dir" \
    "$BASH_BIN" "$WATCH_SCRIPT" "$@" 2>&1)"
  actual=$?
  if [[ "$actual" != "$expected_exit" ]]; then
    printf 'FAIL: %s\n      expected exit %s, got %s (output: %s)\n' \
      "$desc" "$expected_exit" "$actual" "$out" >&2
    fail=$((fail + 1))
    return
  fi
  if [[ "$substr" != "EMPTY" && "$out" != *"$substr"* ]]; then
    printf 'FAIL: %s\n      stdout missing substring: %s\n      got: %s\n' \
      "$desc" "$substr" "$out" >&2
    fail=$((fail + 1))
    return
  fi
  printf 'ok:   %s\n' "$desc"
  pass=$((pass + 1))
}

# run_watch <expected_exit> <stdout_substr|EMPTY> <desc> <repo> <stub_out>
run_watch() { run_watch_in "$GH_WATCH_STATE_DIR" "$1" "$2" "$3" "$5" "$4"; }

# wassert <desc> <cmd...> — generic boolean case
wassert() {
  local desc="$1"; shift
  if "$@"; then
    printf 'ok:   %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL: %s\n      condition failed: %s\n' "$desc" "$*" >&2; fail=$((fail + 1))
  fi
}

# start_live <repo> — launch a real (stubbed) watcher that stays in its poll
# loop; returns its pid in REPLY once it has taken the pidfile.
start_live() {
  PATH="$STUB_BIN:$PATH" GH_STUB_OUT='[{"n":1}]' "$BASH_BIN" "$WATCH_SCRIPT" "$1" >/dev/null 2>&1 &
  local pid=$! f i
  disown "$pid" 2>/dev/null || true   # keep bash from printing job-kill notices
  LIVE_WATCHERS+=("$pid")
  f="$(watch_pidfile "$1")"
  for i in $(seq 1 20); do [ -s "$f" ] && break; sleep 0.25; done
  REPLY="$pid"
}

# A live watcher for repo A holds the pidfile -> a second launch is refused.
start_live 'octocat/watch-a'; LIVE_A="$REPLY"
wassert 'gh-watch: first launch is running and owns the pidfile' \
  test "$(cat "$(watch_pidfile 'octocat/watch-a')" 2>/dev/null)" = "$LIVE_A"
run_watch 3 'already running' \
  'gh-watch: second launch for the same repo exits 3 and starts no poller' \
  'octocat/watch-a' '[{"n":1}]'
wassert 'gh-watch: refused launch left the first watcher alive' \
  kill -0 "$LIVE_A"
wassert 'gh-watch: refused launch left the incumbent pidfile intact' \
  test "$(cat "$(watch_pidfile 'octocat/watch-a')" 2>/dev/null)" = "$LIVE_A"

# --status never launches: it only reports on the incumbent.
run_watch_in "$GH_WATCH_STATE_DIR" 3 "watcher running for octocat/watch-a (pid $LIVE_A)" \
  'gh-watch: --status reports the live watcher (exit 3) without launching' \
  '[{"n":1}]' --status 'octocat/watch-a'
run_watch_in "$GH_WATCH_STATE_DIR" 0 'no watcher running' \
  'gh-watch: --status on an unwatched repo exits 0 and starts nothing' \
  '[{"n":1}]' --status 'octocat/watch-status-none'
wassert 'gh-watch: --status wrote no pidfile' \
  test ! -e "$(watch_pidfile 'octocat/watch-status-none')"

# A DIFFERENT repo is not blocked by repo A's watcher (state is per repo).
start_live 'octocat/watch-b'; LIVE_B="$REPLY"
wassert 'gh-watch: a second repo watches concurrently (own pidfile)' \
  test "$(cat "$(watch_pidfile 'octocat/watch-b')" 2>/dev/null)" = "$LIVE_B"
wassert 'gh-watch: both repo watchers are alive at the same time' \
  bash -c 'kill -0 '"$LIVE_A"' && kill -0 '"$LIVE_B"''

# Stale pidfile from a killed/crashed watcher must NOT wedge the script.
DEAD_PID_SH="$GH_TMP/dead.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$DEAD_PID_SH"; chmod +x "$DEAD_PID_SH"
"$BASH_BIN" "$DEAD_PID_SH" & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
printf '%s\n' "$DEAD_PID" >"$(watch_pidfile 'octocat/watch-stale')"
run_watch 1 'baseline fetch failed' \
  'gh-watch: stale pidfile (dead pid) is reclaimed, launch proceeds' \
  'octocat/watch-stale' ''
wassert 'gh-watch: pidfile is removed on exit' \
  test ! -e "$(watch_pidfile 'octocat/watch-stale')"

# Recycled pid: the file names a LIVE process that is not a gh-watch -> stale.
sleep 300 & IMPOSTOR=$!; disown "$IMPOSTOR" 2>/dev/null || true
printf '%s\n' "$IMPOSTOR" >"$(watch_pidfile 'octocat/watch-impostor')"
run_watch 1 'baseline fetch failed' \
  'gh-watch: live pid that is not a gh-watch is treated as stale' \
  'octocat/watch-impostor' ''
kill -9 "$IMPOSTOR" 2>/dev/null

# Garbage pidfile content must not wedge the script either.
printf 'not-a-pid\n' >"$(watch_pidfile 'octocat/watch-garbage')"
run_watch 1 'baseline fetch failed' \
  'gh-watch: unparseable pidfile is reclaimed, launch proceeds' \
  'octocat/watch-garbage' ''

# No prior state at all: launch proceeds (the originally-failing case).
run_watch 1 'baseline fetch failed' \
  'gh-watch: no watcher running for the repo -> launch proceeds' \
  'octocat/watch-fresh' ''

# A live watcher for a DIFFERENT repo in this repo's pidfile is NOT an
# incumbent: the liveness match is anchored on the repo argument, so the
# file is stale and this launch proceeds.
printf '%s\n' "$LIVE_B" >"$(watch_pidfile 'octocat/watch-other')"
run_watch 1 'baseline fetch failed' \
  'gh-watch: pidfile naming a live watcher for ANOTHER repo is stale' \
  'octocat/watch-other' ''
wassert 'gh-watch: the other-repo watcher was left alone' kill -0 "$LIVE_B"

# An existing but UNWRITABLE state dir: `mkdir -p` returns 0 for it, so the
# script must check writability itself. Reporting 3 here would tell the caller
# "one is already running, do not relaunch" when none is.
NOWRITE="$GH_TMP/nowrite"
mkdir -p "$NOWRITE"
chmod 500 "$NOWRITE"
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip: gh-watch: unwritable state dir (root bypasses mode bits)\n'
else
  run_watch_in "$NOWRITE" 1 'not a writable directory' \
    'gh-watch: unwritable state dir exits 1, not 3' \
    '' 'octocat/watch-nowrite'
fi
chmod u+rwx "$NOWRITE"

# Same class, permanent: the pidfile path is a directory, so it can be neither
# removed nor written. Must be 1 (and must not leak `rm:` to stderr).
mkdir -p "$(watch_pidfile 'octocat/watch-dirpid')"
DIRPID_OUT="$(PATH="$STUB_BIN:$PATH" GH_STUB_OUT='' "$BASH_BIN" "$WATCH_SCRIPT" 'octocat/watch-dirpid' 2>&1)"
DIRPID_RC=$?
wassert 'gh-watch: directory-shaped pidfile exits 1, not 3' test "$DIRPID_RC" -eq 1
wassert 'gh-watch: directory-shaped pidfile reports only its own message on stderr' \
  test "$DIRPID_OUT" = "could not take the watcher pidfile $(watch_pidfile 'octocat/watch-dirpid') for octocat/watch-dirpid"

# --takeover replaces an incumbent that is not the caller's own watcher.
start_live 'octocat/watch-take'; LIVE_TAKE="$REPLY"
run_watch_in "$GH_WATCH_STATE_DIR" 1 'taking over from watcher pid' \
  'gh-watch: --takeover terminates the incumbent and takes the pidfile' \
  '' --takeover 'octocat/watch-take'
wassert 'gh-watch: --takeover left no incumbent running' \
  bash -c '! kill -0 '"$LIVE_TAKE"' 2>/dev/null'

# SIGTERM must release the pidfile at once, not after the running `sleep 30`.
start_live 'octocat/watch-term'; LIVE_TERM="$REPLY"
kill -TERM "$LIVE_TERM" 2>/dev/null
for i in $(seq 1 20); do
  [ -e "$(watch_pidfile 'octocat/watch-term')" ] || break
  sleep 0.25
done
wassert 'gh-watch: SIGTERM releases the pidfile within 5s (not after sleep 30)' \
  test ! -e "$(watch_pidfile 'octocat/watch-term')"

# RACE: concurrent launches all finding the SAME stale pidfile must still
# leave exactly ONE watcher. Reclaiming is remove-then-create; unserialized,
# every loser deletes the winner's fresh pidfile and installs its own, so they
# all believe they own it and the pidfile ends up naming none of them.
RACE_REPO='octocat/watch-race'
printf '%s\n' "$DEAD_PID" >"$(watch_pidfile "$RACE_REPO")"
RACE_PIDS=()
for i in 1 2 3 4 5; do
  PATH="$STUB_BIN:$PATH" GH_STUB_OUT='[{"n":1}]' "$BASH_BIN" "$WATCH_SCRIPT" "$RACE_REPO" >/dev/null 2>&1 &
  RACE_PIDS+=("$!"); LIVE_WATCHERS+=("$!")
  disown "$!" 2>/dev/null || true
done
sleep 4
RACE_ALIVE=0; RACE_WINNER=""
for p in "${RACE_PIDS[@]}"; do
  if kill -0 "$p" 2>/dev/null; then RACE_ALIVE=$((RACE_ALIVE + 1)); RACE_WINNER="$p"; fi
done
wassert "gh-watch: 5 concurrent launches on a stale pidfile leave exactly 1 watcher (saw $RACE_ALIVE)" \
  test "$RACE_ALIVE" -eq 1
wassert 'gh-watch: the surviving racer is the pid recorded in the pidfile' \
  test "$(cat "$(watch_pidfile "$RACE_REPO")" 2>/dev/null)" = "$RACE_WINNER"
wassert 'gh-watch: the race left no lock directory behind' \
  test ! -e "$(watch_pidfile "$RACE_REPO").lock"

reap_live_watchers
unset GH_WATCH_STATE_DIR

# ---------------------------------------------------------------------------
# install.sh — style selection, layouts, idempotency
#
# Hermetic: every case points HOME at a temp dir, so the real ~/.claude and
# ~/.local are never touched. ORCA_STYLE bypasses the /dev/tty prompt. The
# no-tty case runs under setsid (no controlling terminal) so it behaves the
# same in an interactive shell and in CI.

INSTALL_SH="$REPO_ROOT/install.sh"
INST_TMP="$(mktemp -d)"
trap 'reap_live_watchers; chmod u+rwx "$GH_TMP/nowrite" 2>/dev/null; rm -rf "$WATCHER_TMP" "$GH_TMP" "$INST_TMP"' EXIT

# claude style on a fresh HOME
IH1="$INST_TMP/h1"; mkdir -p "$IH1"
OUT1="$(ORCA_STYLE=claude HOME="$IH1" sh "$INSTALL_SH" </dev/null 2>&1)"; RC1=$?
wassert 'install: claude style exits 0' test "$RC1" -eq 0
wassert 'install: agent symlink points into the repo' \
  test "$(readlink "$IH1/.claude/agents/orca.md")" = "$REPO_ROOT/agents/orca.md"
wassert 'install: hook and watcher installed' \
  bash -c "test -e '$IH1/.claude/hooks/orca-start-watcher.sh' && test -e '$IH1/.claude/scripts/gh-watch.sh'"
wassert 'install: SessionStart hook wired exactly once' \
  test "$(jq '.hooks.SessionStart | length' "$IH1/.claude/settings.json")" = 1
# The default install writes the ~ form UNEXPANDED, so the entry dedupes against
# hand-written ones; an expanded absolute path here would defeat that.
wassert 'install: default CLAUDE_HOME wires the literal ~ form, unexpanded' \
  test "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$IH1/.claude/settings.json")" = '~/.claude/hooks/orca-start-watcher.sh'
printf '%s' "$OUT1" | grep -q 'backup:' && FRESH_BACKUP=1 || FRESH_BACKUP=0
wassert 'install: fresh install makes no backups' test "$FRESH_BACKUP" = 0

# rerun is a no-op
OUT2="$(ORCA_STYLE=claude HOME="$IH1" sh "$INSTALL_SH" </dev/null 2>&1)"; RC2=$?
wassert 'install: rerun exits 0' test "$RC2" -eq 0
printf '%s' "$OUT2" | grep -qE 'installed:|backup:' && RERUN_CHANGED=1 || RERUN_CHANGED=0
wassert 'install: rerun changes nothing (idempotent)' test "$RERUN_CHANGED" = 0
wassert 'install: rerun leaves exactly one SessionStart entry' \
  test "$(jq '.hooks.SessionStart | length' "$IH1/.claude/settings.json")" = 1

# agents style
IH2="$INST_TMP/h2"; mkdir -p "$IH2"
ORCA_STYLE=agents HOME="$IH2" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1; RC3=$?
wassert 'install: agents style exits 0' test "$RC3" -eq 0
wassert 'install: agents style installs watcher + playbook' \
  bash -c "test -e '$IH2/.local/bin/gh-watch' && test -e '$IH2/.config/orca/AGENTS.md'"
wassert 'install: agents style creates no ~/.claude' test ! -d "$IH2/.claude"

# no tty, no ORCA_STYLE, nothing to detect -> refuse with exit 2, never hang
IH3="$INST_TMP/h3"; mkdir -p "$IH3"
if command -v setsid >/dev/null 2>&1; then
  HOME="$IH3" setsid -w sh "$INSTALL_SH" </dev/null >/dev/null 2>&1; RC4=$?
  wassert 'install: no tty + no ORCA_STYLE exits 2' test "$RC4" -eq 2
else
  printf 'skip: install: no-tty case (setsid unavailable)\n'
fi

# copy mode replaces (and backs up) a pre-existing file with a regular file
IH4="$INST_TMP/h4"; mkdir -p "$IH4/.claude/agents"
printf 'old\n' > "$IH4/.claude/agents/orca.md"
ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH4" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1; RC5=$?
wassert 'install: copy mode exits 0' test "$RC5" -eq 0
wassert 'install: copy mode installs a regular file, not a link' \
  bash -c "test -f '$IH4/.claude/agents/orca.md' && test ! -L '$IH4/.claude/agents/orca.md'"
wassert 'install: pre-existing file was backed up' \
  bash -c "ls '$IH4'/.orca-backups/*/orca.md >/dev/null 2>&1"

# copy-mode rerun is also a no-op (identical files short-circuit before backup)
OUT6="$(ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH4" sh "$INSTALL_SH" </dev/null 2>&1)"; RC6=$?
wassert 'install: copy-mode rerun exits 0' test "$RC6" -eq 0
printf '%s' "$OUT6" | grep -qE 'installed:|backup:' && COPY_RERUN_CHANGED=1 || COPY_RERUN_CHANGED=0
wassert 'install: copy-mode rerun changes nothing (idempotent)' test "$COPY_RERUN_CHANGED" = 0

# agents-style rerun is a no-op too
OUT7="$(ORCA_STYLE=agents HOME="$IH2" sh "$INSTALL_SH" </dev/null 2>&1)"; RC7=$?
wassert 'install: agents-style rerun exits 0' test "$RC7" -eq 0
printf '%s' "$OUT7" | grep -qE 'installed:|backup:' && AGENTS_RERUN_CHANGED=1 || AGENTS_RERUN_CHANGED=0
wassert 'install: agents-style rerun changes nothing (idempotent)' test "$AGENTS_RERUN_CHANGED" = 0

# custom CLAUDE_HOME: files land there and the wired hook command names it,
# never the ~/.claude default (which would point at nothing)
IH5="$INST_TMP/h5"; CH5="$INST_TMP/ch5"; mkdir -p "$IH5"
ORCA_STYLE=claude HOME="$IH5" CLAUDE_HOME="$CH5" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1; RC8=$?
wassert 'install: custom CLAUDE_HOME exits 0' test "$RC8" -eq 0
wassert 'install: custom CLAUDE_HOME receives the files' \
  test -e "$CH5/hooks/orca-start-watcher.sh"
wassert 'install: wired hook command names the custom CLAUDE_HOME' \
  test "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CH5/settings.json")" = "$CH5/hooks/orca-start-watcher.sh"

# piped bootstrap: stdin-fed script ($0 is the shell) must clone to ORCA_REPO
# and re-exec from the clone - never trust the cwd. file:// keeps it offline.
if command -v git >/dev/null 2>&1; then
  BOOT="$INST_TMP/boot"; mkdir -p "$BOOT/home"
  ( cd "$INST_TMP" && \
    ORCA_URL="file://$REPO_ROOT" ORCA_REPO="$BOOT/clone" ORCA_STYLE=claude \
    HOME="$BOOT/home" sh <"$INSTALL_SH" ) >/dev/null 2>&1; RC9=$?
  wassert 'install: piped bootstrap exits 0' test "$RC9" -eq 0
  wassert 'install: piped bootstrap cloned to ORCA_REPO' \
    test -f "$BOOT/clone/agents/orca.md"
  wassert 'install: piped bootstrap installed from the clone, not the cwd' \
    bash -c "readlink '$BOOT/home/.claude/agents/orca.md' | grep -q '^$BOOT/clone/'"
else
  printf 'skip: install: piped bootstrap (git unavailable)\n'
fi

# literal-tilde ORCA_REPO: a QUOTED ORCA_REPO="~/x" reaches install.sh with the
# tilde unexpanded, so install.sh expands it itself. Regression for #24, where
# the strip pattern was itself tilde-expanded and "~/x" resolved to "$HOME/~/x"
# - cloning into a directory literally named `~` inside the user's home. Only
# the piped path reaches that code, so these drive it the same way as above.
if command -v git >/dev/null 2>&1; then
  TH1="$INST_TMP/tilde-slash"; mkdir -p "$TH1/home"
  OUTT1="$( cd "$INST_TMP" && \
    ORCA_URL="file://$REPO_ROOT" ORCA_REPO='~/clone' ORCA_STYLE=claude \
    HOME="$TH1/home" sh <"$INSTALL_SH" 2>&1 )"; RCT1=$?
  wassert 'install: ORCA_REPO="~/x" exits 0' test "$RCT1" -eq 0
  wassert 'install: ORCA_REPO="~/x" cloned to $HOME/x' \
    test -f "$TH1/home/clone/agents/orca.md"
  wassert 'install: ORCA_REPO="~/x" left no literal ~ segment on disk' \
    test ! -e "$TH1/home/~"
  printf '%s' "$OUTT1" | grep -qx "Installing orca (claude style) from $TH1/home/clone" \
    && T1_RESOLVED=1 || T1_RESOLVED=0
  wassert 'install: ORCA_REPO="~/x" resolved to $HOME/x, tilde expanded' \
    test "$T1_RESOLVED" = 1

  # the bare `~` form resolves to $HOME itself
  TH2="$INST_TMP/tilde-bare"; mkdir -p "$TH2/home"
  OUTT2="$( cd "$INST_TMP" && \
    ORCA_URL="file://$REPO_ROOT" ORCA_REPO='~' ORCA_STYLE=claude \
    HOME="$TH2/home" sh <"$INSTALL_SH" 2>&1 )"; RCT2=$?
  wassert 'install: ORCA_REPO="~" exits 0' test "$RCT2" -eq 0
  wassert 'install: ORCA_REPO="~" cloned into $HOME itself' \
    test -f "$TH2/home/agents/orca.md"
  wassert 'install: ORCA_REPO="~" left no literal ~ segment on disk' \
    test ! -e "$TH2/home/~"
  printf '%s' "$OUTT2" | grep -qx "Installing orca (claude style) from $TH2/home" \
    && T2_RESOLVED=1 || T2_RESOLVED=0
  wassert 'install: ORCA_REPO="~" resolved to $HOME, tilde expanded' \
    test "$T2_RESOLVED" = 1
else
  printf 'skip: install: literal-tilde ORCA_REPO (git unavailable)\n'
fi

# ---------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
