#!/usr/bin/env bash
#
# run.sh — test suite for orca's watcher components.
#
# Covers:
#   hooks/orca-start-watcher.sh  (SessionStart directive injection)
#   scripts/gh-watch.sh          (single-instance-per-repo watcher)
#   install.sh                   (both styles, --uninstall, --restore)
#   bin/orca                     (the launcher: preflight checks, identity)
#
# Hermetic: temp git repos stand in for workspaces, a stub `gh` (and, for the
# launcher, a stub `claude`) on PATH replaces the network, and
# GH_WATCH_STATE_DIR redirects pidfiles into a temp dir so a real watcher on
# this machine is neither seen nor disturbed.
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
REPO_SSH="$WATCHER_TMP/ssh"
REPO_HTTPS="$WATCHER_TMP/https"
REPO_NONE="$WATCHER_TMP/none"
mkdir -p "$REPO_SSH" "$REPO_HTTPS" "$REPO_NONE"
git -C "$REPO_SSH" init -q
git -C "$REPO_SSH" remote add origin 'git@github.com:octocat/hello-world.git'
git -C "$REPO_HTTPS" init -q
git -C "$REPO_HTTPS" remote add origin 'https://github.com/octocat/hello-world.git'
git -C "$REPO_NONE" init -q # no remote configured

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
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok:   %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n      condition failed: %s\n' "$desc" "$*" >&2
    fail=$((fail + 1))
  fi
}

# start_live <repo> — launch a real (stubbed) watcher that stays in its poll
# loop; returns its pid in REPLY once it has taken the pidfile.
start_live() {
  PATH="$STUB_BIN:$PATH" GH_STUB_OUT='[{"n":1}]' "$BASH_BIN" "$WATCH_SCRIPT" "$1" >/dev/null 2>&1 &
  local pid=$! f i
  disown "$pid" 2>/dev/null || true # keep bash from printing job-kill notices
  LIVE_WATCHERS+=("$pid")
  f="$(watch_pidfile "$1")"
  for i in $(seq 1 20); do
    [ -s "$f" ] && break
    sleep 0.25
  done
  REPLY="$pid"
}

# A live watcher for repo A holds the pidfile -> a second launch is refused.
start_live 'octocat/watch-a'
LIVE_A="$REPLY"
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
start_live 'octocat/watch-b'
LIVE_B="$REPLY"
wassert 'gh-watch: a second repo watches concurrently (own pidfile)' \
  test "$(cat "$(watch_pidfile 'octocat/watch-b')" 2>/dev/null)" = "$LIVE_B"
wassert 'gh-watch: both repo watchers are alive at the same time' \
  bash -c 'kill -0 '"$LIVE_A"' && kill -0 '"$LIVE_B"''

# Stale pidfile from a killed/crashed watcher must NOT wedge the script.
DEAD_PID_SH="$GH_TMP/dead.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$DEAD_PID_SH"
chmod +x "$DEAD_PID_SH"
"$BASH_BIN" "$DEAD_PID_SH" &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
printf '%s\n' "$DEAD_PID" >"$(watch_pidfile 'octocat/watch-stale')"
run_watch 1 'baseline fetch failed' \
  'gh-watch: stale pidfile (dead pid) is reclaimed, launch proceeds' \
  'octocat/watch-stale' ''
wassert 'gh-watch: pidfile is removed on exit' \
  test ! -e "$(watch_pidfile 'octocat/watch-stale')"

# Recycled pid: the file names a LIVE process that is not a gh-watch -> stale.
sleep 300 &
IMPOSTOR=$!
disown "$IMPOSTOR" 2>/dev/null || true
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
start_live 'octocat/watch-take'
LIVE_TAKE="$REPLY"
run_watch_in "$GH_WATCH_STATE_DIR" 1 'taking over from watcher pid' \
  'gh-watch: --takeover terminates the incumbent and takes the pidfile' \
  '' --takeover 'octocat/watch-take'
wassert 'gh-watch: --takeover left no incumbent running' \
  bash -c '! kill -0 '"$LIVE_TAKE"' 2>/dev/null'

# SIGTERM must release the pidfile at once, not after the running `sleep 30`.
start_live 'octocat/watch-term'
LIVE_TERM="$REPLY"
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
  RACE_PIDS+=("$!")
  LIVE_WATCHERS+=("$!")
  disown "$!" 2>/dev/null || true
done
sleep 4
RACE_ALIVE=0
RACE_WINNER=""
for p in "${RACE_PIDS[@]}"; do
  if kill -0 "$p" 2>/dev/null; then
    RACE_ALIVE=$((RACE_ALIVE + 1))
    RACE_WINNER="$p"
  fi
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
LAUNCHER="$REPO_ROOT/bin/orca"
INST_TMP="$(mktemp -d)"
trap 'reap_live_watchers; chmod u+rwx "$GH_TMP/nowrite" 2>/dev/null; rm -rf "$WATCHER_TMP" "$GH_TMP" "$INST_TMP"' EXIT

# claude style on a fresh HOME
IH1="$INST_TMP/h1"
mkdir -p "$IH1"
OUT1="$(ORCA_STYLE=claude HOME="$IH1" sh "$INSTALL_SH" </dev/null 2>&1)"
RC1=$?
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
# The summary line belongs to a run that moved something aside: with nothing
# to back up it is absent, and its guard must not turn the run into exit 1 (#17).
printf '%s' "$OUT1" | grep -q 'replaced files' && FRESH_REPLACED=1 || FRESH_REPLACED=0
wassert 'install: fresh install prints no replaced-files line' test "$FRESH_REPLACED" = 0

# rerun is a no-op
OUT2="$(ORCA_STYLE=claude HOME="$IH1" sh "$INSTALL_SH" </dev/null 2>&1)"
RC2=$?
wassert 'install: rerun exits 0' test "$RC2" -eq 0
printf '%s' "$OUT2" | grep -qE 'installed:|backup:' && RERUN_CHANGED=1 || RERUN_CHANGED=0
wassert 'install: rerun changes nothing (idempotent)' test "$RERUN_CHANGED" = 0
wassert 'install: rerun leaves exactly one SessionStart entry' \
  test "$(jq '.hooks.SessionStart | length' "$IH1/.claude/settings.json")" = 1

# agents style
IH2="$INST_TMP/h2"
mkdir -p "$IH2"
ORCA_STYLE=agents HOME="$IH2" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
RC3=$?
wassert 'install: agents style exits 0' test "$RC3" -eq 0
wassert 'install: agents style installs watcher + playbook' \
  bash -c "test -e '$IH2/.local/bin/gh-watch' && test -e '$IH2/.config/orca/AGENTS.md'"
wassert 'install: agents style creates no ~/.claude' test ! -d "$IH2/.claude"

# no tty, no ORCA_STYLE -> refuse with exit 2 and install nothing, never hang
# and never guess. An existing ~/.claude used to select the claude style with
# only a notice, and the install then edited its settings.json (#16): it is
# now the same refusal, and the directory stays empty. setsid drops the
# controlling terminal, so /dev/tty cannot be opened, as in CI.
IH3="$INST_TMP/h3"
mkdir -p "$IH3"
IH24="$INST_TMP/h24"
mkdir -p "$IH24/.claude"
IH25="$INST_TMP/h25"
mkdir -p "$IH25"
IH29="$INST_TMP/h29"
mkdir -p "$IH29"
NOTTY_MSG='no tty and ORCA_STYLE unset; re-run with ORCA_STYLE=claude or ORCA_STYLE=agents'
if command -v setsid >/dev/null 2>&1; then
  OUT4="$(HOME="$IH3" setsid -w sh "$INSTALL_SH" </dev/null 2>&1)"
  RC4=$?
  wassert 'install: no tty + no ORCA_STYLE exits 2' test "$RC4" -eq 2
  printf '%s' "$OUT4" | grep -qF "$NOTTY_MSG" && NOTTY_SAID=1 || NOTTY_SAID=0
  wassert 'install: no tty + no ORCA_STYLE says how to re-run' test "$NOTTY_SAID" = 1
  wassert 'install: no tty + no ORCA_STYLE installs nothing' test ! -d "$IH3/.claude"
  OUT4B="$(HOME="$IH24" setsid -w sh "$INSTALL_SH" </dev/null 2>&1)"
  RC4B=$?
  wassert 'install: no tty + no ORCA_STYLE + an existing ~/.claude exits 2, not inferred' \
    test "$RC4B" -eq 2
  printf '%s' "$OUT4B" | grep -qF "$NOTTY_MSG" && NOTTY_SAID_B=1 || NOTTY_SAID_B=0
  wassert 'install: no tty + no ORCA_STYLE + an existing ~/.claude says how to re-run' \
    test "$NOTTY_SAID_B" = 1
  wassert 'install: no tty + no ORCA_STYLE + an existing ~/.claude leaves it empty' \
    test -z "$(ls -A "$IH24/.claude")"
  # with the style stated there is nothing to ask, so no tty is no obstacle
  HOME="$IH25" ORCA_STYLE=claude setsid -w sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
  RC4C=$?
  wassert 'install: no tty + ORCA_STYLE=claude exits 0' test "$RC4C" -eq 0
  wassert 'install: no tty + ORCA_STYLE=claude installs and wires the hook' \
    test "$(jq '.hooks.SessionStart | length' "$IH25/.claude/settings.json")" = 1
  # a value that is set but not a style - a typo in CI - is named, not called unset
  OUT4D="$(HOME="$IH29" ORCA_STYLE=cluade setsid -w sh "$INSTALL_SH" </dev/null 2>&1)"
  RC4D=$?
  wassert 'install: no tty + an invalid ORCA_STYLE exits 2' test "$RC4D" -eq 2
  printf '%s' "$OUT4D" | grep -qF 'no tty and ORCA_STYLE=cluade is not claude or agents; re-run with ORCA_STYLE=claude or ORCA_STYLE=agents' &&
    NOTTY_NAMED=1 || NOTTY_NAMED=0
  wassert 'install: no tty + an invalid ORCA_STYLE names the value' test "$NOTTY_NAMED" = 1
  wassert 'install: no tty + an invalid ORCA_STYLE installs nothing' test ! -d "$IH29/.claude"
else
  printf 'skip: install: no-tty cases (setsid unavailable)\n'
fi

# copy mode replaces (and backs up) a pre-existing file with a regular file
IH4="$INST_TMP/h4"
mkdir -p "$IH4/.claude/agents"
printf 'old\n' >"$IH4/.claude/agents/orca.md"
OUT5="$(ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH4" sh "$INSTALL_SH" </dev/null 2>&1)"
RC5=$?
wassert 'install: copy mode exits 0' test "$RC5" -eq 0
wassert 'install: copy mode installs a regular file, not a link' \
  bash -c "test -f '$IH4/.claude/agents/orca.md' && test ! -L '$IH4/.claude/agents/orca.md'"
wassert 'install: pre-existing file was backed up' \
  bash -c "ls '$IH4'/.orca-backups/*/*-orca.md >/dev/null 2>&1"
printf '%s' "$OUT5" | grep -qF "replaced files moved to $IH4/.orca-backups/" && BACKUP_SAID=1 || BACKUP_SAID=0
wassert 'install: an install over an existing file names the backup dir' test "$BACKUP_SAID" = 1

# copy-mode rerun is also a no-op (identical files short-circuit before backup)
OUT6="$(ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH4" sh "$INSTALL_SH" </dev/null 2>&1)"
RC6=$?
wassert 'install: copy-mode rerun exits 0' test "$RC6" -eq 0
printf '%s' "$OUT6" | grep -qE 'installed:|backup:' && COPY_RERUN_CHANGED=1 || COPY_RERUN_CHANGED=0
wassert 'install: copy-mode rerun changes nothing (idempotent)' test "$COPY_RERUN_CHANGED" = 0

# agents-style rerun is a no-op too
OUT7="$(ORCA_STYLE=agents HOME="$IH2" sh "$INSTALL_SH" </dev/null 2>&1)"
RC7=$?
wassert 'install: agents-style rerun exits 0' test "$RC7" -eq 0
printf '%s' "$OUT7" | grep -qE 'installed:|backup:' && AGENTS_RERUN_CHANGED=1 || AGENTS_RERUN_CHANGED=0
wassert 'install: agents-style rerun changes nothing (idempotent)' test "$AGENTS_RERUN_CHANGED" = 0

# custom CLAUDE_HOME: files land there and the wired hook command names it,
# never the ~/.claude default (which would point at nothing)
IH5="$INST_TMP/h5"
CH5="$INST_TMP/ch5"
mkdir -p "$IH5"
ORCA_STYLE=claude HOME="$IH5" CLAUDE_HOME="$CH5" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
RC8=$?
wassert 'install: custom CLAUDE_HOME exits 0' test "$RC8" -eq 0
wassert 'install: custom CLAUDE_HOME receives the files' \
  test -e "$CH5/hooks/orca-start-watcher.sh"
wassert 'install: wired hook command names the custom CLAUDE_HOME' \
  test "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CH5/settings.json")" = "$CH5/hooks/orca-start-watcher.sh"

# A settings.json that already wires the hook BY HAND counts as wired, whatever
# else the entry carries: the dedupe goes by the command an entry runs, never
# by exact equality with the entry the installer writes. Exact equality missed
# a hand-edited entry (a `matcher`, a `timeout` inside hooks[]) and appended a
# second copy on every run (#15). A recognised entry leaves the file untouched
# - a rewrite would have backed it up and reformatted it - so cmp is asserted
# beside the entry count.
IH19="$INST_TMP/h19"
mkdir -p "$IH19/.claude"
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/orca-start-watcher.sh"}]}]}}' \
  >"$IH19/.claude/settings.json"
cp "$IH19/.claude/settings.json" "$INST_TMP/h19-settings.before"
OUTD1="$(ORCA_STYLE=claude HOME="$IH19" sh "$INSTALL_SH" </dev/null 2>&1)"
RCD1=$?
wassert 'install: a hand-wired entry with a matcher key exits 0' test "$RCD1" -eq 0
wassert 'install: a hand-wired entry with a matcher key is not duplicated' \
  test "$(jq '.hooks.SessionStart | length' "$IH19/.claude/settings.json")" = 1
wassert 'install: a hand-wired entry with a matcher key leaves settings.json untouched' \
  cmp -s "$INST_TMP/h19-settings.before" "$IH19/.claude/settings.json"
printf '%s' "$OUTD1" | grep -qF 'ok: SessionStart hook already wired' && D1_SAID=1 || D1_SAID=0
wassert 'install: a hand-wired entry with a matcher key is reported as already wired' test "$D1_SAID" = 1
ORCA_STYLE=claude HOME="$IH19" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'install: a rerun over a hand-wired entry keeps exactly one entry' \
  test "$(jq '.hooks.SessionStart | length' "$IH19/.claude/settings.json")" = 1

# the same, with the extra key inside hooks[] rather than beside it
IH20="$INST_TMP/h20"
mkdir -p "$IH20/.claude"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/orca-start-watcher.sh","timeout":10}]}]}}' \
  >"$IH20/.claude/settings.json"
cp "$IH20/.claude/settings.json" "$INST_TMP/h20-settings.before"
ORCA_STYLE=claude HOME="$IH20" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
RCD2=$?
wassert 'install: a hand-wired entry with extra keys inside hooks[] exits 0' test "$RCD2" -eq 0
wassert 'install: a hand-wired entry with extra keys inside hooks[] is not duplicated' \
  test "$(jq '.hooks.SessionStart | length' "$IH20/.claude/settings.json")" = 1
wassert 'install: a hand-wired entry with extra keys inside hooks[] leaves settings.json untouched' \
  cmp -s "$INST_TMP/h20-settings.before" "$IH20/.claude/settings.json"

