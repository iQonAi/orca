#!/usr/bin/env bash
# Polls a GitHub repo's open issues and PRs every 30s (`gh issue list` plus
# `gh pr list`); exits as soon as issue/comment/label state changes. Exiting
# re-invokes the orchestrator (harness task-notification), giving ~30s change
# detection under the harness's 60s wakeup floor — ~35s on the poll that sees a
# difference, which is re-fetched $GH_WATCH_CONFIRM_DELAY seconds later
# (default 5) and must still differ from the baseline before the watcher exits.
#
# Usage: gh-watch.sh [--status|--takeover|--ignore <numbers>] [owner/repo]
#   No repo argument: repo auto-detected from cwd via `gh repo view`.
#   --status    report whether a live watcher holds this repo, then exit.
#               Never launches, never writes state — safe to call every cycle.
#               Also reports the ignore set, when the repo has one.
#   --takeover  terminate the live watcher holding this repo (if any), then
#               become the watcher in its place. For an incumbent that is not
#               the caller's own job: its exit notifies whoever launched it,
#               not the caller, so leaving it in place means blind polling.
#   --ignore <numbers>
#               record the issue/PR numbers the CALLER currently owns, then
#               exit 0 without launching anything. A change confined to those
#               numbers is not a wake-up, so the caller's own workers pushing
#               commits, opening PRs and posting review comments no longer
#               re-invoke it to report work it did itself. `--ignore ""`
#               clears the set. The numbers are ONE namespace over issues and
#               PRs, because an owner owns an issue and its PR together.
#               The set is re-read on EVERY poll, so it changes without
#               restarting the watcher — and a restart is itself the
#               re-invocation this exists to remove. A live watcher is not
#               required: the set is state, and a watcher started later reads
#               it.
#               BLIND SPOT, by construction: an external comment, an
#               @-mention or an `on-hold` label on an ignored number does not
#               wake the watcher either. Nothing here can tell those from the
#               caller's own work — same token, same actor — so the caller
#               compensates: poll faster while comments flow, and re-read your
#               own PRs before merging them.
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
#      holds this repo. --ignore: the set was written. In every case except
#      --ignore: the caller SHOULD (re)start a watcher.
#   1  could not start (no repo resolved, unusable state dir, pidfile not
#      takeable, baseline fetch failed), or --ignore was given something that
#      is not a list of numbers -> fix the cause, do not spin.
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
# watch concurrently, and one ignore file per repo beside it. NEVER
# ~/.claude/jobs/ — the harness reserves that.
# A stale pidfile (killed/crashed watcher) cannot wedge the script: the
# recorded pid must be alive AND still be a gh-watch for THIS repo to be
# honoured, otherwise the file is reclaimed. Reclaiming races (two launches
# both finding the same stale file) are serialized by a `mkdir` mutex — see
# the acquire block below.
set -u

usage="usage: gh-watch.sh [--status|--takeover|--ignore <numbers>] [owner/repo]"
mode=watch
ignore_arg=""
case "${1:-}" in
  --status)
    mode=status
    shift
    ;;
  --takeover)
    mode=takeover
    shift
    ;;
  --ignore)
    mode=ignore
    # The value is REQUIRED and may be EMPTY — `--ignore ""` is how the set is
    # cleared — so its absence is a question about the argument count, not
    # about the string. Testing -z here would silently turn `--ignore` alone
    # into "clear", and a caller that meant to name its numbers and mistyped
    # the flag would un-ignore everything it owns instead of being told.
    [ "$#" -ge 2 ] || {
      echo "$usage"
      exit 1
    }
    ignore_arg="$2"
    shift 2
    ;;
  --*)
    echo "$usage"
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
  #
  # PRIVATE when we create it. The default home is $TMPDIR or /tmp, and this
  # directory holds the pidfile, the lock and the ignore set: created with the
  # ambient umask, a permissive one (002, 000) leaves it group- or
  # world-writable, and anyone local could then write the ignore set and deafen
  # the watcher, or plant a pidfile and stop it starting. `-m` applies only when
  # mkdir CREATES the directory, so an existing state dir keeps the mode it has
  # — nobody's working setup changes under them.
  #
  # SC2174 is right that `-m` with `-p` covers only the DEEPEST directory, and
  # that is the one being asked for: the leaf is what holds the pidfile, the
  # lock and the ignore set. Every parent above it already exists on the paths
  # this script builds — $XDG_RUNTIME_DIR, or $TMPDIR/`/tmp` — so there are no
  # intermediate directories left to create. A $GH_WATCH_STATE_DIR pointing
  # somewhere deep and absent is the exception: the levels above the leaf are
  # then made with the ambient umask, and the operator who chose that path owns
  # that choice.
  # shellcheck disable=SC2174
  mkdir -p -m 700 "$state_dir" 2>/dev/null
  { [ -d "$state_dir" ] && [ -w "$state_dir" ] && [ -x "$state_dir" ]; } || {
    echo "watcher state dir $state_dir is not a writable directory"
    exit 1
  }
