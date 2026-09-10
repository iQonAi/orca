#!/usr/bin/env bash
# Polls a GitHub repo's open issues and PRs every 30s (`gh issue list` plus
# `gh pr list`); exits as soon as issue/comment/label state changes. Exiting
# re-invokes the orchestrator (harness task-notification), giving ~30s change
# detection under the harness's 60s wakeup floor — ~35s on the poll that sees a
# difference, which is re-fetched $GH_WATCH_CONFIRM_DELAY seconds later
# (default 5) and must still differ from the baseline before the watcher exits.
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
  --status)
    mode=status
    shift
    ;;
  --takeover)
    mode=takeover
    shift
    ;;
  --*)
    echo "usage: gh-watch.sh [--status|--takeover] [owner/repo]"
    exit 1
    ;;
esac

repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}"
[ -z "$repo" ] && {
  echo "usage: gh-watch.sh <owner/repo> (none given, none detected from cwd)"
  exit 1
}

state_dir="${GH_WATCH_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gh-watch-$(id -u)}"
if [ "$mode" != status ]; then
  # `mkdir -p` RETURNS 0 for a directory that already exists but is unusable,
  # so its exit status alone is not a guard — check the properties we need.
  mkdir -p "$state_dir" 2>/dev/null
  { [ -d "$state_dir" ] && [ -w "$state_dir" ] && [ -x "$state_dir" ]; } || {
    echo "watcher state dir $state_dir is not a writable directory"
    exit 1
  }
fi
pidfile="$state_dir/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_').pid"

# The repo goes into an ERE below, so escape its regex metacharacters first.
# A repo name may legally contain `.`, and an unescaped `.` is "any character":
# the pattern built for `octocat/watch.dot` would match a watcher for
# `octocat/watchxdot`, and this repo's pidfile would then be honoured for a
# watcher of another repo — refusing the launch and leaving this repo unwatched.
repo_re="$(printf '%s' "$repo" | sed 's/[]\.[*^$+?(){}|]/\\&/g')"