# an unrelated entry - a matcher, extra keys, a command of its own - is never
# taken for the hook: orca is wired beside it, it survives with every key and
# value intact, and a rerun adds nothing.
IH21="$INST_TMP/h21"
mkdir -p "$IH21/.claude"
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"~/.claude/hooks/mine.sh","timeout":5}]}]}}' \
  >"$IH21/.claude/settings.json"
PRE21="$(jq -Sc '.hooks.SessionStart[0]' "$IH21/.claude/settings.json")"
ORCA_STYLE=claude HOME="$IH21" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'install: an unrelated SessionStart entry is not taken for the hook (orca wired beside it)' \
  test "$(jq '.hooks.SessionStart | length' "$IH21/.claude/settings.json")" = 2
wassert 'install: the unrelated SessionStart entry survives with its keys and values intact' \
  test "$(jq -Sc '.hooks.SessionStart[0]' "$IH21/.claude/settings.json")" = "$PRE21"
ORCA_STYLE=claude HOME="$IH21" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'install: a rerun beside the unrelated entry keeps exactly two entries' \
  test "$(jq '.hooks.SessionStart | length' "$IH21/.claude/settings.json")" = 2

# ...and so is an entry whose command merely CONTAINS the hook path: wired
# means equal to it, never a substring of it, or a `.bak` beside the hook
# would pass for the hook and orca would be left unwired (#38).
IH26="$INST_TMP/h26"
mkdir -p "$IH26/.claude"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/hooks/orca-start-watcher.sh.bak"}]}]}}' \
  >"$IH26/.claude/settings.json"
ORCA_STYLE=claude HOME="$IH26" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'install: an entry whose command merely contains the hook path is not taken for it (orca wired beside it)' \
  test "$(jq '.hooks.SessionStart | length' "$IH26/.claude/settings.json")" = 2
wassert 'install: the containing entry and the orca entry both stand, each with its own command' \
  test "$(jq -c '[.hooks.SessionStart[].hooks[].command]' "$IH26/.claude/settings.json")" = '["~/.claude/hooks/orca-start-watcher.sh.bak","~/.claude/hooks/orca-start-watcher.sh"]'

# the expanded spelling is recognised too: the absolute path a custom
# CLAUDE_HOME writes, and the default path spelled out in full by hand.
IH22="$INST_TMP/h22"
CH22="$INST_TMP/ch22"
mkdir -p "$IH22" "$CH22"
printf '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"%s/hooks/orca-start-watcher.sh"}]}]}}\n' "$CH22" \
  >"$CH22/settings.json"
cp "$CH22/settings.json" "$INST_TMP/h22-settings.before"
ORCA_STYLE=claude HOME="$IH22" CLAUDE_HOME="$CH22" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
RCD4=$?
wassert 'install: a hand-wired entry naming a custom CLAUDE_HOME exits 0' test "$RCD4" -eq 0
wassert 'install: a hand-wired entry naming a custom CLAUDE_HOME is not duplicated' \
  test "$(jq '.hooks.SessionStart | length' "$CH22/settings.json")" = 1
wassert 'install: a hand-wired entry naming a custom CLAUDE_HOME leaves settings.json untouched' \
  cmp -s "$INST_TMP/h22-settings.before" "$CH22/settings.json"
IH23="$INST_TMP/h23"
mkdir -p "$IH23/.claude"
printf '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"%s/.claude/hooks/orca-start-watcher.sh"}]}]}}\n' "$IH23" \
  >"$IH23/.claude/settings.json"
ORCA_STYLE=claude HOME="$IH23" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'install: a hand-wired entry spelling the default path out in full is not duplicated' \
  test "$(jq '.hooks.SessionStart | length' "$IH23/.claude/settings.json")" = 1

# a trailing slash on CLAUDE_HOME names the same home: `/x/` used to build the
# hook identity as `/x//hooks/...`, which matched no hand-wired `/x/hooks/...`,
# so install appended a duplicate on every run (#38).
IH27="$INST_TMP/h27"
CH27="$INST_TMP/ch27"
mkdir -p "$IH27" "$CH27"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/hooks/orca-start-watcher.sh"}]}]}}\n' "$CH27" \
  >"$CH27/settings.json"
cp "$CH27/settings.json" "$INST_TMP/h27-settings.before"
ORCA_STYLE=claude HOME="$IH27" CLAUDE_HOME="$CH27/" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
RCD5=$?
wassert 'install: CLAUDE_HOME with a trailing slash exits 0' test "$RCD5" -eq 0
wassert 'install: CLAUDE_HOME with a trailing slash does not duplicate a hand-wired plain-path entry' \
  test "$(jq '.hooks.SessionStart | length' "$CH27/settings.json")" = 1
wassert 'install: CLAUDE_HOME with a trailing slash leaves the hand-wired settings.json untouched' \
  cmp -s "$INST_TMP/h27-settings.before" "$CH27/settings.json"
# every trailing slash, not just one: `<dir>//` is the same home too
ORCA_STYLE=claude HOME="$IH27" CLAUDE_HOME="$CH27//" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
RCD6=$?
wassert 'install: CLAUDE_HOME with two trailing slashes exits 0' test "$RCD6" -eq 0
wassert 'install: CLAUDE_HOME with two trailing slashes does not duplicate a hand-wired plain-path entry' \
  test "$(jq '.hooks.SessionStart | length' "$CH27/settings.json")" = 1
wassert 'install: CLAUDE_HOME with two trailing slashes leaves the hand-wired settings.json untouched' \
  cmp -s "$INST_TMP/h27-settings.before" "$CH27/settings.json"

# The piped path clones ORCA_URL at ORCA_REF - a release tag by default - so
# the origin standing in for github must carry that tag. A temp repo does:
# the files install.sh installs, copied from the WORKING TREE so the code
# under test is the code being edited, tagged v0.1.0; an empty commit tagged
# v0.2.0; and an untagged commit at the head of main. The real checkout will
# not do - it has no such tag, and in CI it is a shallow, tagless fetch.
# GIT_CONFIG_GLOBAL and the identity vars keep a developer's own git config
# (signing, hooks) out of the fixture. file:// keeps every clone offline.
ORIGIN="$INST_TMP/origin"
if command -v git >/dev/null 2>&1; then
  mkdir -p "$ORIGIN/agents" "$ORIGIN/hooks" "$ORIGIN/scripts" "$ORIGIN/bin"
  cp "$INSTALL_SH" "$ORIGIN/install.sh"
  cp "$REPO_ROOT/agents/orca.md" "$ORIGIN/agents/orca.md"
  cp "$HOOKS_DIR/orca-start-watcher.sh" "$ORIGIN/hooks/orca-start-watcher.sh"
  cp "$WATCH_SCRIPT" "$ORIGIN/scripts/gh-watch.sh"
  cp "$LAUNCHER" "$ORIGIN/bin/orca"
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_AUTHOR_NAME=orca-test GIT_AUTHOR_EMAIL=orca-test@example.invalid \
      GIT_COMMITTER_NAME=orca-test GIT_COMMITTER_EMAIL=orca-test@example.invalid
    git -C "$ORIGIN" init -q -b main
    git -C "$ORIGIN" add -A
    git -C "$ORIGIN" commit -q -m 'release v0.1.0'
    git -C "$ORIGIN" tag v0.1.0
    git -C "$ORIGIN" commit -q --allow-empty -m 'release v0.2.0'
    git -C "$ORIGIN" tag v0.2.0
    git -C "$ORIGIN" commit -q --allow-empty -m 'unreleased'
  )
fi

# piped bootstrap: stdin-fed script ($0 is the shell) must clone to ORCA_REPO
# and re-exec from the clone - never trust the cwd. file:// keeps it offline.
if command -v git >/dev/null 2>&1; then
  BOOT="$INST_TMP/boot"
  mkdir -p "$BOOT/home"
  (cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$BOOT/clone" ORCA_STYLE=claude \
      HOME="$BOOT/home" sh <"$INSTALL_SH") >/dev/null 2>&1
  RC9=$?
  wassert 'install: piped bootstrap exits 0' test "$RC9" -eq 0
  wassert 'install: piped bootstrap cloned to ORCA_REPO' \
    test -f "$BOOT/clone/agents/orca.md"
  # case, not grep: the prefix interpolates a mktemp path (`tmp.XXXXXXXXXX`),
  # so as a regex its `.` would be a live BRE metacharacter, not a literal.
  case "$(readlink "$BOOT/home/.claude/agents/orca.md")" in
    "$BOOT/clone/"*) BOOT_FROM_CLONE=1 ;;
    *) BOOT_FROM_CLONE=0 ;;
  esac
  wassert 'install: piped bootstrap installed from the clone, not the cwd' \
    test "$BOOT_FROM_CLONE" = 1
else
  printf 'skip: install: piped bootstrap (git unavailable)\n'
fi

# literal-tilde ORCA_REPO: a QUOTED ORCA_REPO="~/x" reaches install.sh with the
# tilde unexpanded, so install.sh expands it itself. Regression for #24, where
# the strip pattern was itself tilde-expanded and "~/x" resolved to "$HOME/~/x"
# - cloning into a directory literally named `~` inside the user's home. Only
# the piped path reaches that code, so these drive it the same way as above.
if command -v git >/dev/null 2>&1; then
  TH1="$INST_TMP/tilde-slash"
  mkdir -p "$TH1/home"
  OUTT1="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO='~/clone' ORCA_STYLE=claude \
      HOME="$TH1/home" sh <"$INSTALL_SH" 2>&1)"
  RCT1=$?
  wassert 'install: ORCA_REPO="~/x" exits 0' test "$RCT1" -eq 0
  wassert 'install: ORCA_REPO="~/x" cloned to $HOME/x' \
    test -f "$TH1/home/clone/agents/orca.md"
  wassert 'install: ORCA_REPO="~/x" left no literal ~ segment on disk' \
    test ! -e "$TH1/home/~"
  # -F: the expected line interpolates a mktemp path (`tmp.XXXXXXXXXX`), so
  # without it the `.` is a live BRE metacharacter, not a literal.
  printf '%s' "$OUTT1" | grep -qxF "Installing orca (claude style) from $TH1/home/clone" &&
    T1_RESOLVED=1 || T1_RESOLVED=0
  wassert 'install: ORCA_REPO="~/x" resolved to $HOME/x, tilde expanded' \
    test "$T1_RESOLVED" = 1

  # the bare `~` form resolves to $HOME itself
  TH2="$INST_TMP/tilde-bare"
  mkdir -p "$TH2/home"
  OUTT2="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO='~' ORCA_STYLE=claude \
      HOME="$TH2/home" sh <"$INSTALL_SH" 2>&1)"
  RCT2=$?
  wassert 'install: ORCA_REPO="~" exits 0' test "$RCT2" -eq 0
  wassert 'install: ORCA_REPO="~" cloned into $HOME itself' \
    test -f "$TH2/home/agents/orca.md"
  wassert 'install: ORCA_REPO="~" left no literal ~ segment on disk' \
    test ! -e "$TH2/home/~"
  printf '%s' "$OUTT2" | grep -qxF "Installing orca (claude style) from $TH2/home" &&
    T2_RESOLVED=1 || T2_RESOLVED=0
  wassert 'install: ORCA_REPO="~" resolved to $HOME, tilde expanded' \
    test "$T2_RESOLVED" = 1
else
  printf 'skip: install: literal-tilde ORCA_REPO (git unavailable)\n'
fi

