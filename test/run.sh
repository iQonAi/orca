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
  mkdir -p "$ORIGIN/agents" "$ORIGIN/hooks" "$ORIGIN/scripts"
  cp "$INSTALL_SH" "$ORIGIN/install.sh"
  cp "$REPO_ROOT/agents/orca.md" "$ORIGIN/agents/orca.md"
  cp "$HOOKS_DIR/orca-start-watcher.sh" "$ORIGIN/hooks/orca-start-watcher.sh"
  cp "$WATCH_SCRIPT" "$ORIGIN/scripts/gh-watch.sh"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_AUTHOR_NAME=orca-test GIT_AUTHOR_EMAIL=orca-test@example.invalid \
      GIT_COMMITTER_NAME=orca-test GIT_COMMITTER_EMAIL=orca-test@example.invalid
    git -C "$ORIGIN" init -q -b main
    git -C "$ORIGIN" add -A
    git -C "$ORIGIN" commit -q -m 'release v0.1.0'
    git -C "$ORIGIN" tag v0.1.0
    git -C "$ORIGIN" commit -q --allow-empty -m 'release v0.2.0'
    git -C "$ORIGIN" tag v0.2.0
    git -C "$ORIGIN" commit -q --allow-empty -m 'unreleased' )
fi

# piped bootstrap: stdin-fed script ($0 is the shell) must clone to ORCA_REPO
# and re-exec from the clone - never trust the cwd. file:// keeps it offline.
if command -v git >/dev/null 2>&1; then
  BOOT="$INST_TMP/boot"; mkdir -p "$BOOT/home"
  ( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$BOOT/clone" ORCA_STYLE=claude \
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
    ORCA_URL="file://$ORIGIN" ORCA_REPO='~/clone' ORCA_STYLE=claude \
    HOME="$TH1/home" sh <"$INSTALL_SH" 2>&1 )"; RCT1=$?
  wassert 'install: ORCA_REPO="~/x" exits 0' test "$RCT1" -eq 0
  wassert 'install: ORCA_REPO="~/x" cloned to $HOME/x' \
    test -f "$TH1/home/clone/agents/orca.md"
  wassert 'install: ORCA_REPO="~/x" left no literal ~ segment on disk' \
    test ! -e "$TH1/home/~"
  # -F: the expected line interpolates a mktemp path (`tmp.XXXXXXXXXX`), so
  # without it the `.` is a live BRE metacharacter, not a literal.
  printf '%s' "$OUTT1" | grep -qxF "Installing orca (claude style) from $TH1/home/clone" \
    && T1_RESOLVED=1 || T1_RESOLVED=0
  wassert 'install: ORCA_REPO="~/x" resolved to $HOME/x, tilde expanded' \
    test "$T1_RESOLVED" = 1

  # the bare `~` form resolves to $HOME itself
  TH2="$INST_TMP/tilde-bare"; mkdir -p "$TH2/home"
  OUTT2="$( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO='~' ORCA_STYLE=claude \
    HOME="$TH2/home" sh <"$INSTALL_SH" 2>&1 )"; RCT2=$?
  wassert 'install: ORCA_REPO="~" exits 0' test "$RCT2" -eq 0
  wassert 'install: ORCA_REPO="~" cloned into $HOME itself' \
    test -f "$TH2/home/agents/orca.md"
  wassert 'install: ORCA_REPO="~" left no literal ~ segment on disk' \
    test ! -e "$TH2/home/~"
  printf '%s' "$OUTT2" | grep -qxF "Installing orca (claude style) from $TH2/home" \
    && T2_RESOLVED=1 || T2_RESOLVED=0
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
  PIN1="$INST_TMP/pin-default"; mkdir -p "$PIN1/home"
  OUTV1="$( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN1/clone" ORCA_STYLE=claude \
    HOME="$PIN1/home" sh <"$INSTALL_SH" 2>&1 )"; RCV1=$?
  wassert 'install: pinned default exits 0' test "$RCV1" -eq 0
  wassert 'install: pinned default checks out v0.1.0, not the head of main' \
    test "$(git -C "$PIN1/clone" describe --tags --exact-match 2>/dev/null)" = v0.1.0
  printf '%s' "$OUTV1" | grep -qxF 'installed orca v0.1.0' && V1_SAID=1 || V1_SAID=0
  wassert 'install: pinned default reports the version it installed' test "$V1_SAID" = 1

  # ORCA_REF override: another tag ...
  PIN2="$INST_TMP/pin-tag"; mkdir -p "$PIN2/home"
  OUTV2="$( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN2/clone" ORCA_REF=v0.2.0 ORCA_STYLE=claude \
    HOME="$PIN2/home" sh <"$INSTALL_SH" 2>&1 )"; RCV2=$?
  wassert 'install: ORCA_REF=<tag> exits 0' test "$RCV2" -eq 0
  wassert 'install: ORCA_REF=<tag> checks out that tag' \
    test "$(git -C "$PIN2/clone" describe --tags --exact-match 2>/dev/null)" = v0.2.0
  printf '%s' "$OUTV2" | grep -qxF 'installed orca v0.2.0' && V2_SAID=1 || V2_SAID=0
  wassert 'install: ORCA_REF=<tag> reports that tag' test "$V2_SAID" = 1

  # ... and a branch name: ORCA_REF=main is the documented development
  # setting. Its head carries no tag, so the version line names the commit.
  PIN3="$INST_TMP/pin-main"; mkdir -p "$PIN3/home"
  OUTV3="$( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN3/clone" ORCA_REF=main ORCA_STYLE=claude \
    HOME="$PIN3/home" sh <"$INSTALL_SH" 2>&1 )"; RCV3=$?
  wassert 'install: ORCA_REF=main exits 0' test "$RCV3" -eq 0
  wassert 'install: ORCA_REF=main checks out the head of main' \
    test "$(git -C "$PIN3/clone" rev-parse HEAD 2>/dev/null)" = "$(git -C "$ORIGIN" rev-parse main)"
  printf '%s' "$OUTV3" | grep -qxF "installed orca $(git -C "$ORIGIN" rev-parse --short main)" \
    && V3_SAID=1 || V3_SAID=0
  wassert 'install: ORCA_REF=main reports the commit, having no tag to name' test "$V3_SAID" = 1

  # re-run on an existing checkout: moved to the pinned tag from wherever it
  # was left - here a branch, which is what the previous installer left.
  OUTV4="$( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN3/clone" ORCA_STYLE=claude \
    HOME="$PIN3/home" sh <"$INSTALL_SH" 2>&1 )"; RCV4=$?
  wassert 'install: re-run on an existing checkout exits 0' test "$RCV4" -eq 0
  wassert 'install: re-run moves the existing checkout to the pinned tag' \
    test "$(git -C "$PIN3/clone" describe --tags --exact-match 2>/dev/null)" = v0.1.0
  printf '%s' "$OUTV4" | grep -qxF 'installed orca v0.1.0' && V4_SAID=1 || V4_SAID=0
  wassert 'install: re-run reports the pinned version' test "$V4_SAID" = 1

  # unknown ref: exits non-zero before anything is installed - on a machine
  # with no checkout, and on one whose checkout then stays where it was.
  PIN5="$INST_TMP/pin-unknown"; mkdir -p "$PIN5/home"
  OUTV5="$( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN5/clone" ORCA_REF=v9.9.9 ORCA_STYLE=claude \
    HOME="$PIN5/home" sh <"$INSTALL_SH" 2>&1 )"; RCV5=$?
  wassert 'install: unknown ORCA_REF exits non-zero' test "$RCV5" -ne 0
  wassert 'install: unknown ORCA_REF installs nothing' test ! -d "$PIN5/home/.claude"
  wassert 'install: unknown ORCA_REF leaves no checkout behind' test ! -e "$PIN5/clone"
  printf '%s' "$OUTV5" | grep -q 'v9.9.9' && V5_SAID=1 || V5_SAID=0
  wassert 'install: unknown ORCA_REF names the ref it could not find' test "$V5_SAID" = 1

  ( cd "$INST_TMP" && \
    ORCA_URL="file://$ORIGIN" ORCA_REPO="$PIN3/clone" ORCA_REF=v9.9.9 ORCA_STYLE=claude \
    HOME="$PIN3/home" sh <"$INSTALL_SH" >/dev/null 2>&1 ); RCV6=$?
  wassert 'install: unknown ORCA_REF on an existing checkout exits non-zero' test "$RCV6" -ne 0
  wassert 'install: unknown ORCA_REF leaves the existing checkout where it was' \
    test "$(git -C "$PIN3/clone" describe --tags --exact-match 2>/dev/null)" = v0.1.0
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
IH6="$INST_TMP/h6"; mkdir -p "$IH6"
ORCA_STYLE=claude HOME="$IH6" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
OUTU1="$(HOME="$IH6" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"; RCU1=$?
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
OUTU2="$(HOME="$IH6" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"; RCU2=$?
wassert 'uninstall: rerun exits 0' test "$RCU2" -eq 0
printf '%s' "$OUTU2" | grep -qE 'removed:|left alone:' && UN_RERUN_CHANGED=1 || UN_RERUN_CHANGED=0
wassert 'uninstall: rerun touches nothing (idempotent)' test "$UN_RERUN_CHANGED" = 0