fi
repo_slug="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
pidfile="$state_dir/$repo_slug.pid"
# The ignore set lives beside the pidfile, per repo, and OUTLIVES any single
# watcher: the caller writes it once and every watcher for the repo — this one,
# and the one that replaces it after an exit — reads the same file.
ignore_file="$state_dir/$repo_slug.ignore"

# The set as written, or "" when there is none. A missing file is the ordinary
# state (nobody has ignored anything), not an error.
#
# A set that EXISTS but cannot be read is a third state, and it must not look
# like the first. Reading it as "" fails open — toward waking the caller, which
# is the safe direction — but silently: the watcher stops filtering, and
# --status, the one probe the playbook runs every cycle, answers "no set" for
# "a set I cannot read". So say it, on stderr, once per episode: this is read
# every poll, and 110 copies of one line is the noise the snapshot's own error
# handling exists to avoid.
ignore_unreadable=0
read_ignore() {
  if [ -e "$ignore_file" ] && { [ ! -f "$ignore_file" ] || [ ! -r "$ignore_file" ]; }; then
    if [ "$ignore_unreadable" != 1 ]; then
      echo "ignore set $ignore_file is not readable; ignoring nothing" >&2
      ignore_unreadable=1
    fi
    return 0
  fi
  ignore_unreadable=0
  cat "$ignore_file" 2>/dev/null
  return 0
}