# pinned ref: the piped bootstrap clones ORCA_REF - a release tag - never the
# head of main, so `curl | sh` installs a known version, and a re-run moves an
# existing checkout to it. Each case asserts the checkout itself (the tag HEAD
# sits on, which is what the version line reads back) and then the line.
if command -v git >/dev/null 2>&1; then
  # default: the pinned tag, present locally so `git describe` can name it
  PIN1="$INST_TMP/pin-default"
  mkdir -p "$PIN1/home"
  OUTV1="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN1/clone" ORCA_STYLE=claude \
      HOME="$PIN1/home" sh <"$INSTALL_SH" 2>&1)"
  RCV1=$?
  wassert 'install: pinned default exits 0' test "$RCV1" -eq 0
  wassert 'install: pinned default checks out v0.1.0, not the head of main' \
    test "$(git -C "$PIN1/clone" describe --tags --exact-match 2>/dev/null)" = v0.1.0
  printf '%s' "$OUTV1" | grep -qxF 'installed orca v0.1.0' && V1_SAID=1 || V1_SAID=0
  wassert 'install: pinned default reports the version it installed' test "$V1_SAID" = 1

  # ORCA_REF override: another tag ...
  PIN2="$INST_TMP/pin-tag"
  mkdir -p "$PIN2/home"
  OUTV2="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN2/clone" ORCA_REF=v0.2.0 ORCA_STYLE=claude \
      HOME="$PIN2/home" sh <"$INSTALL_SH" 2>&1)"
  RCV2=$?
  wassert 'install: ORCA_REF=<tag> exits 0' test "$RCV2" -eq 0
  wassert 'install: ORCA_REF=<tag> checks out that tag' \
    test "$(git -C "$PIN2/clone" describe --tags --exact-match 2>/dev/null)" = v0.2.0
  printf '%s' "$OUTV2" | grep -qxF 'installed orca v0.2.0' && V2_SAID=1 || V2_SAID=0
  wassert 'install: ORCA_REF=<tag> reports that tag' test "$V2_SAID" = 1

  # ... and a branch name: ORCA_REF=main is the documented development
  # setting. Its head carries no tag, so the version line names the commit.
  PIN3="$INST_TMP/pin-main"
  mkdir -p "$PIN3/home"
  OUTV3="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN3/clone" ORCA_REF=main ORCA_STYLE=claude \
      HOME="$PIN3/home" sh <"$INSTALL_SH" 2>&1)"
  RCV3=$?
  wassert 'install: ORCA_REF=main exits 0' test "$RCV3" -eq 0
  wassert 'install: ORCA_REF=main checks out the head of main' \
    test "$(git -C "$PIN3/clone" rev-parse HEAD 2>/dev/null)" = "$(git -C "$ORIGIN" rev-parse main)"
  printf '%s' "$OUTV3" | grep -qxF "installed orca $(git -C "$ORIGIN" rev-parse --short main)" &&
    V3_SAID=1 || V3_SAID=0
  wassert 'install: ORCA_REF=main reports the commit, having no tag to name' test "$V3_SAID" = 1

  # re-run on an existing checkout: moved to the pinned tag from wherever it
  # was left - here a branch, which is what the previous installer left.
  OUTV4="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN3/clone" ORCA_STYLE=claude \
      HOME="$PIN3/home" sh <"$INSTALL_SH" 2>&1)"
  RCV4=$?
  wassert 'install: re-run on an existing checkout exits 0' test "$RCV4" -eq 0
  wassert 'install: re-run moves the existing checkout to the pinned tag' \
    test "$(git -C "$PIN3/clone" describe --tags --exact-match 2>/dev/null)" = v0.1.0
  printf '%s' "$OUTV4" | grep -qxF 'installed orca v0.1.0' && V4_SAID=1 || V4_SAID=0
  wassert 'install: re-run reports the pinned version' test "$V4_SAID" = 1

  # unknown ref: exits non-zero before anything is installed - on a machine
  # with no checkout, and on one whose checkout then stays where it was.
  PIN5="$INST_TMP/pin-unknown"
  mkdir -p "$PIN5/home"
  OUTV5="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN5/clone" ORCA_REF=v9.9.9 ORCA_STYLE=claude \
      HOME="$PIN5/home" sh <"$INSTALL_SH" 2>&1)"
  RCV5=$?
  wassert 'install: unknown ORCA_REF exits non-zero' test "$RCV5" -ne 0
  wassert 'install: unknown ORCA_REF installs nothing' test ! -d "$PIN5/home/.claude"
  wassert 'install: unknown ORCA_REF leaves no checkout behind' test ! -e "$PIN5/clone"
  # our own guard line, not git's `Remote branch v9.9.9 not found` - which
  # would still be there with the guard deleted.
  printf '%s' "$OUTV5" | grep -qF 'could not clone orca v9.9.9' && V5_SAID=1 || V5_SAID=0
  wassert 'install: unknown ORCA_REF fails through the clone guard, naming the ref' test "$V5_SAID" = 1

  OUTV6="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN3/clone" ORCA_REF=v9.9.9 ORCA_STYLE=claude \
      HOME="$PIN3/home" sh <"$INSTALL_SH" 2>&1)"
  RCV6=$?
  wassert 'install: unknown ORCA_REF on an existing checkout exits non-zero' test "$RCV6" -ne 0
  # the guard's own line: with it deleted, a swallowed fetch failure would
  # reach `checkout FETCH_HEAD`, and the exit status alone would not tell.
  printf '%s' "$OUTV6" | grep -qF 'could not fetch v9.9.9' && V6_SAID=1 || V6_SAID=0
  wassert 'install: unknown ORCA_REF on an existing checkout fails through the fetch guard' \
    test "$V6_SAID" = 1
  wassert 'install: unknown ORCA_REF leaves the existing checkout where it was' \
    test "$(git -C "$PIN3/clone" describe --tags --exact-match 2>/dev/null)" = v0.1.0

  # a ref that leads with `-`: it follows `--`, so git reads it as a ref and
  # never as an option. It fails through the same guard, with no `unknown
  # switch` from git, and installs nothing into a fresh HOME.
  PIN7="$INST_TMP/pin-dash"
  mkdir -p "$PIN7/home"
  OUTV7="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN3/clone" ORCA_REF=-x ORCA_STYLE=claude \
      HOME="$PIN7/home" sh <"$INSTALL_SH" 2>&1)"
  RCV7=$?
  wassert 'install: ORCA_REF=-x exits non-zero' test "$RCV7" -ne 0
  printf '%s' "$OUTV7" | grep -qF 'could not fetch -x' && V7_SAID=1 || V7_SAID=0
  wassert 'install: ORCA_REF=-x fails through the fetch guard' test "$V7_SAID" = 1
  printf '%s' "$OUTV7" | grep -q 'unknown switch' && V7_SWITCH=1 || V7_SWITCH=0
  wassert 'install: ORCA_REF=-x reaches git as a ref, not as an option' test "$V7_SWITCH" = 0
  wassert 'install: ORCA_REF=-x installs nothing' test ! -d "$PIN7/home/.claude"

  # ORCA_URL is honoured on a re-run: the fetch goes to it, not to whatever
  # remote the checkout carries - here one with no tags at all - and the
  # checkout's own remote is left as it was.
  TAGLESS="$INST_TMP/tagless"
  PIN8="$INST_TMP/pin-url"
  mkdir -p "$PIN8/home"
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git clone -q --no-tags -- "file://$ORIGIN" "$TAGLESS"
    git clone -q --depth 1 -- "file://$TAGLESS" "$PIN8/clone"
  )
  OUTV8="$(cd "$INST_TMP" &&
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN8/clone" ORCA_STYLE=claude \
      HOME="$PIN8/home" sh <"$INSTALL_SH" 2>&1)"
  RCV8=$?
  wassert 'install: re-run against ORCA_URL exits 0 though the checkout remote lacks the tag' \
    test "$RCV8" -eq 0
  wassert 'install: re-run against ORCA_URL ends at the pinned tag' \
    test "$(git -C "$PIN8/clone" describe --tags --exact-match 2>/dev/null)" = v0.1.0
  printf '%s' "$OUTV8" | grep -qxF 'installed orca v0.1.0' && V8_SAID=1 || V8_SAID=0
  wassert 'install: re-run against ORCA_URL reports the pinned version' test "$V8_SAID" = 1
  wassert 'install: re-run leaves the checkout remote as it was' \
    test "$(git -C "$PIN8/clone" remote get-url origin)" = "file://$TAGLESS"

  # version line, non-piped path: a release tarball has no .git, and unpacked
  # inside some other repository `git describe` would walk up and report THAT
  # repository's version. Gated on the checkout's own .git, so it prints none.
  # The tagged origin above stands in for the enclosing repository.
  TARBALL="$ORIGIN/tarball"
  mkdir -p "$TARBALL"
  cp -R "$ORIGIN/agents" "$ORIGIN/hooks" "$ORIGIN/scripts" "$ORIGIN/bin" "$ORIGIN/install.sh" "$TARBALL/"
  PIN9="$INST_TMP/tarball-home"
  mkdir -p "$PIN9"
  OUTV9="$(ORCA_STYLE=claude HOME="$PIN9" sh "$TARBALL/install.sh" </dev/null 2>&1)"
  RCV9=$?
  wassert 'install: a tarball inside another repository exits 0' test "$RCV9" -eq 0
  wassert 'install: a tarball inside another repository still installs' \
    test -L "$PIN9/.claude/agents/orca.md"
  printf '%s' "$OUTV9" | grep -q 'installed orca' && V9_SAID=1 || V9_SAID=0
  wassert 'install: a tarball inside another repository prints no version line' \
    test "$V9_SAID" = 0
else
  printf 'skip: install: pinned ORCA_REF (git unavailable)\n'
fi

# ---------------------------------------------------------------------------
# install.sh --uninstall — reverses the install, and only the install
#
# The whole point of these cases is the boundary between "the installer made
# this" and "the user made this". Uninstall removes a path only when it is a
# symlink into an orca checkout at the installer's own relative path, or a
# regular file byte-identical to the source it was copied from. Anything else
# is reported on stdout and left standing, so every case below that plants a
# user-owned file asserts the file is still there afterwards.

# claude style: install, then uninstall, leaves nothing of orca's
IH6="$INST_TMP/h6"
mkdir -p "$IH6"
ORCA_STYLE=claude HOME="$IH6" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
OUTU1="$(HOME="$IH6" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
RCU1=$?
wassert 'uninstall: claude style exits 0' test "$RCU1" -eq 0
# -e is false for a DANGLING symlink, so -L is asserted too: a link left
# pointing at a removed checkout would otherwise read as "gone".
wassert 'uninstall: every installed file is gone, with no dangling link left' \
  bash -c "for f in agents/orca.md hooks/orca-start-watcher.sh scripts/gh-watch.sh; do
             test ! -e '$IH6/.claude'/\$f || exit 1; test ! -L '$IH6/.claude'/\$f || exit 1
           done"
wassert 'uninstall: the SessionStart hook is unwired' \
  test "$(jq '.hooks.SessionStart // [] | length' "$IH6/.claude/settings.json")" = 0
wassert 'uninstall: settings.json keeps no trace of orca' \
  bash -c "! grep -q orca '$IH6/.claude/settings.json'"

# running it twice must be a clean no-op, not an error
OUTU2="$(HOME="$IH6" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
RCU2=$?
wassert 'uninstall: rerun exits 0' test "$RCU2" -eq 0
printf '%s' "$OUTU2" | grep -qE 'removed:|left alone:' && UN_RERUN_CHANGED=1 || UN_RERUN_CHANGED=0
wassert 'uninstall: rerun touches nothing (idempotent)' test "$UN_RERUN_CHANGED" = 0

# a settings.json the user already had: orca's entry goes, everything else -
# other SessionStart entries, other hook types, unrelated top-level keys -
# survives with its values intact.
IH7="$INST_TMP/h7"
mkdir -p "$IH7/.claude"
cat >"$IH7/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/mine.sh" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "guard.sh" } ] }
    ]
  }
}
JSON
PRE7="$(jq -Sc 'del(.hooks.SessionStart)' "$IH7/.claude/settings.json")"
ORCA_STYLE=claude HOME="$IH7" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'uninstall: (setup) install wired orca alongside the user entry' \
  test "$(jq '.hooks.SessionStart | length' "$IH7/.claude/settings.json")" = 2
HOME="$IH7" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'uninstall: the user own SessionStart entry survives intact' \
  test "$(jq -c '.hooks.SessionStart' "$IH7/.claude/settings.json")" = '[{"hooks":[{"type":"command","command":"~/.claude/hooks/mine.sh"}]}]'
wassert 'uninstall: unrelated keys and other hook types survive intact' \
  test "$(jq -Sc 'del(.hooks.SessionStart)' "$IH7/.claude/settings.json")" = "$PRE7"
wassert 'uninstall: no orca entry is left in a shared settings.json' \
  bash -c "! grep -q orca-start-watcher '$IH7/.claude/settings.json'"

# user-owned content sitting at install paths: an edited copy and a symlink
# pointing somewhere that is not an orca checkout. Neither is ours to delete.
IH8="$INST_TMP/h8"
mkdir -p "$IH8"
ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH8" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
printf 'my own agent\n' >"$IH8/.claude/agents/orca.md"
rm -f "$IH8/.claude/scripts/gh-watch.sh"
ln -s /dev/null "$IH8/.claude/scripts/gh-watch.sh"
OUTU3="$(HOME="$IH8" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
RCU3=$?
wassert 'uninstall: exits 0 with user-owned files at install paths' test "$RCU3" -eq 0
wassert 'uninstall: a user-edited file at an install path is NOT removed' \
  bash -c "grep -q 'my own agent' '$IH8/.claude/agents/orca.md'"
wassert 'uninstall: a symlink pointing outside an orca checkout is NOT removed' \
  test "$(readlink "$IH8/.claude/scripts/gh-watch.sh")" = /dev/null
printf '%s' "$OUTU3" | grep -qF "left alone: $IH8/.claude/agents/orca.md" &&
  UN_SAID_LEFT=1 || UN_SAID_LEFT=0
wassert 'uninstall: names on stdout what it left alone' test "$UN_SAID_LEFT" = 1
# same run, same directory: a copy-mode file still byte-identical to the
# source IS ours, and goes. Provenance is per path, not per run.
wassert 'uninstall: an untouched copy-mode file is still removed' \
  bash -c "test ! -e '$IH8/.claude/hooks/orca-start-watcher.sh'"

# agents style: the watcher, the playbook, and orca's own ~/.config/orca dir
IH9="$INST_TMP/h9"
mkdir -p "$IH9"
ORCA_STYLE=agents HOME="$IH9" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH9" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
RCU4=$?
wassert 'uninstall: agents style exits 0' test "$RCU4" -eq 0
wassert 'uninstall: agents style removes the watcher and the playbook' \
  bash -c "test ! -e '$IH9/.local/bin/gh-watch' && test ! -e '$IH9/.config/orca/AGENTS.md'"
# rmdir, not rm -r: ~/.config/orca is orca's own, and only if left empty.
wassert 'uninstall: agents style removes its own empty ~/.config/orca' \
  test ! -d "$IH9/.config/orca"
wassert 'uninstall: agents style leaves ~/.local/bin standing' test -d "$IH9/.local/bin"

# custom CLAUDE_HOME: torn down where it was installed, not at ~/.claude
IH10="$INST_TMP/h10"
CH10="$INST_TMP/ch10"
mkdir -p "$IH10"
ORCA_STYLE=claude HOME="$IH10" CLAUDE_HOME="$CH10" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH10" CLAUDE_HOME="$CH10" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
RCU5=$?
wassert 'uninstall: custom CLAUDE_HOME exits 0' test "$RCU5" -eq 0
wassert 'uninstall: custom CLAUDE_HOME files are removed' \
  bash -c "test ! -e '$CH10/agents/orca.md' && test ! -e '$CH10/hooks/orca-start-watcher.sh'"
wassert 'uninstall: custom CLAUDE_HOME settings.json is unwired' \
  test "$(jq '.hooks.SessionStart // [] | length' "$CH10/settings.json")" = 0

# ...spelled with a trailing slash at uninstall time, it is still the same
# home: the installer's own entry is found and dropped, where `/x//hooks/...`
# used to find nothing and report no orca entry (#38).
IH28="$INST_TMP/h28"
CH28="$INST_TMP/ch28"
mkdir -p "$IH28"
ORCA_STYLE=claude HOME="$IH28" CLAUDE_HOME="$CH28" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH28" CLAUDE_HOME="$CH28/" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
RCU12=$?
wassert 'uninstall: CLAUDE_HOME with a trailing slash exits 0' test "$RCU12" -eq 0
wassert 'uninstall: CLAUDE_HOME with a trailing slash unwires the entry the installer wrote' \
  test "$(jq '.hooks.SessionStart // [] | length' "$CH28/settings.json")" = 0
# every trailing slash, not just one: `<dir>//` finds the entry too
ORCA_STYLE=claude HOME="$IH28" CLAUDE_HOME="$CH28" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH28" CLAUDE_HOME="$CH28//" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
RCU13=$?
wassert 'uninstall: CLAUDE_HOME with two trailing slashes exits 0' test "$RCU13" -eq 0
wassert 'uninstall: CLAUDE_HOME with two trailing slashes unwires the entry the installer wrote' \
  test "$(jq '.hooks.SessionStart // [] | length' "$CH28/settings.json")" = 0

# backups are the user's escape hatch: uninstall points at them, never
# restores blind (which run's backup would it even pick?) and never deletes.
IH11="$INST_TMP/h11"
mkdir -p "$IH11/.claude/agents"
printf 'previous agent\n' >"$IH11/.claude/agents/orca.md"
ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH11" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
OUTU4="$(HOME="$IH11" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
wassert 'uninstall: the pre-install backup is still on disk afterwards' \
  bash -c "grep -q 'previous agent' '$IH11'/.orca-backups/*/*-orca.md"
printf '%s' "$OUTU4" | grep -q '.orca-backups' && UN_BACKUP_NOTE=1 || UN_BACKUP_NOTE=0
wassert 'uninstall: points at the backup dir instead of restoring blind' \
  test "$UN_BACKUP_NOTE" = 1
printf '%s' "$OUTU4" | grep -q -- '--restore <run>' && UN_RESTORE_NOTE=1 || UN_RESTORE_NOTE=0
wassert 'uninstall: the backup note points at --restore' test "$UN_RESTORE_NOTE" = 1

# Without jq, uninstall must change no JSON at all: it prints the entry to
# delete by hand, exactly as install prints the entry to add by hand. Editing
# settings.json with sed/grep guesswork would be worse than not editing it.
# The suite itself needs jq, so jq is hidden with a PATH shim holding only the
# tools the uninstall path uses.
IH13="$INST_TMP/h13"
mkdir -p "$IH13"
NOJQ_BIN="$INST_TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
NOJQ_OK=1
for t in sh dirname readlink cmp rm rmdir mktemp date mkdir ln cp; do
  p="$(command -v "$t")" && ln -s "$p" "$NOJQ_BIN/$t" || NOJQ_OK=0
done
if [[ "$NOJQ_OK" == 1 ]]; then
  ORCA_STYLE=claude HOME="$IH13" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
  # cmp, not "$(cat x)" = "$(cat y)": command substitution strips trailing
  # newlines, so a string compare cannot see a trailing-newline-only change
  # and has no business claiming "byte-for-byte".
  cp "$IH13/.claude/settings.json" "$INST_TMP/nojq-settings.before"
  OUTU5="$(env -i PATH="$NOJQ_BIN" HOME="$IH13" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
  RCU9=$?
  wassert 'uninstall: without jq exits 0' test "$RCU9" -eq 0
  wassert 'uninstall: without jq still removes the files it owns' \
    bash -c "test ! -e '$IH13/.claude/hooks/orca-start-watcher.sh'"
  wassert 'uninstall: without jq leaves settings.json byte-for-byte identical' \
    cmp -s "$INST_TMP/nojq-settings.before" "$IH13/.claude/settings.json"
  printf '%s' "$OUTU5" | grep -qF '{"hooks":[{"type":"command","command":"~/.claude/hooks/orca-start-watcher.sh"}]}' &&
    NOJQ_TOLD=1 || NOJQ_TOLD=0
  wassert 'uninstall: without jq prints the exact entry to remove by hand' \
    test "$NOJQ_TOLD" = 1
