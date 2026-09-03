#!/usr/bin/env bash
# Polls a GitHub repo's open issues/PRs every 30s; exits as soon as
# issue/comment/label state changes. Exiting re-invokes the orchestrator
# (harness task-notification), giving ~30s change detection under the
# harness's 60s wakeup floor.
#
# Usage: gh-watch.sh [--status|--takeover] [owner/repo]
#   No repo argument: repo auto-detected from cwd via `gh repo view`.
#   --status    report whether a live watcher holds this repo, then exit.
#               Never launches, never writes state — safe to call every cycle.
#   --takeover  terminate the live watcher holding this repo (if any), then
#               become the watcher in its place. For an incumbent that is not
#               the caller's own job: its exit notifies whoever launched it,
#               not the caller, so leaving it in place means blind polling.
#
# SINGLE-INSTANCE PER REPO. Idempotency is this script's OWN invariant,
# not the caller's: it takes a per-repo pidfile before doing any work. Callers
# must NOT pre-check with `pgrep -f "gh-watch.sh <repo>"` — `pgrep -f` matches
# full command lines, so the check's own wrapper shell contains the pattern and
# pgrep matches ITSELF, reporting "already running" when nothing is. Either
# just launch this script and read its exit, or ask it with --status.
#
# Exit codes (every mode uses the same three, and no others):
#   0  watch mode: ran, then a change was detected OR the ~55min quiet expiry
#      hit, OR a signal (INT/TERM/HUP) stopped it. --status: no live watcher
#      holds this repo. In every case: the caller SHOULD (re)start a watcher.
#   1  could not start (no repo resolved, unusable state dir, pidfile not
#      takeable, baseline fetch failed) -> fix the cause, do not spin.
#   3  a watcher is ALREADY running for this repo. From a launch: this
#      invocation did nothing, so relaunching identically just returns 3
#      again. From --status: the incumbent's pid is printed. If the incumbent
#      is not the caller's own job, --takeover replaces it.
#   3 is deliberately distinct from 0: the caller reacts to this script's exit,
#   so a duplicate launch must never look like "a change was detected" (that
#   would spin the orchestrator) nor like a hard error worth retrying.
#
# State: $GH_WATCH_STATE_DIR, else $XDG_RUNTIME_DIR/gh-watch-<uid>, else
# $TMPDIR (or /tmp)/gh-watch-<uid>. One pidfile per repo, so different repos
# watch concurrently. NEVER ~/.claude/jobs/ — the harness reserves that.
# A stale pidfile (killed/crashed watcher) cannot wedge the script: the
# recorded pid must be alive AND still be a gh-watch for THIS repo to be
# honoured, otherwise the file is reclaimed. Reclaiming races (two launches
# both finding the same stale file) are serialized by a `mkdir` mutex — see
# the acquire block below.
set -u

mode=watch
case "${1:-}" in
  --status)   mode=status;   shift ;;
  --takeover) mode=takeover; shift ;;
  --*) echo "usage: gh-watch.sh [--status|--takeover] [owner/repo]"; exit 1 ;;
esac

repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}"
[ -z "$repo" ] && { echo "usage: gh-watch.sh <owner/repo> (none given, none detected from cwd)"; exit 1; }

state_dir="${GH_WATCH_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gh-watch-$(id -u)}"
if [ "$mode" != status ]; then
  # `mkdir -p` RETURNS 0 for a directory that already exists but is unusable,
  # so its exit status alone is not a guard — check the properties we need.
  mkdir -p "$state_dir" 2>/dev/null
  { [ -d "$state_dir" ] && [ -w "$state_dir" ] && [ -x "$state_dir" ]; } || {
    echo "watcher state dir $state_dir is not a writable directory"; exit 1; }
fi
pidfile="$state_dir/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_').pid"

# Is $1 a live watcher FOR THIS REPO? (pid alive is not enough: pids get
# recycled.) The match is anchored on the script name AND the repo argument,
# because an unanchored `gh-watch` substring test matches far more than real
# watchers — editors, greps, and above all the harness's own wrapper shell,
# which is the classic self-match bug. The trailing alternative with no repo
# argument covers a watcher launched with the repo auto-detected from cwd:
# only such a watcher for THIS repo can have written this repo's pidfile.
# `-ww` is required — BSD `ps` truncates the command column to terminal width.
live_watcher() {
  [ -n "${1:-}" ] || return 1
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  ps -ww -o args= -p "$1" 2>/dev/null \
    | grep -qE "gh-watch\.sh([[:space:]]+$repo)?[[:space:]]*$"
}

if [ "$mode" = status ]; then
  incumbent="$(cat "$pidfile" 2>/dev/null)"
  if live_watcher "$incumbent"; then
    echo "watcher running for $repo (pid $incumbent)"
    exit 3
  fi
  echo "no watcher running for $repo"
  exit 0
fi

if [ "$mode" = takeover ]; then
  incumbent="$(cat "$pidfile" 2>/dev/null)"
  if live_watcher "$incumbent"; then
    echo "taking over from watcher pid $incumbent for $repo"
    kill -TERM "$incumbent" 2>/dev/null
    for _ in $(seq 1 20); do live_watcher "$incumbent" || break; sleep 0.5; done
    if live_watcher "$incumbent"; then
      echo "watcher pid $incumbent for $repo did not exit; not starting a second one"
      exit 3
    fi
  fi
fi