# Drop every row of snapshot $1 whose number is in the space-separated set $2.
# `snapshot()` emits `number updatedAt labels`, so the number is the first
# field and awk's default splitting finds it with no new dependency.
#
# The set reaches awk through the ENVIRONMENT, not through `-v`. `-v` runs its
# value through escape processing, so a file holding `\062\060` would make awk
# drop #20 — a number the set does not contain. The write path validates
# digits; the read path takes whatever is on disk, so it is the read path that
# must not decode it.
ignore_filter() {
  [ -n "$2" ] || {
    printf '%s' "$1"
    return 0
  }
  printf '%s\n' "$1" | GH_WATCH_IGNORE_SET="$2" awk '
    BEGIN {
      n = split(ENVIRON["GH_WATCH_IGNORE_SET"], a, /[ \t\n]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") drop[a[i]] = 1
    }
    !($1 in drop)'
}

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
#     `--ignore <numbers>` is exactly such a flag and is deliberately NOT
#     matched: an --ignore run writes the set and exits without ever taking
#     the pidfile, so no pid this function is ever asked about can be one.
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
  # Reported on the line after the watcher's, and only when there is a set:
  # --status runs once per orchestrator cycle, and a line that says nothing is
  # noise in the output the caller actually reads.
  ignoring="$(read_ignore)"
  if live_watcher "$incumbent"; then
    echo "watcher running for $repo (pid $incumbent)"
    [ -n "$ignoring" ] && echo "ignoring: $ignoring"
    exit 3
  fi
  echo "no watcher running for $repo"
  [ -n "$ignoring" ] && echo "ignoring: $ignoring"
  exit 0
fi

if [ "$mode" = ignore ]; then
  # VALIDATE THE WHOLE LIST BEFORE WRITING ANY OF IT. A partial write followed
  # by a failure would un-ignore the numbers the caller still owns, and it
  # would do it at the worst moment: the caller learns of the error, fixes the
  # command, and in between its own workers wake it.
  ignore_set=""
  # Word splitting is the point here: the value is a list of numbers in one
  # argument, spelled the way a caller would say it. PATHNAME EXPANSION is not,
  # and `set -f` turns it off for the split: left on, a value holding `*` is
  # expanded against the working directory, so what gets validated is not what
  # was typed — and in a directory of numeric filenames the expansion passes
  # the digits-only check that the typed value must fail. Globbing stays off
  # for the rest of this branch, which exits a few lines below.
  set -f
  # shellcheck disable=SC2086
  for token in $ignore_arg; do
    case "$token" in
      *[!0-9]*)
        echo "gh-watch.sh --ignore expects issue/PR numbers, got '$token'"
        exit 1
        ;;
    esac
    ignore_set="${ignore_set:+$ignore_set }$token"
  done
  set +f
  # `mv` onto a DIRECTORY succeeds by moving the temp file INSIDE it, so without
  # this guard the write reports success, records nothing, orphans the temp file
  # in there, and leaves `read_ignore` answering "" for good — the caller is told
  # its numbers are ignored while the watcher goes on waking it on its own work.
  # The pidfile path refuses this shape already (its write fails on a directory);
  # this one has to ask.
  [ -d "$ignore_file" ] && {
    echo "could not write the ignore set $ignore_file for $repo (it is a directory)"
    exit 1
  }
  # Atomic: a watcher polls this file every 30s, and a truncated read is a set
  # that is briefly missing numbers the caller owns — which fires. Writing a
  # temp file in the same directory and renaming it means every read sees
  # either the old set or the new one.
  #
  # `mktemp` names the temp file, and creates it, exclusively. A name built here
  # from the pid is predictable, so anyone who can write in the state dir can
  # put something at that path first — a symlink, which the redirect below would
  # follow, writing the set wherever the link points, as this user.
  #
  # The template is the TARGET's own path plus the placeholder, so the temp file
  # is created beside the file it replaces. `mktemp` with no template lands in
  # $TMPDIR, which can be another filesystem, and `mv` across filesystems is a
  # copy — no longer the atomic rename this whole dance exists for.
  #
  # A failed `mktemp` (an unwritable state dir reaching this far) leaves
  # $ignore_tmp empty and takes the same exit as a failed write: same message,
  # same code, previous set untouched.
  ignore_tmp="$(mktemp "$ignore_file.XXXXXX" 2>/dev/null)"
  {
    [ -n "$ignore_tmp" ] &&
      (printf '%s\n' "$ignore_set" >"$ignore_tmp") 2>/dev/null &&
      mv -f "$ignore_tmp" "$ignore_file" 2>/dev/null
  } || {
    [ -n "$ignore_tmp" ] && rm -f "$ignore_tmp" 2>/dev/null
    echo "could not write the ignore set $ignore_file for $repo"
    exit 1
  }
  if [ -n "$ignore_set" ]; then
    echo "ignoring $ignore_set for $repo"
  else
    echo "ignore set cleared for $repo"
  fi
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
# The set in force when the baseline was taken. It is half of the union below,
# so it is read here rather than defaulted to empty: a watcher started while
# numbers are already ignored must not treat its first poll as a release.
ignore_prev="$(read_ignore)"
echo "watching $repo (baseline captured $(date +%H:%M:%S))"
for _ in $(seq 1 110); do
  sleep 30 &
  sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  sleep_pid=""
  # Only a failed fetch is skipped. An empty answer is a real snapshot: it says
  # the repo has nothing open, which differs from a baseline that had something.
  cur=$(snapshot) || continue
  # RE-READ THE SET EVERY POLL. Taking it once at startup would mean a restart
  # per change of ownership, and a restart is a re-invocation of the caller —
  # the very thing being removed.
  ignore_now="$(read_ignore)"
  # THE UNION of the set in force at the baseline and the set in force now.
  # A number can be released in the same gap in which it changed ("merge, then
  # release"): filtered with the current set alone, that poll reports the
  # caller's own merge as news. The union covers the release poll, and the raw
  # snapshot below becomes the next baseline, so from the next poll on the
  # number is compared like any other.
  #
  # It is SYMMETRIC, and that is deliberate: it also swallows a change that
  # landed just BEFORE the number was claimed. The caller claims a number when
  # it is about to work on it and reads that issue or PR before acting, so a
  # change dropped on the claiming poll is one it is about to read anyway.
  #
  # No separator when a side is empty: an unignored repo would otherwise union
  # to a single space, which is not an empty set, and every poll would run the
  # filter over a set that drops nothing.
  ignore_union="${ignore_prev:+$ignore_prev }$ignore_now"
  base_seen="$(ignore_filter "$base" "$ignore_union")"
  if [ "$(ignore_filter "$cur" "$ignore_union")" != "$base_seen" ]; then
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
    # FILTERED TOO, with the SAME set the poll used. This is the easiest place
    # to leave the ignore set out, and the most expensive: the confirm is taken
    # seconds after a differing poll, which is exactly when the caller's own
    # worker is pushing, so an unfiltered confirm hands back most of the wake-ups
    # the filter just removed. The same set, not a re-read one, because these
    # two fetches are one decision about one baseline.
    [ "$(ignore_filter "$confirm" "$ignore_union")" = "$base_seen" ] && continue
    echo "CHANGE DETECTED at $(date +%H:%M:%S)"
    # The RAW snapshot, ignored rows included: the caller is being woken and
    # wants the whole state of the repo, not the part it does not own.
    echo "$confirm"
    exit 0
  fi
  # The raw snapshot becomes the next baseline. With no ignore set this changes
  # nothing (the two are equal here by definition). With one, it is what stops a
  # change made while a number was ignored from firing the moment it is
  # released: that change is already in the baseline it is compared against.
  #
  # The union window closes HERE, beside the baseline it protects, and nowhere
  # else. Advancing it on every poll instead spends it on the polls that leave
  # the baseline standing — a failed confirming fetch, or a confirm that agreed
  # with the baseline — and the window then lapses over a baseline that never
  # moved. Release the number in that gap and the change made while it was
  # ignored fires. Not advancing on those polls only widens the union, which is
  # the safe direction: it ignores more, never less.
  base="$cur"
  ignore_prev="$ignore_now"
done
echo "no change in ~55min; restart me"
exit 0