else
  printf 'skip: uninstall: no-jq case (could not build a PATH shim)\n'
fi

# PIPED UNINSTALL MUST NOT INSTALL.
#
# `curl ... | sh -s -- --uninstall` is the documented teardown command, and
# the piped copy is the only copy that has seen the flag. If it re-executed
# the install.sh already at ~/.local/share/orca, any copy predating
# --uninstall would ignore the flag and INSTALL - the teardown command doing
# the exact opposite of what it says, in a curl | sh script. The action is
# therefore parsed BEFORE the bootstrap block, and uninstall never re-execs.
#
# The stale checkout here carries a TRIPWIRE install.sh that cannot be
# mistaken for a working one: if the bootstrap ever execs it again, it leaves
# a marker and the case fails. No git and no network are involved.
IHP="$INST_TMP/piped-un"
mkdir -p "$IHP/home"
STALE="$IHP/stale"
mkdir -p "$STALE/agents"
cp "$REPO_ROOT/agents/orca.md" "$STALE/agents/orca.md"
printf '#!/bin/sh\ntouch "%s/EXECUTED"\nexit 0\n' "$STALE" >"$STALE/install.sh"
chmod +x "$STALE/install.sh"
ORCA_STYLE=claude HOME="$IHP/home" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
# ORCA_URL is deliberately bogus: if anything tries to fetch, it fails loudly
# rather than quietly succeeding on a machine that happens to be online.
OUTP1="$(cd "$INST_TMP" &&
  ORCA_URL="file:///nonexistent-orca-remote" ORCA_REPO="$STALE" \
    HOME="$IHP/home" sh -s -- --uninstall <"$INSTALL_SH" 2>&1)"
RCP1=$?
wassert 'uninstall: piped uninstall exits 0' test "$RCP1" -eq 0
wassert 'uninstall: piped uninstall never re-execs the install.sh on disk' \
  test ! -e "$STALE/EXECUTED"
wassert 'uninstall: piped uninstall UNINSTALLS (does not install)' \
  bash -c "test ! -e '$IHP/home/.claude/agents/orca.md' && test ! -L '$IHP/home/.claude/agents/orca.md'"
wassert 'uninstall: piped uninstall unwires the hook rather than wiring it' \
  test "$(jq '.hooks.SessionStart // [] | length' "$IHP/home/.claude/settings.json")" = 0
# Anchored: an unanchored `wired:` also matches uninstall's own `unwired:`.
printf '%s' "$OUTP1" | grep -qE '^ +(installed|wired):' && PIPED_INSTALLED=1 || PIPED_INSTALLED=0
wassert 'uninstall: piped uninstall reports no install activity at all' \
  test "$PIPED_INSTALLED" = 0

# ...and with no checkout anywhere it must still not fetch one: a teardown
# that needs the network (or git) is broken by design.
IHP2="$INST_TMP/piped-un2"
mkdir -p "$IHP2/home"
ORCA_STYLE=claude HOME="$IHP2/home" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
(cd "$INST_TMP" &&
  ORCA_URL="file:///nonexistent-orca-remote" ORCA_REPO="$IHP2/absent" \
    HOME="$IHP2/home" sh -s -- --uninstall <"$INSTALL_SH" >/dev/null 2>&1)
RCP2=$?
wassert 'uninstall: piped uninstall with no checkout exits 0' test "$RCP2" -eq 0
wassert 'uninstall: piped uninstall clones nothing' test ! -e "$IHP2/absent"
wassert 'uninstall: piped uninstall still removes symlinks without a checkout' \
  bash -c "test ! -L '$IHP2/home/.claude/hooks/orca-start-watcher.sh'"

# provenance, anchored: install only ever writes ABSOLUTE symlinks, so a
# RELATIVE target cannot be one of ours. Unanchored, `./agents/orca.md`
# resolves against the uninstaller's cwd, and the check silently degrades to
# "am I being run from inside a checkout?" - which the documented invocation
# always is. This case runs from $REPO_ROOT, the worst case for that bug.
IH14="$INST_TMP/h14"
mkdir -p "$IH14/.claude/agents"
ln -s ./agents/orca.md "$IH14/.claude/agents/orca.md"
(cd "$REPO_ROOT" && HOME="$IH14" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1)
wassert 'uninstall: a RELATIVE symlink target is never ours, even from a checkout' \
  test "$(readlink "$IH14/.claude/agents/orca.md")" = ./agents/orca.md

# ...and an absolute link whose root is NOT a checkout is not ours either:
# the root must carry agents/orca.md AND install.sh, not just the one file
# the link happens to name.
IH15="$INST_TMP/h15"
mkdir -p "$IH15/.claude/agents"
FAKEROOT="$INST_TMP/fakeroot"
mkdir -p "$FAKEROOT/agents"
cp "$REPO_ROOT/agents/orca.md" "$FAKEROOT/agents/orca.md" # no install.sh at the root
ln -s "$FAKEROOT/agents/orca.md" "$IH15/.claude/agents/orca.md"
HOME="$IH15" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'uninstall: an absolute link into a NON-checkout root is not ours' \
  test "$(readlink "$IH15/.claude/agents/orca.md")" = "$FAKEROOT/agents/orca.md"

# The other half of that rule: a link into a REAL checkout that is not the
# one uninstalling IS ours. This is the piped case (uninstall run from a
# different copy than the install came from), so it must not need an exact
# $ORCA_REPO match. A minimal second checkout stands in for it.
REPO2="$INST_TMP/repo2"
mkdir -p "$REPO2/agents" "$REPO2/hooks" "$REPO2/scripts" "$REPO2/bin"
cp "$INSTALL_SH" "$REPO2/install.sh"
cp "$REPO_ROOT/agents/orca.md" "$REPO2/agents/orca.md"
cp "$HOOKS_DIR/orca-start-watcher.sh" "$REPO2/hooks/orca-start-watcher.sh"
cp "$WATCH_SCRIPT" "$REPO2/scripts/gh-watch.sh"
cp "$LAUNCHER" "$REPO2/bin/orca"
IH16="$INST_TMP/h16"
mkdir -p "$IH16"
ORCA_STYLE=claude HOME="$IH16" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH16" sh "$REPO2/install.sh" --uninstall </dev/null >/dev/null 2>&1
RCU10=$?
wassert 'uninstall: from a different checkout exits 0' test "$RCU10" -eq 0
wassert 'uninstall: a link into ANOTHER real checkout is still ours to remove' \
  bash -c "test ! -L '$IH16/.claude/agents/orca.md' && test ! -L '$IH16/.claude/scripts/gh-watch.sh'"

# A settings.json with no orca entry must not be rewritten AT ALL - not even
# reformatted. It has a SessionStart array (so the jq filter would happily
# run and normalize the file) and deliberately compact formatting, which is
# what makes the "nothing to remove -> do not touch it" short-circuit visible.
IH17="$INST_TMP/h17"
mkdir -p "$IH17/.claude"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"mine.sh"}]}]},"model":"opus"}' \
  >"$IH17/.claude/settings.json"
cp "$IH17/.claude/settings.json" "$INST_TMP/h17-settings.before"
HOME="$IH17" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'uninstall: a settings.json with nothing of ours is not rewritten at all' \
  cmp -s "$INST_TMP/h17-settings.before" "$IH17/.claude/settings.json"

# Best effort, not fail-fast: one unremovable file must not abort the sweep.
# Everything after it still gets done, what stayed is named, and the exit
# status reports the shortfall (root bypasses mode bits, so skip there).
IH18="$INST_TMP/h18"
mkdir -p "$IH18"
ORCA_STYLE=claude HOME="$IH18" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
chmod 500 "$IH18/.claude/agents"
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip: uninstall: unremovable file (root bypasses mode bits)\n'
else
  OUTU6="$(HOME="$IH18" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
  RCU11=$?
  wassert 'uninstall: an unremovable file exits 1, not 0' test "$RCU11" -eq 1
  wassert 'uninstall: the sweep continues past it (later files still removed)' \
    bash -c "test ! -e '$IH18/.claude/scripts/gh-watch.sh'"
  wassert 'uninstall: the sweep continues past it (hook still unwired)' \
    test "$(jq '.hooks.SessionStart // [] | length' "$IH18/.claude/settings.json")" = 0
  printf '%s' "$OUTU6" | grep -q 'item(s) are still installed' && UN_SUMMARY=1 || UN_SUMMARY=0
  wassert 'uninstall: reports how much was left behind' test "$UN_SUMMARY" = 1
fi
chmod u+rwx "$IH18/.claude/agents"

# HOME empty, unset, or naming the filesystem root would make every target an
# absolute path under / - refuse before removing anything. `/.` and `//` are
# the same place spelled differently, and a pattern match alone misses them.
UNOUT1="$(HOME= sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
RCU6=$?
wassert 'uninstall: empty HOME exits 1, removes nothing' test "$RCU6" -eq 1
printf '%s' "$UNOUT1" | grep -q 'refusing to uninstall' && UN_REFUSED=1 || UN_REFUSED=0
wassert 'uninstall: empty HOME says why it refused' test "$UN_REFUSED" = 1
UNOUT2="$(env -u HOME sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
RCU7=$?
wassert 'uninstall: unset HOME exits 1, removes nothing' test "$RCU7" -eq 1
for badhome in / // /. /tmp/..; do
  HOME="$badhome" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
  wassert "uninstall: HOME=$badhome is refused (exit 1)" test "$?" -eq 1
done

# A typo'd flag must not silently fall through to installing. ORCA_STYLE is
# set so a regression here would INSTALL (and be caught below) rather than
# exit 2 down the no-style path, which would mask the bug behind the same
# exit code; the message is asserted for the same reason.
IH12="$INST_TMP/h12"
mkdir -p "$IH12"
UNOUT3="$(ORCA_STYLE=claude HOME="$IH12" sh "$INSTALL_SH" --uninstal </dev/null 2>&1)"
RCU8=$?
wassert 'install: an unrecognized option exits 2' test "$RCU8" -eq 2
printf '%s' "$UNOUT3" | grep -q 'unrecognized option: --uninstal' && UN_BADOPT=1 || UN_BADOPT=0
wassert 'install: an unrecognized option names the option it rejected' test "$UN_BADOPT" = 1
wassert 'install: an unrecognized option installs nothing' test ! -d "$IH12/.claude"

# ---------------------------------------------------------------------------
# install.sh — backup manifest and --restore
#
# Every file backup() moves aside gets a numbered name in the run directory
# and a MANIFEST line `<name><TAB><absolute origin>`, so a later --restore
# can put it back exactly where it came from. --restore is opt-in: it names
# one run, copies back only onto absent paths, never overwrites, and never
# touches settings.json. Hermetic like everything above: temp HOMEs, no
# network, and the piped case runs against the same tripwire checkout.

# claude style over a HOME where every install target already exists, plus a
# settings.json that needs the hook wired: four entries, in install order,
# each naming the absolute path it came from. cmp against the exact expected
# file, so the numbering, the tab and the origins are all asserted at once.
IM1="$INST_TMP/m1"
mkdir -p "$IM1/.claude/agents" "$IM1/.claude/hooks" "$IM1/.claude/scripts"
printf 'previous agent\n' >"$IM1/.claude/agents/orca.md"
printf 'previous hook\n' >"$IM1/.claude/hooks/orca-start-watcher.sh"
printf 'previous watcher\n' >"$IM1/.claude/scripts/gh-watch.sh"
printf '{\n  "model": "opus",\n  "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "mine.sh"}]}]}\n}\n' \
  >"$IM1/.claude/settings.json"
cp "$IM1/.claude/settings.json" "$INST_TMP/m1-settings.before"
OUTM1="$(ORCA_STYLE=claude HOME="$IM1" sh "$INSTALL_SH" </dev/null 2>&1)"
RCM1=$?
wassert 'manifest: (setup) claude-style install over existing files exits 0' test "$RCM1" -eq 0
M1_RUN="$(ls "$IM1/.orca-backups" 2>/dev/null)"
wassert 'manifest: one install makes exactly one run directory' \
  test "$(printf '%s\n' "$M1_RUN" | grep -c .)" -eq 1
printf '01-orca.md\t%s\n02-orca-start-watcher.sh\t%s\n03-gh-watch.sh\t%s\n04-settings.json\t%s\n' \
  "$IM1/.claude/agents/orca.md" "$IM1/.claude/hooks/orca-start-watcher.sh" \
  "$IM1/.claude/scripts/gh-watch.sh" "$IM1/.claude/settings.json" >"$INST_TMP/m1-manifest.expected"
wassert 'manifest: claude style records numbered names and absolute origins, tab-separated' \
  cmp -s "$INST_TMP/m1-manifest.expected" "$IM1/.orca-backups/$M1_RUN/MANIFEST"
wassert 'manifest: the backup copies hold the previous contents under their numbered names' \
  bash -c "grep -q 'previous agent' '$IM1/.orca-backups/$M1_RUN/01-orca.md' \
        && grep -q 'previous hook' '$IM1/.orca-backups/$M1_RUN/02-orca-start-watcher.sh' \
        && grep -q 'previous watcher' '$IM1/.orca-backups/$M1_RUN/03-gh-watch.sh'"
printf '%s' "$OUTM1" | grep -qF "replaced files moved to $IM1/.orca-backups/$M1_RUN (after --uninstall, --restore $M1_RUN puts them back)" &&
  M1_SAID=1 || M1_SAID=0
wassert 'manifest: install names the run and how to put it back' test "$M1_SAID" = 1
# The settings.json edit starts from the backup copy, not from an empty file:
# the backup IS the pre-install file byte-for-byte, and the wired file still
# carries everything that was in it. This is the caller that used to assume
# $BACKUP_DIR/settings.json - a name that no longer exists.
wassert 'manifest: the settings.json backup is the pre-install file byte-for-byte' \
  cmp -s "$INST_TMP/m1-settings.before" "$IM1/.orca-backups/$M1_RUN/04-settings.json"
wassert 'manifest: the settings.json edit kept the user model key' \
  test "$(jq -r .model "$IM1/.claude/settings.json")" = opus
wassert 'manifest: the settings.json edit kept the user SessionStart entry beside orca' \
  test "$(jq '.hooks.SessionStart | length' "$IM1/.claude/settings.json")" = 2

# agents style: the playbook's destination is AGENTS.md, which shares no
# basename with the orca.md it is installed from - the case that made a
# basename-only backup impossible to restore.
IM2="$INST_TMP/m2"
mkdir -p "$IM2/.local/bin" "$IM2/.config/orca"
printf 'previous watcher\n' >"$IM2/.local/bin/gh-watch"
printf 'previous playbook\n' >"$IM2/.config/orca/AGENTS.md"
ORCA_STYLE=agents HOME="$IM2" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
M2_RUN="$(ls "$IM2/.orca-backups" 2>/dev/null)"
printf '01-gh-watch\t%s\n02-AGENTS.md\t%s\n' "$IM2/.local/bin/gh-watch" "$IM2/.config/orca/AGENTS.md" \
  >"$INST_TMP/m2-manifest.expected"
wassert 'manifest: agents style records its own destinations (AGENTS.md, not orca.md)' \
  cmp -s "$INST_TMP/m2-manifest.expected" "$IM2/.orca-backups/$M2_RUN/MANIFEST"