# a settings.json the user already had: orca's entry goes, everything else -
# other SessionStart entries, other hook types, unrelated top-level keys -
# survives with its values intact.
IH7="$INST_TMP/h7"; mkdir -p "$IH7/.claude"
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
IH8="$INST_TMP/h8"; mkdir -p "$IH8"
ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH8" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
printf 'my own agent\n' >"$IH8/.claude/agents/orca.md"
rm -f "$IH8/.claude/scripts/gh-watch.sh"
ln -s /dev/null "$IH8/.claude/scripts/gh-watch.sh"
OUTU3="$(HOME="$IH8" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"; RCU3=$?
wassert 'uninstall: exits 0 with user-owned files at install paths' test "$RCU3" -eq 0
wassert 'uninstall: a user-edited file at an install path is NOT removed' \
  bash -c "grep -q 'my own agent' '$IH8/.claude/agents/orca.md'"
wassert 'uninstall: a symlink pointing outside an orca checkout is NOT removed' \
  test "$(readlink "$IH8/.claude/scripts/gh-watch.sh")" = /dev/null
printf '%s' "$OUTU3" | grep -q "left alone: $IH8/.claude/agents/orca.md" \
  && UN_SAID_LEFT=1 || UN_SAID_LEFT=0
wassert 'uninstall: names on stdout what it left alone' test "$UN_SAID_LEFT" = 1
# same run, same directory: a copy-mode file still byte-identical to the
# source IS ours, and goes. Provenance is per path, not per run.
wassert 'uninstall: an untouched copy-mode file is still removed' \
  bash -c "test ! -e '$IH8/.claude/hooks/orca-start-watcher.sh'"