# Is $1 a live watcher FOR THIS REPO? (pid alive is not enough: pids get
# recycled.) The match is anchored on the script name and on the end of the
# command line, because an unanchored `gh-watch` substring test matches far
# more than real watchers — editors, greps, and above all the harness's own
# wrapper shell, which is the classic self-match bug. The trailing alternative
# with no repo argument covers a watcher launched with the repo auto-detected
# from cwd: only such a watcher for THIS repo can have written this repo's
# pidfile.
#
# Mode words are allowed generically, not one by one: a watcher launched as
# `gh-watch.sh --takeover <repo>` keeps that word in its argv for the rest of
# its life, and matching only the bare form answered "none running" about a
# watcher that was polling (#30). Two limits on that are worth stating plainly:
#
#   - The match set really did grow. `gh-watch.sh --status`, a wrapper
#     `sh -c '... gh-watch.sh --status'` and `vim scripts/gh-watch.sh --nofork`
#     all match now, and --status runs are frequent (the playbook calls one per
#     cycle). What keeps this safe is NOT the anchoring: it is that
#     live_watcher() is only ever asked about a pid read from THIS repo's own
#     pidfile, so a wrong answer needs that pid to have been recycled onto one
#     of those processes.
#   - "A mode word added later needs no second fix here" holds only for a
#     VALUELESS long flag. `--interval 60`, `--delay=5` and every short flag
#     fail to match, and would each need this pattern widened again.
#
# `-ww` is required — BSD `ps` truncates the command column to terminal width.
live_watcher() {
  [ -n "${1:-}" ] || return 1
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  ps -ww -o args= -p "$1" 2>/dev/null |
    grep -qE "gh-watch\.sh([[:space:]]+--[A-Za-z-]+)*([[:space:]]+$repo_re)?[[:space:]]*$"
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
    for _ in $(seq 1 20); do
      live_watcher "$incumbent" || break
      sleep 0.5
    done
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
  if mkdir "$lockdir" 2>/dev/null; then
    got_lock=1
    break
  fi
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
(printf '%s\n' "$$" >"$lockdir/holder") 2>/dev/null
incumbent="$(cat "$pidfile" 2>/dev/null)"
if live_watcher "$incumbent"; then
  incumbent_live=1
else
  # Both writes go through a subshell: a FAILED redirection is reported by the
  # shell itself, and only a redirection on the subshell suppresses it. An
  # unwritable pidfile path (e.g. a directory) must fail quietly here and be
  # reported by the exit-code branch below, not leak a raw shell error.
  rm -f "$pidfile" 2>/dev/null
  (printf '%s\n' "$$" >"$pidfile") 2>/dev/null && owned=1
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
# Built from the GraphQL-backed CLI listings, NOT from `repos/<repo>/issues`.
# That REST listing served inconsistent EMPTY responses for minutes at a time
# from a bad replica — it answered `[]` while `gh pr list` returned the PR that
# was open — and a watcher reading one of those as "everything just closed"
# reports a change that never happened (#32). `gh issue list` and `gh pr list`
# stayed consistent through every observed flake window. They take two calls
# because `gh issue list` excludes pull requests, where the REST listing
# included them; the concatenation is sorted so listing order alone can never
# look like a change.
#
# EMPTY IS NOT FAILURE. A listing that succeeds with no items is the truth about
# a quiet repo — zero open issues alongside one open PR is an ordinary state.
# Only a non-zero exit means "no answer", and only that returns non-zero here.
# Conflating the two would leave the watcher deaf on exactly the repos where a
# first issue arriving is the thing worth waking up for.
snapshot() {
  local issues prs
  # stderr is dropped, as it was on the call this replaced: the exit status
  # already says "no answer", and a listing that is failing fails on every poll
  # — 110 copies of the same gh error in the output the orchestrator reads. A
  # failure that is not transient is caught by the baseline, which does report.
  issues=$(gh issue list --repo "$repo" --state open --limit 50 \
    --json number,updatedAt,labels \
    --jq '.[] | "\(.number) \(.updatedAt) \([.labels[].name] | join(","))"' 2>/dev/null) || return 1
  prs=$(gh pr list --repo "$repo" --state open --limit 50 \
    --json number,updatedAt,labels \
    --jq '.[] | "\(.number) \(.updatedAt) \([.labels[].name] | join(","))"' 2>/dev/null) || return 1
  {
    [ -n "$issues" ] && printf '%s\n' "$issues"
    [ -n "$prs" ] && printf '%s\n' "$prs"
  } | sort
}
# Seconds between a poll that differs from the baseline and the fetch that has
# to differ from it too before the watcher exits. It is the whole cost of the
# confirm, paid only on a differing poll; only the tests need to change it.
# Validated here rather than at the point of use: an unusable value reaches
# `sleep`, which fails, prints its usage into the output the orchestrator reads,
# and leaves no gap between the two fetches at all — the confirm degrades to
# nothing, silently, in the one direction that matters.
# Two conditions, because the shape alone is not the value: it must be all
# digits, AND at least one of them must be non-zero. `00` and `000` are as
# digits-only as `30` is, and each one sleeps for exactly no time — the same
# collapse a non-numeric value causes, reached by a value that looks well
# formed. Asking for a non-zero digit rejects every spelling of zero at once,
# and still accepts `10`, which "holds no zero" would refuse.
confirm_delay="${GH_WATCH_CONFIRM_DELAY:-5}"
confirm_delay_ok=0
case "$confirm_delay" in
  *[!0-9]*) ;;
  *[1-9]*) confirm_delay_ok=1 ;;
esac
if [ "$confirm_delay_ok" != 1 ]; then
  echo "GH_WATCH_CONFIRM_DELAY '$confirm_delay' is not a positive integer; using 5" >&2
  confirm_delay=5
fi
# A FAILED baseline is fatal; an EMPTY one is not. The watcher has nothing to
# compare against if it never got an answer, but "" is a perfectly good baseline
# for a repo with nothing open yet.
base=$(snapshot) || {
  echo "baseline fetch failed for $repo"
  exit 1
}
echo "watching $repo (baseline captured $(date +%H:%M:%S))"
for _ in $(seq 1 110); do
  sleep 30 &
  sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  sleep_pid=""
  # Only a failed fetch is skipped. An empty answer is a real snapshot: it says
  # the repo has nothing open, which differs from a baseline that had something.
  cur=$(snapshot) || continue
  if [ "$cur" != "$base" ]; then
    # CONFIRM. Defence in depth against any transient the listings can still
    # produce: take a second snapshot and exit only if it ALSO differs from the
    # baseline. Against the BASELINE, not against $cur: activity that keeps
    # moving between the two fetches is a real change, and comparing the two
    # snapshots with each other would swallow exactly that case.
    sleep "$confirm_delay" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null
    sleep_pid=""
    # A FAILED confirming fetch confirmed nothing. Leave the baseline standing
    # and poll on: the next poll sees the same difference and confirms it then,
    # one poll late instead of wrong.
    confirm=$(snapshot) || continue
    [ "$confirm" = "$base" ] && continue
    echo "CHANGE DETECTED at $(date +%H:%M:%S)"
    echo "$confirm"
    exit 0
  fi
done
echo "no change in ~55min; restart me"
exit 0