# custom CLAUDE_HOME: the origin is the custom path, never the ~/.claude
# default; the run directory itself still lives under $HOME.
IM3="$INST_TMP/m3"
CM3="$INST_TMP/cm3"
mkdir -p "$IM3" "$CM3/agents"
printf 'previous agent\n' >"$CM3/agents/orca.md"
ORCA_STYLE=claude HOME="$IM3" CLAUDE_HOME="$CM3" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
M3_RUN="$(ls "$IM3/.orca-backups" 2>/dev/null)"
printf '01-orca.md\t%s\n' "$CM3/agents/orca.md" >"$INST_TMP/m3-manifest.expected"
wassert 'manifest: a custom CLAUDE_HOME is recorded as the origin, not ~/.claude' \
  cmp -s "$INST_TMP/m3-manifest.expected" "$IM3/.orca-backups/$M3_RUN/MANIFEST"

# Two files sharing a basename. No two install targets do today, so the
# collision the numbering exists for is proven on backup() itself: the block
# from TS= through the end of the function is lifted out of install.sh and
# driven directly under a temp HOME.
IM4="$INST_TMP/m4"
mkdir -p "$IM4/a" "$IM4/b"
printf 'from a\n' >"$IM4/a/same.md"
printf 'from b\n' >"$IM4/b/same.md"
BACKUP_UNIT="$(sed -n '/^TS=/,/^}/p' "$INSTALL_SH")"
HOME="$IM4" sh -c "set -eu; $BACKUP_UNIT; backup '$IM4/a/same.md'; backup '$IM4/b/same.md'" \
  >/dev/null 2>&1
RCM4=$?
wassert 'manifest: (setup) backup() ran on two files sharing a basename' test "$RCM4" -eq 0
M4_RUN="$(ls "$IM4/.orca-backups" 2>/dev/null)"
wassert 'manifest: two files sharing a basename get distinct names, neither overwritten' \
  bash -c "grep -q 'from a' '$IM4/.orca-backups/$M4_RUN/01-same.md' \
        && grep -q 'from b' '$IM4/.orca-backups/$M4_RUN/02-same.md'"
printf '01-same.md\t%s\n02-same.md\t%s\n' "$IM4/a/same.md" "$IM4/b/same.md" >"$INST_TMP/m4-manifest.expected"
wassert 'manifest: each is mapped back to its own origin' \
  cmp -s "$INST_TMP/m4-manifest.expected" "$IM4/.orca-backups/$M4_RUN/MANIFEST"

# --restore <run>, claude style: install over existing files (m1 above),
# uninstall, put the run back. The three files return with their previous
# contents as regular files; settings.json is named and left exactly as
# uninstall left it; the backup copies stay on disk.
HOME="$IM1" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
cp "$IM1/.claude/settings.json" "$INST_TMP/m1-settings.after-uninstall"
wassert 'restore: (setup) uninstall removed the installed files' \
  bash -c "test ! -e '$IM1/.claude/agents/orca.md' && test ! -e '$IM1/.claude/hooks/orca-start-watcher.sh'"
OUTR1="$(HOME="$IM1" sh "$INSTALL_SH" --restore "$M1_RUN" </dev/null 2>&1)"
RCR1=$?
wassert 'restore: a known run exits 0' test "$RCR1" -eq 0
wassert 'restore: absent files come back with their previous contents' \
  bash -c "grep -q 'previous agent' '$IM1/.claude/agents/orca.md' \
        && grep -q 'previous hook' '$IM1/.claude/hooks/orca-start-watcher.sh' \
        && grep -q 'previous watcher' '$IM1/.claude/scripts/gh-watch.sh'"
wassert 'restore: a restored file is a regular file, not a link into the backup' \
  bash -c "test -f '$IM1/.claude/agents/orca.md' && test ! -L '$IM1/.claude/agents/orca.md'"
wassert 'restore: settings.json is left exactly as uninstall left it' \
  cmp -s "$INST_TMP/m1-settings.after-uninstall" "$IM1/.claude/settings.json"
printf '%s' "$OUTR1" | grep -qF "not restored: $IM1/.orca-backups/$M1_RUN/04-settings.json" &&
  R1_NAMED=1 || R1_NAMED=0
wassert 'restore: names the settings.json backup it did not restore' test "$R1_NAMED" = 1
printf '%s' "$OUTR1" | grep -q -- '--uninstall removes the hook' && R1_WHY=1 || R1_WHY=0
wassert 'restore: says the hook entry is --uninstall business and the rest a manual merge' \
  test "$R1_WHY" = 1
wassert 'restore: the backup copies stay on disk (copy, not move)' \
  bash -c "test -f '$IM1/.orca-backups/$M1_RUN/01-orca.md' && test -f '$IM1/.orca-backups/$M1_RUN/MANIFEST'"

# a second restore of the same run finds everything in place: all skips, no
# change, exit 0
OUTR2="$(HOME="$IM1" sh "$INSTALL_SH" --restore "$M1_RUN" </dev/null 2>&1)"
RCR2=$?
wassert 'restore: rerun exits 0' test "$RCR2" -eq 0
# Anchored: an unanchored `restored:` also matches the `not restored:` line
# that names the settings.json backup.
printf '%s' "$OUTR2" | grep -qE '^ +restored:' && R2_CHANGED=1 || R2_CHANGED=0
wassert 'restore: rerun restores nothing (everything is in place)' test "$R2_CHANGED" = 0

# ...and an ABSENT settings.json is still not put back. With the file in
# place the exists-check alone would skip it; this is the case that proves
# the whole-file revert stays a manual step and not a side effect of a
# missing path.
mv "$IM1/.claude/settings.json" "$INST_TMP/m1-settings.aside"
HOME="$IM1" sh "$INSTALL_SH" --restore "$M1_RUN" </dev/null >/dev/null 2>&1
RCR2B=$?
wassert 'restore: an absent settings.json is still not restored' test ! -e "$IM1/.claude/settings.json"
wassert 'restore: an absent settings.json is not an error' test "$RCR2B" -eq 0
mv "$INST_TMP/m1-settings.aside" "$IM1/.claude/settings.json"

# never overwrites: a file already at an origin path stays and is reported;
# the absent files in the same run are still put back.
IM5="$INST_TMP/m5"
mkdir -p "$IM5/.claude/agents" "$IM5/.claude/hooks"
printf 'previous agent\n' >"$IM5/.claude/agents/orca.md"
printf 'previous hook\n' >"$IM5/.claude/hooks/orca-start-watcher.sh"
ORCA_STYLE=claude HOME="$IM5" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IM5" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
printf 'mine now\n' >"$IM5/.claude/agents/orca.md"
M5_RUN="$(ls "$IM5/.orca-backups" 2>/dev/null)"
OUTR3="$(HOME="$IM5" sh "$INSTALL_SH" --restore "$M5_RUN" </dev/null 2>&1)"
RCR3=$?
wassert 'restore: exits 0 when some origin paths already exist' test "$RCR3" -eq 0
wassert 'restore: a file already at an origin path is never overwritten' \
  bash -c "grep -q 'mine now' '$IM5/.claude/agents/orca.md'"
printf '%s' "$OUTR3" | grep -qF "skipped: exists - $IM5/.claude/agents/orca.md" && R3_SKIP=1 || R3_SKIP=0
wassert 'restore: reports the file it left alone as skipped: exists' test "$R3_SKIP" = 1
wassert 'restore: the absent files in the same run are still put back' \
  bash -c "grep -q 'previous hook' '$IM5/.claude/hooks/orca-start-watcher.sh'"

# agents style, end to end: install over a user's own AGENTS.md and gh-watch,
# uninstall (which rmdirs the emptied ~/.config/orca), restore. Both come
# back, AGENTS.md under its own name, with the directory recreated.
HOME="$IM2" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'restore: (setup) agents-style uninstall removed ~/.config/orca' test ! -d "$IM2/.config/orca"
HOME="$IM2" sh "$INSTALL_SH" --restore "$M2_RUN" </dev/null >/dev/null 2>&1
RCR4=$?
wassert 'restore: agents style exits 0' test "$RCR4" -eq 0
wassert 'restore: AGENTS.md goes back under its own name, its directory recreated' \
  bash -c "grep -q 'previous playbook' '$IM2/.config/orca/AGENTS.md'"
wassert 'restore: the agents-style watcher goes back too' \
  bash -c "grep -q 'previous watcher' '$IM2/.local/bin/gh-watch'"

# an unknown run: non-zero, named, and nothing changes
IM6="$INST_TMP/m6"
mkdir -p "$IM6"
OUTR5="$(HOME="$IM6" sh "$INSTALL_SH" --restore 19700101-000000 </dev/null 2>&1)"
RCR5=$?
wassert 'restore: an unknown run exits non-zero' test "$RCR5" -ne 0
printf '%s' "$OUTR5" | grep -q 'unknown run: 19700101-000000' && R5_SAID=1 || R5_SAID=0
wassert 'restore: an unknown run is named in the error' test "$R5_SAID" = 1
wassert 'restore: an unknown run changes nothing' test -z "$(ls -A "$IM6")"

# the no-argument form lists the runs and their manifest entries, and
# restores nothing
rm -f "$IM5/.claude/hooks/orca-start-watcher.sh"
OUTR6="$(HOME="$IM5" sh "$INSTALL_SH" --restore </dev/null 2>&1)"
RCR6=$?
wassert 'restore: the no-argument form exits 0' test "$RCR6" -eq 0
printf '%s' "$OUTR6" | grep -qxF "  $M5_RUN" && R6_RUN=1 || R6_RUN=0
wassert 'restore: the no-argument form lists the run' test "$R6_RUN" = 1
printf '%s' "$OUTR6" | grep -qF "01-orca.md -> $IM5/.claude/agents/orca.md" && R6_ENTRY=1 || R6_ENTRY=0
wassert 'restore: the no-argument form lists each manifest entry with its origin' test "$R6_ENTRY" = 1
wassert 'restore: the no-argument form restores nothing' \
  test ! -e "$IM5/.claude/hooks/orca-start-watcher.sh"

# a run made before the manifest existed: listed as not restorable, and
# naming it exits non-zero without touching anything
mkdir -p "$IM6/.orca-backups/20200101-000000"
printf 'old\n' >"$IM6/.orca-backups/20200101-000000/orca.md"
OUTR7="$(HOME="$IM6" sh "$INSTALL_SH" --restore </dev/null 2>&1)"
printf '%s' "$OUTR7" | grep -q 'no manifest: restore by hand' && R7_SAID=1 || R7_SAID=0
wassert 'restore: a run with no manifest is listed as restore by hand' test "$R7_SAID" = 1
OUTR8="$(HOME="$IM6" sh "$INSTALL_SH" --restore 20200101-000000 </dev/null 2>&1)"
RCR8=$?
wassert 'restore: a run with no manifest exits non-zero' test "$RCR8" -ne 0
printf '%s' "$OUTR8" | grep -q 'no manifest' && R8_SAID=1 || R8_SAID=0
wassert 'restore: a run with no manifest says so' test "$R8_SAID" = 1
wassert 'restore: a run with no manifest changes nothing' test ! -d "$IM6/.claude"

# Like --uninstall, --restore is parsed before the bootstrap block and never
# clones, fetches or re-execs: the same tripwire checkout catches a regression.
rm -f "$STALE/EXECUTED"
OUTP3="$(cd "$INST_TMP" &&
  ORCA_URL="file:///nonexistent-orca-remote" ORCA_REPO="$STALE" \
    HOME="$IM5" sh -s -- --restore <"$INSTALL_SH" 2>&1)"
RCP3=$?
wassert 'restore: piped --restore exits 0' test "$RCP3" -eq 0
wassert 'restore: piped --restore never re-execs the install.sh on disk' test ! -e "$STALE/EXECUTED"
printf '%s' "$OUTP3" | grep -qxF "  $M5_RUN" && P3_LISTED=1 || P3_LISTED=0
wassert 'restore: piped --restore lists the runs' test "$P3_LISTED" = 1
(cd "$INST_TMP" && ORCA_URL="file:///nonexistent-orca-remote" ORCA_REPO="$IM5/absent" \
  HOME="$IM5" sh -s -- --restore "$M5_RUN" <"$INSTALL_SH" >/dev/null 2>&1)
RCP4=$?
wassert 'restore: piped --restore <run> with no checkout exits 0' test "$RCP4" -eq 0
wassert 'restore: piped --restore clones nothing' test ! -e "$IM5/absent"
wassert 'restore: piped --restore <run> puts the file back' \
  bash -c "grep -q 'previous hook' '$IM5/.claude/hooks/orca-start-watcher.sh'"

# the same $HOME guard as uninstall: refuse before building a single path
UNOUT5="$(HOME= sh "$INSTALL_SH" --restore </dev/null 2>&1)"
RCR9=$?
wassert 'restore: empty HOME exits 1' test "$RCR9" -eq 1
printf '%s' "$UNOUT5" | grep -q 'refusing to restore' && R9_REFUSED=1 || R9_REFUSED=0
wassert 'restore: empty HOME says why it refused' test "$R9_REFUSED" = 1

# one action per run, and a flag is never a run name: `--restore --uninstall`
# used to take `--uninstall` as the run name, and `--uninstall --restore`
# silently let the last flag win. ORCA_STYLE is set so a fall-through would
# INSTALL and be caught, not exit 2 down the no-style path.
IM12="$INST_TMP/m12"
mkdir -p "$IM12"
OUTA1="$(ORCA_STYLE=claude HOME="$IM12" sh "$INSTALL_SH" --restore --uninstall </dev/null 2>&1)"
RCA1=$?
wassert 'install: --restore --uninstall exits 2' test "$RCA1" -eq 2
printf '%s' "$OUTA1" | grep -qF 'use one of --uninstall, --restore' && A1_SAID=1 || A1_SAID=0
wassert 'install: --restore --uninstall names the conflict' test "$A1_SAID" = 1
wassert 'install: --restore --uninstall installs nothing' test ! -d "$IM12/.claude"
ORCA_STYLE=claude HOME="$IM12" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
OUTA2="$(HOME="$IM12" sh "$INSTALL_SH" --uninstall --restore </dev/null 2>&1)"
RCA2=$?
wassert 'install: --uninstall --restore exits 2' test "$RCA2" -eq 2
printf '%s' "$OUTA2" | grep -qF 'use one of --uninstall, --restore' && A2_SAID=1 || A2_SAID=0
wassert 'install: --uninstall --restore names the conflict' test "$A2_SAID" = 1
wassert 'install: --uninstall --restore uninstalls nothing' test -L "$IM12/.claude/agents/orca.md"
OUTA3="$(HOME="$IM12" sh "$INSTALL_SH" --restore --uninstal </dev/null 2>&1)"
RCA3=$?
wassert 'install: --restore --uninstal exits 2' test "$RCA3" -eq 2
printf '%s' "$OUTA3" | grep -qF 'unrecognized option: --uninstal' && A3_SAID=1 || A3_SAID=0
wassert 'install: a flag after --restore is an unrecognized option, not a run name' test "$A3_SAID" = 1