# ACQUIRE. Creating the pidfile with `noclobber` is atomic, but RECLAIMING a
# stale one (remove, then re-create) is two steps: without a mutex every loser
# deletes the winner's fresh pidfile and installs its own, and they all believe
# they own it — several live watchers, and a pidfile naming none of them. So
# the whole read/reclaim/create sequence runs under an atomic `mkdir` lock.
lockdir="$pidfile.lock"
owned=0
incumbent=""
incumbent_live=0

# Fast path, no lock needed: a pidfile naming a live watcher for this repo
# needs no reclaim decision, and answering without contending keeps the lock
# free for the launches that actually have to reclaim.
incumbent="$(cat "$pidfile" 2>/dev/null)"
if live_watcher "$incumbent"; then
  echo "watcher already running for $repo (pid $incumbent); not starting a second one"
  exit 3
fi

# Slow path: the pidfile is absent or stale, so serialize.
# The lock may be broken ONLY when its holder is provably gone — a recorded
# holder pid that is dead, or a lock older than a minute (a holder that died in
# the sliver between `mkdir` and recording itself). Breaking a LIVE holder's
# lock would put two processes in the critical section, which is the very race
# the lock exists to stop, so no impatience rule is allowed here.
got_lock=0
for _ in $(seq 1 50); do
  if mkdir "$lockdir" 2>/dev/null; then got_lock=1; break; fi
  # Someone else holds the lock. If they have meanwhile installed themselves
  # as a live watcher, we are simply redundant and can answer without waiting
  # for the lock at all — this drains a burst of launches immediately instead
  # of one lock-round each.
  incumbent="$(cat "$pidfile" 2>/dev/null)"
  if live_watcher "$incumbent"; then
    echo "watcher already running for $repo (pid $incumbent); not starting a second one"
    exit 3
  fi
  holder="$(cat "$lockdir/holder" 2>/dev/null)"
  if [ -n "$holder" ]; then
    kill -0 "$holder" 2>/dev/null || rm -rf "$lockdir" 2>/dev/null
  elif [ -n "$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rm -rf "$lockdir" 2>/dev/null
  fi
  sleep 0.2
done
if [ "$got_lock" != 1 ]; then
  echo "could not take the watcher lock $lockdir for $repo"
  exit 1
fi
( printf '%s\n' "$$" >"$lockdir/holder" ) 2>/dev/null
incumbent="$(cat "$pidfile" 2>/dev/null)"
if live_watcher "$incumbent"; then
  incumbent_live=1
else
  # Both writes go through a subshell: a FAILED redirection is reported by the
  # shell itself, and only a redirection on the subshell suppresses it. An
  # unwritable pidfile path (e.g. a directory) must fail quietly here and be
  # reported by the exit-code branch below, not leak a raw shell error.
  rm -f "$pidfile" 2>/dev/null
  ( printf '%s\n' "$$" >"$pidfile" ) 2>/dev/null && owned=1
fi
# Release only a lock we still hold, so a lock broken out from under us (we
# were wrongly judged dead) is never deleted while its new holder is inside.
[ "$(cat "$lockdir/holder" 2>/dev/null)" = "$$" ] && rm -rf "$lockdir" 2>/dev/null
# Belt and braces: only proceed if the pidfile actually names us.
[ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] || owned=0

if [ "$owned" != 1 ]; then
  # 3 ONLY when a live watcher genuinely holds the repo. Anything else (state
  # dir or pidfile path unusable, lost the race) is a hard 1: reporting 3 would
  # tell the caller "one is running, do not relaunch" when none is — the exact
  # silent blindness the single-instance guard exists to remove.
  if [ "$incumbent_live" = 1 ]; then
    echo "watcher already running for $repo (pid $incumbent); not starting a second one"
    exit 3
  fi
  echo "could not take the watcher pidfile $pidfile for $repo"
  exit 1
fi

# Bash defers a trap until the running foreground command returns, so a plain
# `sleep 30` would hold the pidfile for up to 30s after a TERM. Backgrounding
# the sleep and `wait`ing on it makes the trap run at once; release kills the
# sleep so it is not left behind.
sleep_pid=""
# SC2317: this body is unreachable only to a static reader - it is invoked
# indirectly by the EXIT/INT/TERM/HUP traps installed immediately below, which
# ShellCheck does not trace back to the function.
# shellcheck disable=SC2317
release() {
  [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null
  [ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"
  return 0
}
trap 'release' EXIT
# Signals exit 0, not 130/143: the exit-code contract is {0,1,3}, and a watcher
# stopped by a signal is one the caller should restart — which is what 0 means.
trap 'release; exit 0' INT TERM HUP
snapshot() {
  gh api "repos/$repo/issues?state=open&per_page=50" \
    --jq '[.[] | {n: .number, u: .updated_at, l: [.labels[].name]}]' 2>/dev/null
}
base=$(snapshot) || base=""
[ -z "$base" ] && { echo "baseline fetch failed for $repo"; exit 1; }
echo "watching $repo (baseline captured $(date +%H:%M:%S))"
for _ in $(seq 1 110); do
  sleep 30 & sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  sleep_pid=""
  cur=$(snapshot) || continue
  [ -z "$cur" ] && continue
  if [ "$cur" != "$base" ]; then
    echo "CHANGE DETECTED at $(date +%H:%M:%S)"
    echo "$cur"
    exit 0
  fi
done
echo "no change in ~55min; restart me"
exit 0
