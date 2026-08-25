# orca

A lead-developer orchestrator agent for [Claude Code](https://claude.com/claude-code),
plus the GitHub watcher that gives it fast change detection.

Orca runs as the main session agent. It watches a project's GitHub issues,
plans work, dispatches it to subagent workers in isolated git worktrees, and
drives the resulting PRs through review to merge. You file issues; orca does
the rest and reports a digest each cycle.

## Components

| Path                          | What it is                                                                 |
| ----------------------------- | -------------------------------------------------------------------------- |
| `agents/orca.md`              | The orchestrator playbook — a Claude Code agent definition.                 |
| `scripts/gh-watch.sh`         | Polls a repo's open issues every 30s; exits on any change. Its exit re-invokes orca as a harness task-notification, giving ~30s change detection. Enforces one watcher per repo via a pidfile, with `--status` and `--takeover` modes. |
| `hooks/orca-start-watcher.sh` | SessionStart hook. When the session is orca, it injects a directive telling orca to launch the watcher for the repo resolved from the git remote. No network calls; always exits 0. |
| `test/run.sh`                 | Hermetic test suite for both scripts (stubbed `gh`, temp state dirs).       |

## Requirements

- Claude Code CLI
- `gh` (GitHub CLI), authenticated for the repos you want orca to manage
- `jq`
- bash, git

## Install

Symlink the components into `~/.claude/`:

```sh
mkdir -p ~/.claude/agents ~/.claude/hooks ~/.claude/scripts
ln -s "$PWD/agents/orca.md"              ~/.claude/agents/orca.md
ln -s "$PWD/hooks/orca-start-watcher.sh" ~/.claude/hooks/orca-start-watcher.sh
ln -s "$PWD/scripts/gh-watch.sh"         ~/.claude/scripts/gh-watch.sh
```

Wire the SessionStart hook in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/orca-start-watcher.sh"
          }
        ]
      }
    ]
  }
}
```

`~/.claude/scripts/` is the home for runtime helper scripts. Do not use
`~/.claude/jobs/` — Claude Code reserves it for background-job state.

## Usage

From the project you want orca to manage:

```sh
claude --agent orca
```

On session start the hook injects the watcher directive; orca launches
`gh-watch.sh <owner>/<repo>` as a background job and begins its cycle:
assess open issues, plan, dispatch, review, merge, digest.

Signals orca reacts to:

- An issue **assigned to the configured bot handle** is dispatchable agent work.
- Any **@bot-handle mention** in an issue or PR comment is a message to orca.

Set the bot handle in the project's `CLAUDE.md`; orca asks once at startup if
it is unset.

### gh-watch.sh exit codes

| Exit | Meaning                                                                     |
| ---- | --------------------------------------------------------------------------- |
| 0    | Change detected, ~55min quiet expiry, or stopped by a signal — restart it. In `--status` mode: no watcher holds this repo. |
| 1    | Could not start (no repo, unusable state dir, baseline fetch failed) — fix the cause. |
| 3    | A watcher already holds this repo. In `--status` mode its pid is printed. `--takeover` replaces an incumbent that is not yours. |

## Tests

```sh
bash test/run.sh
```

The suite is hermetic: a stub `gh` replaces the network and
`GH_WATCH_STATE_DIR` redirects pidfiles to a temp dir, so a real watcher on
the machine is neither seen nor disturbed.

## License

MIT — see [LICENSE](LICENSE).