# the run is a directory NAME: `..` and `x/..` would reach a MANIFEST outside
# ~/.orca-backups/. One is planted where each spelling resolves.
IM13="$INST_TMP/m13"
mkdir -p "$IM13/.orca-backups/2020/x"
printf 'planted\t%s\n' "$IM13/pwned" >"$IM13/MANIFEST"
printf 'payload\n' >"$IM13/planted"
printf 'planted\t%s\n' "$IM13/pwned2" >"$IM13/.orca-backups/2020/x/MANIFEST"
printf 'payload\n' >"$IM13/.orca-backups/2020/x/planted"
OUTR12="$(HOME="$IM13" sh "$INSTALL_SH" --restore .. </dev/null 2>&1)"
RCR12=$?
wassert 'restore: a run name of .. exits non-zero' test "$RCR12" -ne 0
printf '%s' "$OUTR12" | grep -qF 'invalid run name: ..' && R12_SAID=1 || R12_SAID=0
wassert 'restore: a run name of .. is refused as a name' test "$R12_SAID" = 1
wassert 'restore: a run name of .. writes nothing' test ! -e "$IM13/pwned"
OUTR13="$(HOME="$IM13" sh "$INSTALL_SH" --restore 2020/x </dev/null 2>&1)"
RCR13=$?
wassert 'restore: a run name with a slash exits non-zero' test "$RCR13" -ne 0
printf '%s' "$OUTR13" | grep -qF 'invalid run name: 2020/x' && R13_SAID=1 || R13_SAID=0
wassert 'restore: a run name with a slash is refused as a name' test "$R13_SAID" = 1
wassert 'restore: a run name with a slash writes nothing' test ! -e "$IM13/pwned2"

# manifest fields are checked, not trusted. A name with `/` reads outside the
# run, an empty name (a blank line) names nothing, and a relative origin
# lands wherever --restore is run from - so these run from $INST_TMP and the
# relative case asserts nothing appeared there. Each is refused, counted in
# the exit status, and skipped; a good line after a bad one still goes back.
IM14="$INST_TMP/m14"
mkdir -p "$IM14/.orca-backups/r1" "$IM14/.orca-backups/r2" "$IM14/.orca-backups/r3" "$IM14/.orca-backups/r4"
printf 'payload\n' >"$IM14/planted"
printf '../../planted\t%s\n' "$IM14/pwned3" >"$IM14/.orca-backups/r1/MANIFEST"
printf '\n' >"$IM14/.orca-backups/r2/MANIFEST"
printf '01-x\trelative/pwned5\n' >"$IM14/.orca-backups/r3/MANIFEST"
printf 'payload\n' >"$IM14/.orca-backups/r3/01-x"
printf '../../planted\t%s\n01-good\t%s\n' "$IM14/pwned6" "$IM14/restored-ok" >"$IM14/.orca-backups/r4/MANIFEST"
printf 'good\n' >"$IM14/.orca-backups/r4/01-good"
OUTR14="$(cd "$INST_TMP" && HOME="$IM14" sh "$INSTALL_SH" --restore r1 </dev/null 2>&1)"
RCR14=$?
wassert 'restore: a manifest name with a slash exits non-zero' test "$RCR14" -ne 0
printf '%s' "$OUTR14" | grep -qF '! bad manifest line, not restored: ../../planted' && R14_SAID=1 || R14_SAID=0
wassert 'restore: a manifest name with a slash is reported as a bad line' test "$R14_SAID" = 1
wassert 'restore: a manifest name with a slash writes nothing' test ! -e "$IM14/pwned3"
OUTR15="$(cd "$INST_TMP" && HOME="$IM14" sh "$INSTALL_SH" --restore r2 </dev/null 2>&1)"
RCR15=$?
wassert 'restore: an empty manifest name exits non-zero' test "$RCR15" -ne 0
printf '%s' "$OUTR15" | grep -qF '! bad manifest line' && R15_SAID=1 || R15_SAID=0
wassert 'restore: an empty manifest name is reported as a bad line' test "$R15_SAID" = 1
(cd "$INST_TMP" && HOME="$IM14" sh "$INSTALL_SH" --restore r3 </dev/null >/dev/null 2>&1)
RCR16=$?
wassert 'restore: a relative manifest origin exits non-zero' test "$RCR16" -ne 0
wassert 'restore: a relative manifest origin writes nothing, not even under the cwd' \
  test ! -e "$INST_TMP/relative/pwned5"
(cd "$INST_TMP" && HOME="$IM14" sh "$INSTALL_SH" --restore r4 </dev/null >/dev/null 2>&1)
RCR17=$?
wassert 'restore: one bad line still fails the run' test "$RCR17" -ne 0
wassert 'restore: a bad line is skipped and the good line after it still goes back' \
  bash -c "test ! -e '$IM14/pwned6' && grep -q good '$IM14/restored-ok'"

# a relative CLAUDE_HOME: the origin is recorded absolute, anchored to the
# directory install ran from, so --restore run from anywhere else still
# lands it there and never under its own cwd.
IM8="$INST_TMP/m8"
mkdir -p "$IM8/cwd/relch/agents"
printf 'previous agent\n' >"$IM8/cwd/relch/agents/orca.md"
(cd "$IM8/cwd" && ORCA_STYLE=claude HOME="$IM8" CLAUDE_HOME=relch sh "$INSTALL_SH" </dev/null >/dev/null 2>&1)
M8_RUN="$(ls "$IM8/.orca-backups" 2>/dev/null)"
printf '01-orca.md\t%s\n' "$IM8/cwd/relch/agents/orca.md" >"$INST_TMP/m8-manifest.expected"
wassert 'manifest: a relative CLAUDE_HOME is recorded as an absolute origin' \
  cmp -s "$INST_TMP/m8-manifest.expected" "$IM8/.orca-backups/$M8_RUN/MANIFEST"
(cd "$IM8/cwd" && HOME="$IM8" CLAUDE_HOME=relch sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1)
(cd "$INST_TMP" && HOME="$IM8" sh "$INSTALL_SH" --restore "$M8_RUN" </dev/null >/dev/null 2>&1)
wassert 'restore: a relative-CLAUDE_HOME backup goes back where it came from, not under the cwd' \
  bash -c "grep -q 'previous agent' '$IM8/cwd/relch/agents/orca.md' && test ! -e '$INST_TMP/relch'"

# a backed-up symlink returns as a symlink with the same target - the
# common case is a link left by an install from another checkout. A plain
# cp would follow it and put back a regular file holding the target's bytes.
IM9="$INST_TMP/m9"
mkdir -p "$IM9/.claude/agents" "$IM9/mine"
printf 'my agent\n' >"$IM9/mine/agent.md"
ln -s "$IM9/mine/agent.md" "$IM9/.claude/agents/orca.md"
ORCA_STYLE=claude HOME="$IM9" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IM9" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
M9_RUN="$(ls "$IM9/.orca-backups" 2>/dev/null)"
HOME="$IM9" sh "$INSTALL_SH" --restore "$M9_RUN" </dev/null >/dev/null 2>&1
RCR18=$?
wassert 'restore: a backed-up symlink exits 0' test "$RCR18" -eq 0
wassert 'restore: a backed-up symlink comes back as a symlink, not a copy of its target' \
  test -L "$IM9/.claude/agents/orca.md"
wassert 'restore: the restored symlink keeps its original target' \
  test "$(readlink "$IM9/.claude/agents/orca.md")" = "$IM9/mine/agent.md"

# a dangling symlink at an origin is still "something there": -e alone
# would miss it, and the copy would then write over or through it.
IM11="$INST_TMP/m11"
mkdir -p "$IM11/.claude/hooks"
printf 'previous hook\n' >"$IM11/.claude/hooks/orca-start-watcher.sh"
ORCA_STYLE=claude HOME="$IM11" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IM11" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
ln -s /nonexistent-orca-target "$IM11/.claude/hooks/orca-start-watcher.sh"
M11_RUN="$(ls "$IM11/.orca-backups" 2>/dev/null)"
OUTR19="$(HOME="$IM11" sh "$INSTALL_SH" --restore "$M11_RUN" </dev/null 2>&1)"
RCR19=$?
wassert 'restore: a dangling symlink at an origin exits 0' test "$RCR19" -eq 0
wassert 'restore: a dangling symlink at an origin is left untouched' \
  test "$(readlink "$IM11/.claude/hooks/orca-start-watcher.sh")" = /nonexistent-orca-target
printf '%s' "$OUTR19" | grep -qF "skipped: exists - $IM11/.claude/hooks/orca-start-watcher.sh" &&
  R19_SKIP=1 || R19_SKIP=0
wassert 'restore: a dangling symlink at an origin is reported as skipped: exists' test "$R19_SKIP" = 1

# Best effort, not fail-fast: a copy that fails is named, the sweep goes on,
# and the exit status reports it - the mirror of uninstall's unremovable
# file above (root bypasses mode bits, so skip there).
IM10="$INST_TMP/m10"
mkdir -p "$IM10/.claude/agents" "$IM10/.claude/hooks"
printf 'previous agent\n' >"$IM10/.claude/agents/orca.md"
printf 'previous hook\n' >"$IM10/.claude/hooks/orca-start-watcher.sh"
ORCA_STYLE=claude HOME="$IM10" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IM10" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
M10_RUN="$(ls "$IM10/.orca-backups" 2>/dev/null)"
chmod 555 "$IM10/.claude/agents"
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip: restore: unwritable origin directory (root bypasses mode bits)\n'
else
  OUTR20="$(HOME="$IM10" sh "$INSTALL_SH" --restore "$M10_RUN" </dev/null 2>&1)"
  RCR20=$?
  wassert 'restore: a copy that fails exits 1, not 0' test "$RCR20" -eq 1
  printf '%s' "$OUTR20" | grep -qF "! could not restore $IM10/.claude/agents/orca.md" && R20_SAID=1 || R20_SAID=0
  wassert 'restore: the failed copy is named on stdout' test "$R20_SAID" = 1
  wassert 'restore: the sweep continues past the failed copy' \
    bash -c "grep -q 'previous hook' '$IM10/.claude/hooks/orca-start-watcher.sh'"
  printf '%s' "$OUTR20" | grep -q 'item(s) could not be restored' && R20_SUMMARY=1 || R20_SUMMARY=0
  wassert 'restore: reports how much could not be restored' test "$R20_SUMMARY" = 1
fi
chmod u+rwx "$IM10/.claude/agents"

# ---------------------------------------------------------------------------
# bin/orca — the launcher: preflight checks, identity export, single instance
#
# Hermetic. PATH is a shim directory holding only the system tools the
# launcher uses plus a stub `gh` and a stub `claude`, so a tool can be made
# "missing" whatever the machine has. The stub gh answers `api user` and the
# collaborator-permission call from canned JSON (through real jq, as gh's
# --jq would) and accepts ONE token, so "GH_TOKEN was set from the file" is
# asserted, not assumed. The stub claude prints the argv and the identity it
# was exec'd with, and can hold the session open. HOME, XDG_CONFIG_HOME and
# CLAUDE_HOME are temp dirs; the install the checks look at is made by
# install.sh itself, so the check sees exactly what a user's would.

L_TMP="$(mktemp -d)"
LIVE_ORCAS=()
reap_live_orcas() {
  local p c
  for p in ${LIVE_ORCAS[@]+"${LIVE_ORCAS[@]}"}; do
    for c in $(pgrep -P "$p" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
    kill -9 "$p" 2>/dev/null
  done
  LIVE_ORCAS=()
}
trap 'reap_live_watchers; reap_live_orcas; chmod u+rwx "$GH_TMP/nowrite" 2>/dev/null; rm -rf "$WATCHER_TMP" "$GH_TMP" "$INST_TMP" "$L_TMP"' EXIT

# the shim PATH: the system tools the launcher and the stubs use, nothing else
L_SYS="$L_TMP/sys"
mkdir -p "$L_SYS"
L_SHIM_OK=1
for t in sh bash git jq ps grep tr stat cat readlink mkdir rm sleep; do
  p="$(command -v "$t")" && ln -s "$p" "$L_SYS/$t" || L_SHIM_OK=0
done
L_STUBS="$L_TMP/stubs"
mkdir -p "$L_STUBS"
cat >"$L_STUBS/gh" <<'STUB'
#!/usr/bin/env bash
# canned gh. Accepts one token (ORCA_STUB_TOKEN) as GH_TOKEN, else 401.
# Answers `api user` and `api repos/<o>/<r>/collaborators/orca-bot/permission`
# (the permission from ORCA_STUB_PERM, default admin), applying --jq with real
# jq. ORCA_STUB_CALLS names a file each call's arguments are appended to.
# ORCA_STUB_WARN is printed on stderr beside a successful `api user`.
jq_expr=
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq)
      jq_expr="$2"
      shift
      ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ -n "${ORCA_STUB_CALLS:-}" ] && printf '%s\n' "${args[*]}" >>"$ORCA_STUB_CALLS"
if [ "${GH_TOKEN-}" != "${ORCA_STUB_TOKEN-}" ]; then
  echo "gh: HTTP 401: Bad credentials (https://api.github.com/${args[1]-})" >&2
  exit 1