# agents style: the watcher, the playbook, and orca's own ~/.config/orca dir
IH9="$INST_TMP/h9"; mkdir -p "$IH9"
ORCA_STYLE=agents HOME="$IH9" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH9" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1; RCU4=$?
wassert 'uninstall: agents style exits 0' test "$RCU4" -eq 0
wassert 'uninstall: agents style removes the watcher and the playbook' \
  bash -c "test ! -e '$IH9/.local/bin/gh-watch' && test ! -e '$IH9/.config/orca/AGENTS.md'"
# rmdir, not rm -r: ~/.config/orca is orca's own, and only if left empty.
wassert 'uninstall: agents style removes its own empty ~/.config/orca' \
  test ! -d "$IH9/.config/orca"
wassert 'uninstall: agents style leaves ~/.local/bin standing' test -d "$IH9/.local/bin"

# custom CLAUDE_HOME: torn down where it was installed, not at ~/.claude
IH10="$INST_TMP/h10"; CH10="$INST_TMP/ch10"; mkdir -p "$IH10"
ORCA_STYLE=claude HOME="$IH10" CLAUDE_HOME="$CH10" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH10" CLAUDE_HOME="$CH10" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1; RCU5=$?
wassert 'uninstall: custom CLAUDE_HOME exits 0' test "$RCU5" -eq 0
wassert 'uninstall: custom CLAUDE_HOME files are removed' \
  bash -c "test ! -e '$CH10/agents/orca.md' && test ! -e '$CH10/hooks/orca-start-watcher.sh'"
wassert 'uninstall: custom CLAUDE_HOME settings.json is unwired' \
  test "$(jq '.hooks.SessionStart // [] | length' "$CH10/settings.json")" = 0

# backups are the user's escape hatch: uninstall points at them, never
# restores blind (which run's backup would it even pick?) and never deletes.
IH11="$INST_TMP/h11"; mkdir -p "$IH11/.claude/agents"
printf 'previous agent\n' >"$IH11/.claude/agents/orca.md"
ORCA_STYLE=claude ORCA_MODE=copy HOME="$IH11" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
OUTU4="$(HOME="$IH11" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"
wassert 'uninstall: the pre-install backup is still on disk afterwards' \
  bash -c "grep -q 'previous agent' '$IH11'/.orca-backups/*/orca.md"
printf '%s' "$OUTU4" | grep -q '.orca-backups' && UN_BACKUP_NOTE=1 || UN_BACKUP_NOTE=0
wassert 'uninstall: points at the backup dir instead of restoring blind' \
  test "$UN_BACKUP_NOTE" = 1

