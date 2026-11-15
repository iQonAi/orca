#!/bin/sh
#
# orca-project.sh - reads one field of the project data file (#55).
#
# Usage: orca-project.sh <field>
#   field  tracker | name | github.repo | linear.team | linear.project
#
# Prints the value on one line and exits 0. The file is .orca/project.json at
# the git root of the current directory. It is committed with the project, so
# it never holds a secret:
#
#   { "version": 1, "name": "Devbox", "tracker": "linear",
#     "github": { "repo": "iQonAi/devbox-control-plane" },
#     "linear": { "team": "IQONAI", "project": "Devbox" } }
#
#   version         1, required
#   name            non-empty string, required
#   tracker         "github" or "linear", required
#   github.repo     owner/repo, required: code and PRs live on GitHub with
#                   either tracker
#   linear.team     non-empty string, required when tracker is "linear"
#   linear.project  string, optional; absent prints an empty value
#
# The whole file is validated on every read, whichever field is asked for, so
# a consumer never acts on half of a broken file.
#
# No file: the defaults are tracker=github, github.repo from the origin
# remote, and name the repository part of that repo. linear.* is not set.
#
# Exit codes:
#   0  the value was printed (empty for an absent linear.project)
#   1  the file is malformed, the tracker is unknown, a required field is
#      missing or has the wrong shape, the field asked for is not set, or
#      with no file there is no origin remote to take the repo from. The
#      reason is on stderr. There is never a silent fallback: a broken file
#      is never read as a missing one.
#   2  usage: no field, or a field this script does not know

set -u

PROG=orca-project.sh
FILE_REL=.orca/project.json

die() {
  echo "$PROG: $*" >&2
  exit 1
}

usage() {
  echo "usage: $PROG <tracker|name|github.repo|linear.team|linear.project>" >&2
  exit 2
}

[ $# -eq 1 ] || usage
field=$1
case "$field" in
  tracker | name | github.repo | linear.team | linear.project) ;;
  -h | --help)
    echo "usage: $PROG <tracker|name|github.repo|linear.team|linear.project>"
    exit 0
    ;;
  *) usage ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"
root=$(git rev-parse --show-toplevel 2>/dev/null) || root=
[ -n "$root" ] || die "not inside a git repository"
file="$root/$FILE_REL"

# Same parse as bin/orca and the SessionStart hook: SSH and HTTPS remotes,
# with or without .git, down to owner/repo.
repo_from_origin() {
  url=$(git -C "$root" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  p=${url%.git}
  p=${p#*://*/} # https://host/owner/repo -> owner/repo
  p=${p#*:}     # git@host:owner/repo -> owner/repo
  case "$p" in */*) ;; *) return 1 ;; esac
  name=${p##*/}
  rest=${p%/*}
  owner=${rest##*/}
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  printf '%s/%s\n' "$owner" "$name"
}

# -e and -L: a dangling symlink at the path is a broken file, not a missing
# one, and jq names it below.
if [ ! -e "$file" ] && [ ! -L "$file" ]; then
  case "$field" in
    tracker) echo github ;;
    github.repo | name)
      repo=$(repo_from_origin) ||
        die "no $FILE_REL in $root and no origin remote to take the repo from; run: orca init"
      if [ "$field" = name ]; then echo "${repo##*/}"; else echo "$repo"; fi
      ;;
    *) die "$field is not set: no $FILE_REL in $root, so the tracker is github" ;;
  esac
  exit 0
fi

# One jq run validates the whole file and answers the field. --slurp, so an
# empty file or two documents back to back are named instead of read as one.
# Every value is a single line: a control character in one would split it.
# The first output line is `ok` or `error`; the rest is the value or the
# reason.
# shellcheck disable=SC2016
prog='
def str: type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not);
def repo: str and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
  and (split("/") | all(. != "." and . != ".."));
def err($m): "error", $m;
if length != 1 then err("must hold exactly one JSON object")
else .[0] |
  if type != "object" then err("must hold a JSON object, not \(type)")
  elif .version != 1 then err("version must be 1, not \(.version | tojson)")
  elif (.name | str | not) then err("name must be a non-empty string")
  elif .tracker == null then err("tracker is missing (github or linear)")
  elif (.tracker | IN("github", "linear") | not) then
    err("unknown tracker \(.tracker | tojson) (github or linear)")
  elif (.github | type) != "object" then err("github is missing: github.repo is required")
  elif (.github.repo | repo | not) then err("github.repo must be owner/repo, not \(.github.repo | tojson)")
  elif .tracker == "linear" and (.linear | type) != "object" then
    err("linear is missing: tracker is linear, so linear.team is required")
  elif .linear != null and (.linear | type) != "object" then err("linear must be an object")
  elif .linear != null and (.linear.team | str | not) then err("linear.team must be a non-empty string")
  elif .linear != null and .linear.project != null and (.linear.project | str | not) then
    err("linear.project must be a non-empty string when present")
  elif ($f | startswith("linear.")) and .linear == null then
    err("\($f) is not set (the tracker is \(.tracker))")
  else "ok", (getpath($f | split(".")) // "")
  end
end'
NL=$(printf '\nx')
NL=${NL%x}
out=$(jq -r -s --arg f "$field" "$prog" "$file" 2>&1) ||
  die "could not read $file as JSON: ${out%%"$NL"*}"
# $(...) drops trailing newlines, so an empty value leaves `ok` alone.
case "$out" in
  ok) value= ;;
  ok"$NL"*) value=${out#ok"$NL"} ;;
  error"$NL"*) die "$file: ${out#error"$NL"}" ;;
  *) die "$file: unexpected jq output" ;;
esac
printf '%s\n' "$value"