fi
case "${args[0]-} ${args[1]-}" in
  'api user')
    body='{"login":"orca-bot","id":424242}'
    [ -n "${ORCA_STUB_WARN:-}" ] && printf '%s\n' "$ORCA_STUB_WARN" >&2
    ;;
  api\ repos/*/collaborators/orca-bot/permission) body="{\"permission\":\"${ORCA_STUB_PERM:-admin}\"}" ;;
  *)
    echo "stub gh: unexpected call: ${args[*]}" >&2
    exit 1
    ;;
esac
if [ -n "$jq_expr" ]; then printf '%s' "$body" | jq -r "$jq_expr"; else printf '%s\n' "$body"; fi
STUB
cat >"$L_STUBS/claude" <<'STUB'
#!/usr/bin/env bash
# stands in for claude: prints what it was exec'd with, then exits - or, with
# ORCA_STUB_HOLD set, stays alive that many seconds (TERM ends it) so the
# session record can be observed while "orca" runs.
printf 'stub claude argv:'
printf ' [%s]' "$@"
printf '\n'
for v in GH_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
  printf '%s=%s\n' "$v" "${!v-unset}"
done
if [ -n "${ORCA_STUB_HOLD:-}" ]; then
  trap 'kill "$sp" 2>/dev/null; exit 0' TERM INT
  sleep "$ORCA_STUB_HOLD" &
  sp=$!
  wait "$sp"
fi
exit 0
STUB
chmod +x "$L_STUBS/gh" "$L_STUBS/claude"
L_PATH="$L_STUBS:$L_SYS"
# the same PATH with no claude on it
L_NOCLAUDE="$L_TMP/noclaude"
mkdir -p "$L_NOCLAUDE"
ln -s "$L_STUBS/gh" "$L_NOCLAUDE/gh"

# a HOME with a claude-style install made by install.sh (launcher included,
# in ORCA_BIN) and a 0600 token file
L_HOME="$L_TMP/home"
L_OBIN="$L_TMP/obin"
mkdir -p "$L_HOME/.config/orca"
L_TOKEN="$L_HOME/.config/orca/token"
printf 'ghp_stubtoken\n' >"$L_TOKEN"
chmod 600 "$L_TOKEN"
ORCA_STYLE=claude HOME="$L_HOME" ORCA_BIN="$L_OBIN" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
L_RECORD="$L_HOME/.config/orca/sessions/octocat_hello-world"

# run_orca <cwd> <argv...> — the launcher under the shim PATH with the temp
# HOME and identity. ORCA_ENV (an array of VAR=value) adds or overrides
# variables for one run. Output and exit code land in ORCA_OUT / ORCA_RC.
ORCA_ENV=()
run_orca() {
  local cwd="$1"
  shift
  ORCA_OUT="$(cd "$cwd" && env -i HOME="$L_HOME" XDG_CONFIG_HOME="$L_HOME/.config" ORCA_BIN="$L_OBIN" \
    PATH="$L_PATH" ORCA_STUB_TOKEN=ghp_stubtoken ${ORCA_ENV[@]+"${ORCA_ENV[@]}"} \
    sh "$LAUNCHER" "$@" 2>&1)"
  ORCA_RC=$?
  ORCA_ENV=()
}
# orca_said <desc> <substr> / orca_not_said <desc> <substr> — ORCA_OUT does
# (not) contain the literal substring
orca_said() {
  if [[ "$ORCA_OUT" == *"$2"* ]]; then
    printf 'ok:   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n      output missing: %s\n      got: %s\n' "$1" "$2" "$ORCA_OUT" >&2
    fail=$((fail + 1))
  fi
}
orca_not_said() {
  if [[ "$ORCA_OUT" != *"$2"* ]]; then
    printf 'ok:   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n      output contains: %s\n      got: %s\n' "$1" "$2" "$ORCA_OUT" >&2
    fail=$((fail + 1))
  fi
}
# tmode <path> — permission bits in octal, GNU stat then BSD stat
tmode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
# wait_record_gone — the janitor removes the record within about a second of
# claude's exit; allow five. Called after every launch, so the next case never
# sees the previous launch's record.
wait_record_gone() {
  local _i
  for _i in $(seq 1 20); do
    [ -e "$L_RECORD" ] || return 0
    sleep 0.25
  done
  return 1
}

if [[ "$L_SHIM_OK" == 1 ]]; then
  # every check passes: exit 0, one ok per check, the login named, nothing
  # launched, nothing written, and the token itself never on the screen
  run_orca "$REPO_SSH" --check
  wassert 'launcher: --check with everything in place exits 0' test "$ORCA_RC" -eq 0
  orca_said 'launcher: --check names the login it runs as' 'ok: running as orca-bot'
  orca_said 'launcher: --check reports the tools' 'ok: tools: gh, git, jq, claude on PATH'
  orca_said 'launcher: --check reports the token file and its mode' "ok: token: $L_TOKEN (mode 0600)"
  orca_said 'launcher: --check resolves the repo from an SSH origin and reports the permission' \
    'ok: repo: octocat/hello-world (orca-bot has admin access)'
  orca_said 'launcher: --check reports the installed files' \
    "ok: install: claude style; playbook, hook and watcher in place under $L_HOME/.claude"
  orca_said 'launcher: --check reports the wired hook' "ok: install: SessionStart hook wired in $L_HOME/.claude/settings.json"
  orca_said 'launcher: --check reports no other instance' 'ok: instance: no other orca running for octocat/hello-world'
  orca_said 'launcher: --check says all checks passed' 'all checks passed'
  orca_not_said 'launcher: --check launches nothing' 'stub claude'
  wassert 'launcher: --check writes no session record' test ! -e "$L_RECORD"
  orca_not_said 'launcher: --check never prints the token' 'ghp_stubtoken'

  # an HTTPS origin normalizes to the same owner/repo; --repo overrides detection
  run_orca "$REPO_HTTPS" --check
  wassert 'launcher: --check from an HTTPS origin exits 0' test "$ORCA_RC" -eq 0
  orca_said 'launcher: an HTTPS origin resolves to owner/repo' 'ok: repo: octocat/hello-world ('
  run_orca "$REPO_SSH" --check --repo octocat/elsewhere
  wassert 'launcher: --repo exits 0' test "$ORCA_RC" -eq 0
  orca_said 'launcher: --repo overrides the detected repo' 'ok: repo: octocat/elsewhere (orca-bot has admin access)'
  orca_said 'launcher: --repo is the repo the instance check uses' 'ok: instance: no other orca running for octocat/elsewhere'
  run_orca "$REPO_SSH" --check --repo=octocat/elsewhere
  wassert 'launcher: --repo=owner/repo exits 0' test "$ORCA_RC" -eq 0
  orca_said 'launcher: --repo=owner/repo overrides the detected repo' 'ok: repo: octocat/elsewhere (orca-bot has admin access)'

  # 1. tools: a missing one is named, and every other check still runs
  ORCA_ENV=(PATH="$L_NOCLAUDE:$L_SYS")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a missing tool fails --check (exit 1)' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a missing tool is named' 'fail: tools: claude not on PATH'
  orca_said 'launcher: the other checks still run after a missing tool' 'ok: running as orca-bot'
  orca_said 'launcher: the failure count is reported' '1 check(s) failed'

  # 2. identity: the token file must exist, be non-empty and be mode 0600 -
  # a readable one is refused UNREAD (gh is never called with it) - and gh
  # must accept it
  ORCA_ENV=(ORCA_TOKEN_FILE="$L_TMP/absent-token")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a missing token file fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a missing token file is named' "fail: token: $L_TMP/absent-token is missing"
  orca_said 'launcher: a missing token file says how to create it' "chmod 600 $L_TMP/absent-token"
  orca_said 'launcher: the identity check is reported as not run without a token' 'fail: identity: not checked (no usable token)'
  orca_said 'launcher: the install check still runs without a token' 'ok: install: claude style'
  L_TOK644="$L_TMP/token-644"
  printf 'ghp_stubtoken\n' >"$L_TOK644"
  chmod 644 "$L_TOK644"
  L_CALLS="$L_TMP/gh-calls"
  : >"$L_CALLS"
  ORCA_ENV=(ORCA_TOKEN_FILE="$L_TOK644" ORCA_STUB_CALLS="$L_CALLS")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a 0644 token file fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a 0644 token file is refused with its mode' "fail: token: $L_TOK644 is mode 644, not 0600"
  orca_said 'launcher: a 0644 token file gets the chmod hint' "run: chmod 600 $L_TOK644"
  orca_not_said 'launcher: a 0644 token file is not used to reach GitHub' 'running as'
  wassert 'launcher: a 0644 token file is never handed to gh' bash -c "! grep -q 'api user' '$L_CALLS'"
  # read-only for the owner is as private as 0600
  L_TOK400="$L_TMP/token-400"
  printf 'ghp_stubtoken\n' >"$L_TOK400"
  chmod 400 "$L_TOK400"
  ORCA_ENV=(ORCA_TOKEN_FILE="$L_TOK400")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a 0400 token file passes --check' test "$ORCA_RC" -eq 0
  orca_said 'launcher: a 0400 token file is reported with its own mode' "ok: token: $L_TOK400 (mode 0400)"
  orca_said 'launcher: a 0400 token file is used to reach GitHub' 'ok: running as orca-bot'
  # a symlinked token file is judged by the file it points at
  L_TOKLINK="$L_TMP/token-link"
  ln -s "$L_TOKEN" "$L_TOKLINK"
  ORCA_ENV=(ORCA_TOKEN_FILE="$L_TOKLINK")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a symlink to a 0600 token file passes --check' test "$ORCA_RC" -eq 0
  orca_said 'launcher: a symlink to a 0600 token file is reported with the target mode' "ok: token: $L_TOKLINK (mode 0600)"
  L_TOKLINK644="$L_TMP/token-link-644"
  ln -s "$L_TOK644" "$L_TOKLINK644"
  ORCA_ENV=(ORCA_TOKEN_FILE="$L_TOKLINK644")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a symlink to a 0644 token file fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a symlink to a 0644 token file is refused with the target mode' \
    "fail: token: $L_TOKLINK644 is mode 644, not 0600"
  L_TOKEMPTY="$L_TMP/token-empty"
  : >"$L_TOKEMPTY"
  chmod 600 "$L_TOKEMPTY"
  ORCA_ENV=(ORCA_TOKEN_FILE="$L_TOKEMPTY")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: an empty token file fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: an empty token file is named' "fail: token: $L_TOKEMPTY is empty"
  # the stub accepts ghp_stubtoken only: told to expect another, it answers
  # 401 - which also proves GH_TOKEN was set from the file
  ORCA_ENV=(ORCA_STUB_TOKEN=ghp_somethingelse)
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a token gh rejects fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a failed gh api user is named with the gh error' \
    "fail: identity: gh api user failed with the token in $L_TOKEN: gh: HTTP 401: Bad credentials"
  orca_said 'launcher: the permission check is reported as not run without a login' \
    "fail: repo: octocat/hello-world; the bot's permission was not checked (identity check failed)"
  # gh's stderr is merged into the parsed output: a warning printed beside a
  # success must not become the git identity
  ORCA_ENV=(ORCA_STUB_WARN='! Warning: this token expires in 3 days')
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a gh warning beside a successful api user fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a gh warning beside a successful api user is named' 'fail: identity: unexpected gh api user output'
  orca_not_said 'launcher: a gh warning beside a successful api user names no login' 'ok: running as'
  ORCA_ENV=(ORCA_STUB_WARN='! Warning: this token expires in 3 days')
  run_orca "$REPO_SSH"
  wassert 'launcher: a gh warning beside a successful api user refuses the launch' test "$ORCA_RC" -eq 1
  orca_not_said 'launcher: a gh warning beside a successful api user reaches no git identity' 'GIT_AUTHOR_EMAIL='

  # 3. repo: the permission must be write or better; no origin is named
  ORCA_ENV=(ORCA_STUB_PERM=read)
  run_orca "$REPO_SSH" --check
  wassert 'launcher: permission read fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: permission read is named with what is needed' \
    'fail: repo: orca-bot has read access on octocat/hello-world; write, maintain or admin is needed'
  ORCA_ENV=(ORCA_STUB_PERM=write)
  run_orca "$REPO_SSH" --check
  wassert 'launcher: permission write passes' test "$ORCA_RC" -eq 0
  orca_said 'launcher: permission write is reported' 'ok: repo: octocat/hello-world (orca-bot has write access)'
  run_orca "$REPO_NONE" --check
  wassert 'launcher: no origin remote fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: no origin remote is named with the --repo hint' \
    'fail: repo: not detected from the current directory (no origin remote); pass --repo owner/repo'
  orca_said 'launcher: the instance check is reported as not run without a repo' 'fail: instance: not checked (no repo)'
  # a --repo value that is not owner/repo is refused before it can reach an
  # API path: no permission call is made with it
  : >"$L_CALLS"
  ORCA_ENV=(ORCA_STUB_CALLS="$L_CALLS")
  run_orca "$REPO_SSH" --check --repo ../x
  wassert 'launcher: --repo ../x fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: --repo ../x is named as not owner/repo' "fail: repo: '../x' is not owner/repo"
  wassert 'launcher: --repo ../x never reaches the permission API' bash -c "! grep -q collaborators '$L_CALLS'"
  : >"$L_CALLS"
  ORCA_ENV=(ORCA_STUB_CALLS="$L_CALLS")
  run_orca "$REPO_SSH" --check --repo a/b/c
  wassert 'launcher: --repo a/b/c fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: --repo a/b/c is named as not owner/repo' "fail: repo: 'a/b/c' is not owner/repo"
  wassert 'launcher: --repo a/b/c never reaches the permission API' bash -c "! grep -q collaborators '$L_CALLS'"

  # 4. install: a dangling link is named with its target (the case from the
  # machine where a temp checkout vanished under the links), a missing file
  # is named, and the hook must be wired by the installer's own rule
  L_CH_DANGLING="$L_TMP/ch-dangling"
  ORCA_STYLE=claude HOME="$L_HOME" CLAUDE_HOME="$L_CH_DANGLING" ORCA_BIN="$L_OBIN" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
  rm -f "$L_CH_DANGLING/agents/orca.md"
  ln -s /nonexistent-orca-checkout/agents/orca.md "$L_CH_DANGLING/agents/orca.md"
  ORCA_ENV=(CLAUDE_HOME="$L_CH_DANGLING")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a dangling installed symlink fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a dangling installed symlink is named with its target' \
    "fail: install: $L_CH_DANGLING/agents/orca.md is a dangling symlink to /nonexistent-orca-checkout/agents/orca.md"
  orca_said 'launcher: the hook wiring is still checked beside a dangling link' \
    "ok: install: SessionStart hook wired in $L_CH_DANGLING/settings.json"
  rm -f "$L_CH_DANGLING/scripts/gh-watch.sh"
  ORCA_ENV=(CLAUDE_HOME="$L_CH_DANGLING")
  run_orca "$REPO_SSH" --check
  orca_said 'launcher: a missing installed file is named' "fail: install: $L_CH_DANGLING/scripts/gh-watch.sh is missing"
  L_CH_NOHOOK="$L_TMP/ch-nohook"
  ORCA_STYLE=claude HOME="$L_HOME" CLAUDE_HOME="$L_CH_NOHOOK" ORCA_BIN="$L_OBIN" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"mine.sh"}]}]}}\n' >"$L_CH_NOHOOK/settings.json"
  ORCA_ENV=(CLAUDE_HOME="$L_CH_NOHOOK")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a settings.json without the hook entry fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: the missing hook entry is named' \
    "fail: install: no SessionStart hook for orca-start-watcher.sh in $L_CH_NOHOOK/settings.json"
  orca_said 'launcher: the installed files pass beside the missing hook entry' \
    "ok: install: claude style; playbook, hook and watcher in place under $L_CH_NOHOOK"
  # a hand-wired entry with extra keys still counts, as it does for install.sh
  printf '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"%s/hooks/orca-start-watcher.sh","timeout":10}]}]}}\n' \
    "$L_CH_NOHOOK" >"$L_CH_NOHOOK/settings.json"
  ORCA_ENV=(CLAUDE_HOME="$L_CH_NOHOOK")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a hand-wired hook entry with extra keys passes' test "$ORCA_RC" -eq 0
  # the style is detected from what is installed; ORCA_STYLE overrides
  L_HOME_EMPTY="$L_TMP/home-empty"
  mkdir -p "$L_HOME_EMPTY"
  ORCA_ENV=(HOME="$L_HOME_EMPTY" XDG_CONFIG_HOME="$L_HOME_EMPTY/.config" ORCA_BIN="$L_HOME_EMPTY/bin" ORCA_TOKEN_FILE="$L_TOKEN")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: no install at all fails --check' test "$ORCA_RC" -eq 1
  orca_said 'launcher: no install at all names both places it looked' \
    "fail: install: no orca install found (neither $L_HOME_EMPTY/.claude/agents/orca.md nor $L_HOME_EMPTY/bin/gh-watch); run install.sh"
  L_HOME_AGENTS="$L_TMP/home-agents"
  L_OBIN_AGENTS="$L_TMP/obin-agents"
  mkdir -p "$L_HOME_AGENTS"
  ORCA_STYLE=agents HOME="$L_HOME_AGENTS" ORCA_BIN="$L_OBIN_AGENTS" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
  ORCA_ENV=(HOME="$L_HOME_AGENTS" XDG_CONFIG_HOME="$L_HOME_AGENTS/.config" ORCA_BIN="$L_OBIN_AGENTS" ORCA_TOKEN_FILE="$L_TOKEN")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: an agents-style install passes --check' test "$ORCA_RC" -eq 0
  orca_said 'launcher: the agents style is detected from its own files' 'ok: install: agents style; watcher and playbook in place'
  ORCA_ENV=(ORCA_STYLE=agents)
  run_orca "$REPO_SSH" --check
  wassert 'launcher: ORCA_STYLE overrides the detected style' test "$ORCA_RC" -eq 1
  orca_said 'launcher: ORCA_STYLE=agents on a claude install names the missing agents files' \
    "fail: install: $L_OBIN/gh-watch is missing"

  # a launch: the checks print first, then claude is exec'd with the extra
  # arguments, GH_TOKEN and the git identity in its environment
  run_orca "$REPO_SSH" --resume abc123
  wassert 'launcher: a launch exits with the exec target status' test "$ORCA_RC" -eq 0
  orca_said 'launcher: a launch prints the check results first' 'ok: running as orca-bot'
  orca_said 'launcher: a launch execs claude --agent orca with the extra arguments passed through' \
    'stub claude argv: [--agent] [orca] [--resume] [abc123]'
  orca_said 'launcher: GH_TOKEN is exported from the token file' 'GH_TOKEN=ghp_stubtoken'
  orca_said 'launcher: the git author name defaults to the login' 'GIT_AUTHOR_NAME=orca-bot'
  orca_said 'launcher: the git author email defaults to the id+login noreply address' \
    'GIT_AUTHOR_EMAIL=424242+orca-bot@users.noreply.github.com'
  orca_said 'launcher: the git committer name matches' 'GIT_COMMITTER_NAME=orca-bot'
  orca_said 'launcher: the git committer email matches' 'GIT_COMMITTER_EMAIL=424242+orca-bot@users.noreply.github.com'
  wassert 'launcher: the session record is removed after claude exits' wait_record_gone
  run_orca "$REPO_SSH"
  orca_said 'launcher: a launch with no extra arguments execs claude --agent orca alone' \
    'stub claude argv: [--agent] [orca]'$'\n'
  wait_record_gone
  run_orca "$REPO_SSH" -- --check
  wassert 'launcher: -- ends the launcher options (exit 0)' test "$ORCA_RC" -eq 0
  orca_said 'launcher: a --check after -- is passed through to claude' 'stub claude argv: [--agent] [orca] [--check]'
  orca_not_said 'launcher: a --check after -- is not a check run' 'all checks passed'
  wait_record_gone
  ORCA_ENV=(ORCA_GIT_NAME='Orca Bot' ORCA_GIT_EMAIL=orca@example.invalid)
  run_orca "$REPO_SSH"
  orca_said 'launcher: ORCA_GIT_NAME overrides the git name' 'GIT_COMMITTER_NAME=Orca Bot'
  orca_said 'launcher: ORCA_GIT_EMAIL overrides the git email' 'GIT_AUTHOR_EMAIL=orca@example.invalid'
  wait_record_gone
  ORCA_ENV=(ORCA_STUB_PERM=read)
  run_orca "$REPO_SSH"
  wassert 'launcher: a failed check refuses the launch (exit 1)' test "$ORCA_RC" -eq 1
  orca_said 'launcher: a refused launch says so' '1 check(s) failed; not launching orca'
  orca_not_said 'launcher: a refused launch execs nothing' 'stub claude'
  wassert 'launcher: a refused launch writes no session record' test ! -e "$L_RECORD"

  # 5. instance: a running orca holds the record with its pid; a second
  # launch for the same repo is refused naming it, another repo is not, and
  # the record goes when the first exits. exec keeps the pid: the
  # backgrounded subshell IS the launcher IS the stub claude.
  (cd "$REPO_SSH" && exec env -i HOME="$L_HOME" XDG_CONFIG_HOME="$L_HOME/.config" ORCA_BIN="$L_OBIN" PATH="$L_PATH" \
    ORCA_STUB_TOKEN=ghp_stubtoken ORCA_STUB_HOLD=60 sh "$LAUNCHER") >"$L_TMP/held.out" 2>&1 &
  L_HELD=$!
  disown "$L_HELD" 2>/dev/null || true
  LIVE_ORCAS+=("$L_HELD")
  for _ in $(seq 1 40); do
    [ "$(cat "$L_RECORD" 2>/dev/null)" = "$L_HELD" ] && break
    sleep 0.25
  done
  wassert 'launcher: a running orca holds the session record with its pid' \
    test "$(cat "$L_RECORD" 2>/dev/null)" = "$L_HELD"
  run_orca "$REPO_SSH"
  wassert 'launcher: a second launch for the same repo is refused (exit 1)' test "$ORCA_RC" -eq 1
  orca_said 'launcher: the refusal names the running pid' \
    "fail: instance: orca already running for octocat/hello-world (pid $L_HELD)"
  orca_not_said 'launcher: the refused second launch execs nothing' 'stub claude'
  wassert 'launcher: the refused second launch leaves the first record intact' \
    test "$(cat "$L_RECORD" 2>/dev/null)" = "$L_HELD"
  wassert 'launcher: the refused second launch leaves the first orca running' kill -0 "$L_HELD"
  run_orca "$REPO_SSH" --check --repo octocat/elsewhere
  wassert 'launcher: another repo is not blocked by the running orca' test "$ORCA_RC" -eq 0
  kill -TERM "$L_HELD" 2>/dev/null
  wassert 'launcher: the record is removed when the running orca exits' wait_record_gone
  # a stale record never blocks: a dead pid, or a live pid that is not an orca
  mkdir -p "$(dirname "$L_RECORD")"
  printf '%s\n' "$DEAD_PID" >"$L_RECORD"
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a stale record (dead pid) does not block' test "$ORCA_RC" -eq 0
  orca_said 'launcher: a stale record reports no other instance' 'ok: instance: no other orca running for octocat/hello-world'
  sleep 300 &
  L_IMPOSTOR=$!
  disown "$L_IMPOSTOR" 2>/dev/null || true
  printf '%s\n' "$L_IMPOSTOR" >"$L_RECORD"
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a record naming a live pid that is not an orca does not block' test "$ORCA_RC" -eq 0
  kill -9 "$L_IMPOSTOR" 2>/dev/null
  # a live pid whose argv merely contains the word orca (a recycled pid now
  # running `less notes/orca`) is not an orca launch either
  bash -c 'exec -a "less notes/orca" sleep 300' &
  L_LOOKALIKE=$!
  disown "$L_LOOKALIKE" 2>/dev/null || true
  wassert 'launcher: the lookalike process really has orca in its argv' \
    bash -c "ps -ww -o args= -p $L_LOOKALIKE | grep -qE '(^|[[:space:]/])orca([[:space:]]|$)'"
  printf '%s\n' "$L_LOOKALIKE" >"$L_RECORD"
  run_orca "$REPO_SSH" --check
  wassert 'launcher: a record naming a live pid with orca in its argv but no claude --agent orca does not block' \
    test "$ORCA_RC" -eq 0
  orca_said 'launcher: the lookalike record reports no other instance' 'ok: instance: no other orca running for octocat/hello-world'
  kill -9 "$L_LOOKALIKE" 2>/dev/null
  printf '%s\n' "$DEAD_PID" >"$L_RECORD"
  run_orca "$REPO_SSH"
  wassert 'launcher: a launch over a stale record proceeds' test "$ORCA_RC" -eq 0
  orca_said 'launcher: a launch over a stale record execs claude' 'stub claude argv: [--agent] [orca]'
  wassert 'launcher: the record written over a stale one is removed after exit' wait_record_gone

  # XDG_CONFIG_HOME elsewhere: the token is read from there, --check creates
  # nothing there, and a launch writes its record there and not under HOME
  L_XDG="$L_TMP/xdg"
  mkdir -p "$L_XDG/orca"
  printf 'ghp_stubtoken\n' >"$L_XDG/orca/token"
  chmod 600 "$L_XDG/orca/token"
  ORCA_ENV=(XDG_CONFIG_HOME="$L_XDG")
  run_orca "$REPO_SSH" --check
  wassert 'launcher: XDG_CONFIG_HOME elsewhere passes --check with the token there' test "$ORCA_RC" -eq 0
  orca_said 'launcher: XDG_CONFIG_HOME elsewhere reads the token from there' "ok: token: $L_XDG/orca/token (mode 0600)"
  wassert 'launcher: --check under XDG_CONFIG_HOME elsewhere creates nothing there' test ! -e "$L_XDG/orca/sessions"
  L_XDG_RECORD="$L_XDG/orca/sessions/octocat_hello-world"
  (cd "$REPO_SSH" && exec env -i HOME="$L_HOME" XDG_CONFIG_HOME="$L_XDG" ORCA_BIN="$L_OBIN" PATH="$L_PATH" \
    ORCA_STUB_TOKEN=ghp_stubtoken ORCA_STUB_HOLD=60 sh "$LAUNCHER") >"$L_TMP/held-xdg.out" 2>&1 &
  L_HELD_XDG=$!
  disown "$L_HELD_XDG" 2>/dev/null || true
  LIVE_ORCAS+=("$L_HELD_XDG")
  for _ in $(seq 1 40); do
    [ "$(cat "$L_XDG_RECORD" 2>/dev/null)" = "$L_HELD_XDG" ] && break
    sleep 0.25
  done
  wassert 'launcher: a launch under XDG_CONFIG_HOME elsewhere writes its record there' \
    test "$(cat "$L_XDG_RECORD" 2>/dev/null)" = "$L_HELD_XDG"
  wassert 'launcher: a launch under XDG_CONFIG_HOME elsewhere writes no record under HOME' test ! -e "$L_RECORD"
  kill -TERM "$L_HELD_XDG" 2>/dev/null

  # usage
  run_orca "$REPO_SSH" --help
  wassert 'launcher: --help exits 0' test "$ORCA_RC" -eq 0
  orca_said 'launcher: --help prints the usage' 'usage: orca [--check] [--repo owner/repo] [claude args...]'
  orca_not_said 'launcher: --help runs no check' 'ok:'
  run_orca "$REPO_SSH" --repo
  wassert 'launcher: --repo without a value exits 2' test "$ORCA_RC" -eq 2
else
  printf 'skip: launcher cases (could not build a PATH shim)\n'
fi

# install.sh and the launcher: it lands in ORCA_BIN for both styles and both
# modes, is named in the install output, and --uninstall removes it under
# the same provenance rules as everything else. ~/.config/orca/token is the
# user's: install, uninstall and restore never create, back up or touch it.
wassert 'install: claude style (link) links the launcher into ORCA_BIN' \
  test "$(readlink "$L_OBIN/orca")" = "$LAUNCHER"
wassert 'install: the launcher defaults to ~/.local/bin/orca' \
  test "$(readlink "$IH1/.local/bin/orca")" = "$LAUNCHER"
L_HOME_AGENTS_LINK="$L_TMP/home-agents-link"
L_OBIN_AGENTS_LINK="$L_TMP/obin-agents-link"
mkdir -p "$L_HOME_AGENTS_LINK"
ORCA_STYLE=agents HOME="$L_HOME_AGENTS_LINK" ORCA_BIN="$L_OBIN_AGENTS_LINK" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'install: agents style (link) links the launcher into ORCA_BIN' \
  test "$(readlink "$L_OBIN_AGENTS_LINK/orca")" = "$LAUNCHER"
L_HOME_COPY="$L_TMP/home-copy"
L_OBIN_COPY="$L_TMP/obin-copy"
mkdir -p "$L_HOME_COPY"
OUTLC="$(ORCA_STYLE=claude ORCA_MODE=copy HOME="$L_HOME_COPY" ORCA_BIN="$L_OBIN_COPY" sh "$INSTALL_SH" </dev/null 2>&1)"
wassert 'install: claude style (copy) copies the launcher into ORCA_BIN as an executable file' \
  bash -c "test -f '$L_OBIN_COPY/orca' && test ! -L '$L_OBIN_COPY/orca' && test -x '$L_OBIN_COPY/orca' && cmp -s '$LAUNCHER' '$L_OBIN_COPY/orca'"
printf '%s' "$OUTLC" | grep -qF "installed: $L_OBIN_COPY/orca" && LC_SAID=1 || LC_SAID=0
wassert 'install: the launcher is listed in the install output' test "$LC_SAID" = 1
printf '%s' "$OUTLC" | grep -qF "'orca --check' runs the preflight checks" && LC_NOTE=1 || LC_NOTE=0
wassert 'install: the install summary says how to launch and how to check' test "$LC_NOTE" = 1
L_HOME_ACOPY="$L_TMP/home-agents-copy"
L_OBIN_ACOPY="$L_TMP/obin-agents-copy"
mkdir -p "$L_HOME_ACOPY"
ORCA_STYLE=agents ORCA_MODE=copy HOME="$L_HOME_ACOPY" ORCA_BIN="$L_OBIN_ACOPY" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
wassert 'install: agents style (copy) copies the launcher into ORCA_BIN' \
  bash -c "test -f '$L_OBIN_ACOPY/orca' && test ! -L '$L_OBIN_ACOPY/orca' && cmp -s '$LAUNCHER' '$L_OBIN_ACOPY/orca'"
HOME="$L_HOME_COPY" ORCA_BIN="$L_OBIN_COPY" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'uninstall: removes a copy-mode launcher' test ! -e "$L_OBIN_COPY/orca"
OUTLU="$(HOME="$L_HOME_AGENTS_LINK" ORCA_BIN="$L_OBIN_AGENTS_LINK" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
wassert 'uninstall: removes a linked launcher' \
  bash -c "test ! -e '$L_OBIN_AGENTS_LINK/orca' && test ! -L '$L_OBIN_AGENTS_LINK/orca'"
printf '%s' "$OUTLU" | grep -qF "removed: $L_OBIN_AGENTS_LINK/orca" && LU_SAID=1 || LU_SAID=0
wassert 'uninstall: names the launcher it removed' test "$LU_SAID" = 1
L_HOME_USER="$L_TMP/home-user"
L_OBIN_USER="$L_TMP/obin-user"
mkdir -p "$L_HOME_USER"
ORCA_STYLE=claude HOME="$L_HOME_USER" ORCA_BIN="$L_OBIN_USER" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
rm -f "$L_OBIN_USER/orca"
printf '#!/bin/sh\necho my own launcher\n' >"$L_OBIN_USER/orca"
OUTLU2="$(HOME="$L_HOME_USER" ORCA_BIN="$L_OBIN_USER" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
wassert 'uninstall: a user-owned file at the launcher path is left alone' \
  bash -c "grep -q 'my own launcher' '$L_OBIN_USER/orca'"
printf '%s' "$OUTLU2" | grep -qF "left alone: $L_OBIN_USER/orca" && LU2_SAID=1 || LU2_SAID=0
wassert 'uninstall: names the user-owned launcher it left alone' test "$LU2_SAID" = 1
# the token file, through install (over a previous launcher, so a backup run
# exists), uninstall and restore
L_HOME_TOK="$L_TMP/home-token"
L_OBIN_TOK="$L_TMP/obin-token"
mkdir -p "$L_HOME_TOK/.config/orca" "$L_OBIN_TOK"
printf 'keep-me\n' >"$L_HOME_TOK/.config/orca/token"
chmod 600 "$L_HOME_TOK/.config/orca/token"
printf '#!/bin/sh\necho previous launcher\n' >"$L_OBIN_TOK/orca"
ORCA_STYLE=agents HOME="$L_HOME_TOK" ORCA_BIN="$L_OBIN_TOK" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
L_TOK_RUN="$(ls "$L_HOME_TOK/.orca-backups" 2>/dev/null)"
wassert 'install: leaves the token file and its contents untouched' \
  test "$(cat "$L_HOME_TOK/.config/orca/token")" = keep-me
wassert 'install: leaves the token file mode 0600' test "$(tmode "$L_HOME_TOK/.config/orca/token")" = 600
wassert 'install: never backs up the token file' \
  bash -c "! grep -qF '.config/orca/token' '$L_HOME_TOK/.orca-backups/$L_TOK_RUN/MANIFEST' && ! ls '$L_HOME_TOK'/.orca-backups/*/*-token >/dev/null 2>&1"
HOME="$L_HOME_TOK" ORCA_BIN="$L_OBIN_TOK" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'uninstall: leaves the token file and its contents untouched' \
  test "$(cat "$L_HOME_TOK/.config/orca/token")" = keep-me
wassert 'uninstall: leaves the token file mode 0600' test "$(tmode "$L_HOME_TOK/.config/orca/token")" = 600
wassert 'uninstall: leaves ~/.config/orca standing while the token is in it' test -d "$L_HOME_TOK/.config/orca"
HOME="$L_HOME_TOK" sh "$INSTALL_SH" --restore "$L_TOK_RUN" </dev/null >/dev/null 2>&1
wassert 'restore: puts the previous launcher back' bash -c "grep -q 'previous launcher' '$L_OBIN_TOK/orca'"
wassert 'restore: leaves the token file and its contents untouched' \
  test "$(cat "$L_HOME_TOK/.config/orca/token")" = keep-me
wassert 'restore: leaves the token file mode 0600' test "$(tmode "$L_HOME_TOK/.config/orca/token")" = 600

# ---------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