# Without jq, uninstall must change no JSON at all: it prints the entry to
# delete by hand, exactly as install prints the entry to add by hand. Editing
# settings.json with sed/grep guesswork would be worse than not editing it.
# The suite itself needs jq, so jq is hidden with a PATH shim holding only the
# tools the uninstall path uses.
IH13="$INST_TMP/h13"; mkdir -p "$IH13"
NOJQ_BIN="$INST_TMP/nojq-bin"; mkdir -p "$NOJQ_BIN"
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
  OUTU5="$(env -i PATH="$NOJQ_BIN" HOME="$IH13" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"; RCU9=$?
  wassert 'uninstall: without jq exits 0' test "$RCU9" -eq 0
  wassert 'uninstall: without jq still removes the files it owns' \
    bash -c "test ! -e '$IH13/.claude/hooks/orca-start-watcher.sh'"
  wassert 'uninstall: without jq leaves settings.json byte-for-byte identical' \
    cmp -s "$INST_TMP/nojq-settings.before" "$IH13/.claude/settings.json"
  printf '%s' "$OUTU5" | grep -qF '{"hooks":[{"type":"command","command":"~/.claude/hooks/orca-start-watcher.sh"}]}' \
    && NOJQ_TOLD=1 || NOJQ_TOLD=0
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
IHP="$INST_TMP/piped-un"; mkdir -p "$IHP/home"
STALE="$IHP/stale"; mkdir -p "$STALE/agents"
cp "$REPO_ROOT/agents/orca.md" "$STALE/agents/orca.md"
printf '#!/bin/sh\ntouch "%s/EXECUTED"\nexit 0\n' "$STALE" >"$STALE/install.sh"
chmod +x "$STALE/install.sh"
ORCA_STYLE=claude HOME="$IHP/home" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
# ORCA_URL is deliberately bogus: if anything tries to fetch, it fails loudly
# rather than quietly succeeding on a machine that happens to be online.
OUTP1="$( cd "$INST_TMP" && \
  ORCA_URL="file:///nonexistent-orca-remote" ORCA_REPO="$STALE" \
  HOME="$IHP/home" sh -s -- --uninstall <"$INSTALL_SH" 2>&1 )"; RCP1=$?
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
IHP2="$INST_TMP/piped-un2"; mkdir -p "$IHP2/home"
ORCA_STYLE=claude HOME="$IHP2/home" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
( cd "$INST_TMP" && \
  ORCA_URL="file:///nonexistent-orca-remote" ORCA_REPO="$IHP2/absent" \
  HOME="$IHP2/home" sh -s -- --uninstall <"$INSTALL_SH" >/dev/null 2>&1 ); RCP2=$?
wassert 'uninstall: piped uninstall with no checkout exits 0' test "$RCP2" -eq 0
wassert 'uninstall: piped uninstall clones nothing' test ! -e "$IHP2/absent"
wassert 'uninstall: piped uninstall still removes symlinks without a checkout' \
  bash -c "test ! -L '$IHP2/home/.claude/hooks/orca-start-watcher.sh'"

# provenance, anchored: install only ever writes ABSOLUTE symlinks, so a
# RELATIVE target cannot be one of ours. Unanchored, `./agents/orca.md`
# resolves against the uninstaller's cwd, and the check silently degrades to
# "am I being run from inside a checkout?" - which the documented invocation
# always is. This case runs from $REPO_ROOT, the worst case for that bug.
IH14="$INST_TMP/h14"; mkdir -p "$IH14/.claude/agents"
ln -s ./agents/orca.md "$IH14/.claude/agents/orca.md"
( cd "$REPO_ROOT" && HOME="$IH14" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1 )
wassert 'uninstall: a RELATIVE symlink target is never ours, even from a checkout' \
  test "$(readlink "$IH14/.claude/agents/orca.md")" = ./agents/orca.md

# ...and an absolute link whose root is NOT a checkout is not ours either:
# the root must carry agents/orca.md AND install.sh, not just the one file
# the link happens to name.
IH15="$INST_TMP/h15"; mkdir -p "$IH15/.claude/agents"
FAKEROOT="$INST_TMP/fakeroot"; mkdir -p "$FAKEROOT/agents"
cp "$REPO_ROOT/agents/orca.md" "$FAKEROOT/agents/orca.md"   # no install.sh at the root
ln -s "$FAKEROOT/agents/orca.md" "$IH15/.claude/agents/orca.md"
HOME="$IH15" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'uninstall: an absolute link into a NON-checkout root is not ours' \
  test "$(readlink "$IH15/.claude/agents/orca.md")" = "$FAKEROOT/agents/orca.md"

