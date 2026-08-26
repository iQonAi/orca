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

One line — it prompts for which configuration style to install:

```sh
curl -fsSL https://raw.githubusercontent.com/iQonAi/orca/main/install.sh | sh
```

Or, to read before you run:

```sh
git clone https://github.com/iQonAi/orca.git && cd orca && ./install.sh
```

Styles:

- **claude** — symlinks the agent, hook, and watcher into
  `~/.claude/{agents,hooks,scripts}` and wires the SessionStart hook into
  `~/.claude/settings.json` (needs `jq`; prints the snippet to add by hand
  if `jq` is missing).
- **agents** — for AGENTS.md-convention agents (Codex/Cursor/Gemini-class):
  installs the watcher to `~/.local/bin/gh-watch` and the playbook to
  `~/.config/orca/AGENTS.md`. The SessionStart hook is Claude-specific and
  is skipped; launch the watcher yourself per the playbook.

Environment overrides:

| Variable      | Default                | Meaning                                        |
| ------------- | ---------------------- | ---------------------------------------------- |
| `ORCA_STYLE`  | (prompt)               | `claude` or `agents`; required when no tty     |
| `ORCA_REPO`   | `~/.local/share/orca`  | where the piped install clones the repo        |
| `ORCA_MODE`   | `link`                 | `copy` to copy files instead of symlinking     |
| `CLAUDE_HOME` | `~/.claude`            | claude-style destination                       |
| `ORCA_BIN`    | `~/.local/bin`         | agents-style watcher destination               |

Re-runs are idempotent. Anything replaced is backed up to
`~/.orca-backups/<timestamp>/`.

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
