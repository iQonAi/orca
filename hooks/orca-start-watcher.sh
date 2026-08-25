#!/usr/bin/env bash
#
# orca-start-watcher.sh — SessionStart hook.
#
# Makes orca's GitHub issue watcher start deterministically. When THIS session
# is the orca orchestrator, this hook injects a SessionStart directive telling
# orca to ensure its `gh-watch.sh` background watcher is running for the current
# repo. It fires on every SessionStart source (startup, resume, clear, compact),
# so a freshly started OR resumed/renamed orca session is always reminded.
#
# Why inject a directive instead of spawning the watcher here?
#   orca's watcher earns its keep by EXITING on change: its exit is what
#   re-invokes the orchestrator (a harness background-job task-notification).
#   Only a harness-tracked background job (started by the agent via the Bash
#   tool's run_in_background) produces that notification. A hook can only
#   spawn a plain OS process, whose exit the harness does not observe — so a
#   hook-spawned watcher would poll GitHub yet never wake orca, AND it would
#   hold gh-watch.sh's per-repo pidfile, so orca's launch of the real, tracked
#   watcher would exit 3 as a duplicate. That is worse than nothing.
#   Hence: the hook makes the START DETERMINISTIC (unmissable directive with
#   the resolved repo); orca still launches the tracked job itself.
#
# Detecting the orca session:
#   We key off the SessionStart stdin JSON `agent_type` field — the `--agent`
#   value the harness populates per session (documented in the Claude Code
#   hook-events payload, and the same channel the sibling
#   assign-worker-identity.sh reads). For an `--agent orca` MAIN session,
#   agent_type == "orca"; a SUBAGENT carries its OWN type (e.g. "implementer",
#   "general-purpose"), so gating on agent_type == "orca" both selects the
#   orca session and naturally excludes the subagents orca spawns — no separate
#   env discriminator needed. (Env vars like CLAUDE_CODE_CHILD_SESSION are NOT
#   reliable here: a tool subprocess of a live orca MAIN session was observed
#   to report CLAUDE_CODE_CHILD_SESSION=1.)
#
# Repo resolution is LOCAL ONLY — parsed from the git remote — so the hook
# makes no network call. A SessionStart hook must be instant; `gh repo view`
# hits api.github.com and could hang startup on a slow/unreachable network.
#
# Exit code: always 0. A SessionStart hook must never disrupt or slow startup,
# so every branch fails OPEN — the worst case is that no directive is injected
# (orca's playbook still starts the watcher on its own).

set -uo pipefail

# Read the SessionStart JSON payload from stdin.
input="$(cat 2>/dev/null || true)"

# Guard: only the orca session (main session; subagents carry their own type).
agent_type=""
if command -v jq >/dev/null 2>&1; then
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null || true)"
fi
[ "$agent_type" = "orca" ] || exit 0

# Working directory: prefer the payload's cwd, fall back to $PWD.
cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$PWD"

# Resolve <owner>/<repo> LOCALLY from the git remote — no network call.
remote_url="$(git -C "$cwd" config --get remote.origin.url 2>/dev/null || true)"
[ -n "$remote_url" ] || exit 0

# Normalize both SSH (git@host:owner/repo.git) and HTTPS
# (https://host/owner/repo.git) forms down to owner/repo.
repo_path="${remote_url%.git}"          # strip trailing .git
repo_path="${repo_path#*://*/}"          # strip https://host/ prefix (if any)
repo_path="${repo_path#*:}"              # strip git@host: prefix (if any)
# repo_path should now be owner/repo; keep only the last two path segments.
owner="$(printf '%s' "$repo_path" | awk -F/ '{ if (NF>=2) print $(NF-1) }')"
name="$(printf '%s' "$repo_path" | awk -F/ '{ print $NF }')"
[ -n "$owner" ] && [ -n "$name" ] || exit 0
repo="${owner}/${name}"

context="Orca watcher autostart: this is the orca orchestrator session in
repo \`${repo}\`. As a first action, launch \`~/.claude/scripts/gh-watch.sh ${repo}\`
as a background job (run_in_background) so its exit re-invokes you on any
issue/comment/label change. Do NOT pre-check with pgrep — the script holds a
per-repo pidfile and enforces single-instance itself. To check without
launching, run \`gh-watch.sh --status ${repo}\` in the foreground: 0 = none
running (launch one), 3 = one already holds this repo (its pid is printed).
If that incumbent is not your own background job, take it over with
\`gh-watch.sh --takeover ${repo}\` instead of relaunching."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
else
  # No jq: plain stdout is also added to SessionStart context.
  printf '%s\n' "$context"
fi

exit 0