# The other half of that rule: a link into a REAL checkout that is not the
# one uninstalling IS ours. This is the piped case (uninstall run from a
# different copy than the install came from), so it must not need an exact
# $ORCA_REPO match. A minimal second checkout stands in for it.
REPO2="$INST_TMP/repo2"; mkdir -p "$REPO2/agents" "$REPO2/hooks" "$REPO2/scripts"
cp "$INSTALL_SH" "$REPO2/install.sh"
cp "$REPO_ROOT/agents/orca.md" "$REPO2/agents/orca.md"
cp "$HOOKS_DIR/orca-start-watcher.sh" "$REPO2/hooks/orca-start-watcher.sh"
cp "$WATCH_SCRIPT" "$REPO2/scripts/gh-watch.sh"
IH16="$INST_TMP/h16"; mkdir -p "$IH16"
ORCA_STYLE=claude HOME="$IH16" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
HOME="$IH16" sh "$REPO2/install.sh" --uninstall </dev/null >/dev/null 2>&1; RCU10=$?
wassert 'uninstall: from a different checkout exits 0' test "$RCU10" -eq 0
wassert 'uninstall: a link into ANOTHER real checkout is still ours to remove' \
  bash -c "test ! -L '$IH16/.claude/agents/orca.md' && test ! -L '$IH16/.claude/scripts/gh-watch.sh'"

# A settings.json with no orca entry must not be rewritten AT ALL - not even
# reformatted. It has a SessionStart array (so the jq filter would happily
# run and normalize the file) and deliberately compact formatting, which is
# what makes the "nothing to remove -> do not touch it" short-circuit visible.
IH17="$INST_TMP/h17"; mkdir -p "$IH17/.claude"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"mine.sh"}]}]},"model":"opus"}' \
  >"$IH17/.claude/settings.json"
cp "$IH17/.claude/settings.json" "$INST_TMP/h17-settings.before"
HOME="$IH17" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
wassert 'uninstall: a settings.json with nothing of ours is not rewritten at all' \
  cmp -s "$INST_TMP/h17-settings.before" "$IH17/.claude/settings.json"

# Best effort, not fail-fast: one unremovable file must not abort the sweep.
# Everything after it still gets done, what stayed is named, and the exit
# status reports the shortfall (root bypasses mode bits, so skip there).
IH18="$INST_TMP/h18"; mkdir -p "$IH18"
ORCA_STYLE=claude HOME="$IH18" sh "$INSTALL_SH" </dev/null >/dev/null 2>&1
chmod 500 "$IH18/.claude/agents"
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip: uninstall: unremovable file (root bypasses mode bits)\n'
else
  OUTU6="$(HOME="$IH18" sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"; RCU11=$?
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
UNOUT1="$(HOME= sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"; RCU6=$?
wassert 'uninstall: empty HOME exits 1, removes nothing' test "$RCU6" -eq 1
printf '%s' "$UNOUT1" | grep -q 'refusing to uninstall' && UN_REFUSED=1 || UN_REFUSED=0
wassert 'uninstall: empty HOME says why it refused' test "$UN_REFUSED" = 1
UNOUT2="$(env -u HOME sh "$INSTALL_SH" --uninstall </dev/null 2>&1)"; RCU7=$?
wassert 'uninstall: unset HOME exits 1, removes nothing' test "$RCU7" -eq 1
for badhome in / // /. /tmp/..; do
  HOME="$badhome" sh "$INSTALL_SH" --uninstall </dev/null >/dev/null 2>&1
  wassert "uninstall: HOME=$badhome is refused (exit 1)" test "$?" -eq 1
done

# A typo'd flag must not silently fall through to installing. ORCA_STYLE is
# set so a regression here would INSTALL (and be caught below) rather than
# exit 2 down the no-style path, which would mask the bug behind the same
# exit code; the message is asserted for the same reason.
IH12="$INST_TMP/h12"; mkdir -p "$IH12"
UNOUT3="$(ORCA_STYLE=claude HOME="$IH12" sh "$INSTALL_SH" --uninstal </dev/null 2>&1)"; RCU8=$?
wassert 'install: an unrecognized option exits 2' test "$RCU8" -eq 2
printf '%s' "$UNOUT3" | grep -q 'unrecognized option: --uninstal' && UN_BADOPT=1 || UN_BADOPT=0
wassert 'install: an unrecognized option names the option it rejected' test "$UN_BADOPT" = 1
wassert 'install: an unrecognized option installs nothing' test ! -d "$IH12/.claude"

# ---------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
