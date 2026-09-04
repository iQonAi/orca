# orca

A lead-developer orchestrator agent for [Claude Code](https://claude.com/claude-code),
plus the GitHub watcher that gives it fast change detection.

Orca runs as the main session agent. It watches a project's GitHub issues,
plans work, dispatches it to subagent workers in isolated git worktrees, and
drives the resulting PRs through review to merge. You file issues; orca does
the rest and reports a digest each cycle.

> [!WARNING]
> **Run orca on private repos only.**
>
> Orca treats any `@bot-handle` mention in an issue or PR comment as an
> instruction addressed to itself, and nothing checks who wrote it. On a public
> repo that is an unauthenticated command channel into a session holding your
> live `gh` token, running shell commands on your machine, and merging its own
> PRs to `main`.
>
> Read access is enough to comment, so even on a private repo the audience is
> everyone with read access or better. See
> [Safety and blast radius](#safety-and-blast-radius) before you install.

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
| `ORCA_STYLE`  | (prompt)               | `claude` or `agents`; skips the prompt. With no tty, an existing `~/.claude` selects claude, otherwise the script exits 2 |
| `ORCA_REPO`   | `~/.local/share/orca`  | where the piped install clones the repo        |
| `ORCA_REF`    | `v0.1.0`               | the release tag the piped install checks out, and moves an existing clone to on re-run; `ORCA_REF=main` for development |
| `ORCA_MODE`   | `link`                 | `copy` to copy files instead of symlinking     |
| `CLAUDE_HOME` | `~/.claude`            | claude-style destination                       |
| `ORCA_BIN`    | `~/.local/bin`         | agents-style watcher destination               |

Re-runs are idempotent. Anything replaced is backed up to
`~/.orca-backups/<timestamp>/`.

`~/.claude/scripts/` is the home for runtime helper scripts. Do not use
`~/.claude/jobs/` — Claude Code reserves it for background-job state.

### Uninstall

```sh
./install.sh --uninstall
```

Or piped, the same way you installed:

```sh
curl -fsSL https://raw.githubusercontent.com/iQonAi/orca/main/install.sh | sh -s -- --uninstall
```

It sweeps both styles in one pass, so there is no prompt, and it honours
`CLAUDE_HOME` / `ORCA_BIN` if you set them at install time. Re-running it is
a no-op. Unlike install, it never clones, pulls, or touches the network — a
teardown that needs the network is broken by design.

Removes:

- `~/.claude/{agents/orca.md,hooks/orca-start-watcher.sh,scripts/gh-watch.sh}`
- `~/.local/bin/gh-watch` and `~/.config/orca/AGENTS.md` (plus
  `~/.config/orca` itself, if empty)
- the `SessionStart` entry it wired into `~/.claude/settings.json`

Only if it is what the installer would have written: an **absolute** symlink
into an orca checkout at the same relative path, or — in `ORCA_MODE=copy` — a
file still byte-identical to the repo's. A path you replaced or edited is
yours; it is printed as `left alone: …` and kept.

Piped, with no checkout on the machine, copy-mode files cannot be compared
against anything. They are reported as `! cannot verify …` and left in place
rather than guessed at — re-run from a checkout to finish the job.

It is **best effort**: a file it cannot remove does not abort the sweep. Every
other step still runs, anything left behind is named on the spot, and the exit
status is non-zero if anything remains, so re-running after fixing the cause
(a permission, a read-only mount) finishes the job.

Deliberately left alone:

- **Your backups.** `~/.orca-backups/<timestamp>/` is never touched or
  restored from — uninstall prints the path and you restore what you want by
  hand. Automatic restore is not possible against the current backup format:
  files are stored by basename with no record of where they came from, and
  `AGENTS.md` does not even share a basename with its destination.
  [#29](https://github.com/iQonAi/orca/issues/29) tracks the manifest work
  that would make it possible.
- **Everything else in `settings.json`.** Only entries equal to the one the
  installer wrote are dropped; other `SessionStart` entries, other hook
  types, and unrelated keys survive. An entry you merged the orca command
  *into* is not one the installer wrote, so it stays, with a note on stdout.
  Emptied `hooks.SessionStart` / `hooks` containers are pruned; the file
  itself is kept. (`jq` rewrites the file, so its indentation is normalized —
  the same thing install does when it wires the hook.)
- **Directories that are not orca's** — `~/.claude/*` and `~/.local/bin` stay
  whatever else they hold.
- **The checkout at `~/.local/share/orca`.** Delete it yourself if you want
  it gone.

Without `jq` it changes no JSON: it prints the exact entry to delete from
`settings.json` by hand, mirroring what install does. With `$HOME` unset or
empty it refuses outright rather than building paths under `/`.

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

## Safety and blast radius

Orca is an autonomous agent holding a live `gh` token, with write access to
your repo and a shell on your machine. Read this before pointing it at
anything.

### Issue and PR comments are an instruction channel

`agents/orca.md` defines two signals: an issue **assigned to the bot handle**
is dispatchable work, and **any `@bot-handle` mention** in an issue or PR
comment is "a message TO this orchestrator session; read it and dispatch/act
accordingly" (`agents/orca.md:41-45`).

Nothing checks who wrote that comment. There is no allow-list, author check, or
trusted-commenter setting anywhere in this repo. On a public repo, every
drive-by commenter is therefore addressing an agent that can run commands on
your machine and merge to `main` — an unauthenticated prompt-injection channel.

**Run orca on private repos only.** That shrinks the audience to people you
have granted some access — but be precise about who that is: **read access is
enough to comment on an issue or PR.** A private repo shared read-only with a
contractor, an outside collaborator, or a broad org team still has this channel
wide open. The trust boundary is everyone with read access or better, not just
the people who can write or merge.

On a public repo the audience is everyone, and you are the allow-list: read
every incoming comment yourself.

### What orca can do

On your machine:

- Runs `gh-watch.sh` as a long-lived background job polling GitHub every 30s
  (`scripts/gh-watch.sh`).
- Creates git worktrees and branches under `.claude/worktrees/`, and writes
  scratch state under `.claude/scratch/` (`agents/orca.md:107-109`).
- Dispatches subagent workers that edit files and run the project's
  `build | lint | typecheck | test` commands (`agents/orca.md:113-114`).
- **Claude-style install only:** `install.sh` symlinks (or copies) the agent,
  hook, and watcher into `~/.claude/` and adds a `SessionStart` hook to
  `~/.claude/settings.json` (`install.sh:78-114`). That is a global change, not
  a per-project one: the hook is invoked on every Claude Code session start, in
  every project. It exits immediately unless the session is the orca agent
  (`hooks/orca-start-watcher.sh:53`) — in any other session it makes no network
  call and spawns nothing. The agents-style install wires no hook at all
  (`install.sh:116-124`).
- The default install symlinks rather than copies (`ORCA_MODE=link`,
  `install.sh:66-76`), so what runs is the clone at `~/.local/share/orca`.
  The piped installer clones it at `ORCA_REF` (a release tag, `v0.1.0` by
  default), and a re-run moves it to that tag, so the playbook and watcher on
  your machine track that release. `ORCA_REF=main` follows `main` instead,
  and a re-run then changes them with no review step. `ORCA_MODE=copy` pins
  what you reviewed either way.

On your repo: comments on issues, sets labels, pushes branches, opens PRs,
posts and resolves review threads, requests reviewers, and merges its own PRs.

The agent frontmatter in `agents/orca.md` sets only `name`, `description`, and
`model`. It declares no tool restriction, so orca and its workers run with
whatever tool permissions your Claude Code session already grants.

### GitHub token scopes

`install.sh` never invokes `gh` — it neither checks nor requests scopes. Orca
uses whatever your existing `gh auth` session already has.

These are the operations orca performs over a full issue-to-merge run. Only the
first two rows are executable `gh` calls in this repo's scripts; every other row
is a step the playbook instructs the model to take, so the "Where" column points
at prose, not at code that enforces it.

| Operation                                                        | Where                                                            | Needs                    |
| ---------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------ |
| Poll open issues every 30s — number, `updated_at`, labels only   | `scripts/gh-watch.sh:201` — `gh api repos/<repo>/issues`         | read issues              |
| Resolve `<owner>/<repo>` from the cwd                            | `scripts/gh-watch.sh:54`, `agents/orca.md:22` — `gh repo view`   | read repo metadata       |
| Read issue assignees and recent comments each cycle              | `agents/orca.md:44-45`                                           | read issues              |
| Comment the plan on an issue; set priority and workflow labels   | `agents/orca.md:104-106`                                         | write issues             |
| Push the worker branch                                           | `agents/orca.md:115`                                             | write repo contents      |
| Open the PR, post review comments, reply to and resolve threads  | `agents/orca.md:115`, `agents/orca.md:122-126`                   | write pull requests      |
| Request an external reviewer                                     | `agents/orca.md:118` — `gh api -X POST .../requested_reviewers`  | write pull requests      |
| Merge the PR                                                     | `agents/orca.md:127`                                             | write contents and PRs   |

Net: a classic token needs `repo`, whose private-repo access covers all of the
above — plus `workflow` if a worker ever changes a file under
`.github/workflows/`. A fine-grained token needs Metadata: read, Issues:
read/write, Contents: read/write, Pull requests: read/write — plus Workflows:
write for that same workflow-file case — scoped to the repos you want orca to
manage, and no others.

Two properties of the 30s poll are worth knowing, since it is the one piece of
this that really is code. It requests `?state=open&per_page=50` and does not
paginate, so only the 50 most recent open items are watched; on a busier repo,
changes below that cut-off are missed. And GitHub's `/issues` endpoint returns
pull requests alongside issues, so the watcher sees PR activity as well.

The watcher makes roughly 120 requests per hour per repo (one poll every 30s),
counting against your token's REST rate limit.

### What gates a merge

The worker lifecycle in `agents/orca.md:116-130` specifies:

1. An internal review agent is spawned for every PR, checking issue completion,
   security, maintainability, and bugs. Its findings are posted as PR review
   comments, so they become resolvable threads.
2. If the project's `CLAUDE.md` names an external reviewer, that reviewer is
   requested in parallel.
3. Orca waits for the internal review and every requested external review.
4. Every thread must be addressed — fixed, then replied to with the fix and its
   commit hash; or replied to with a justification. Silent resolution is
   forbidden.
5. Merge happens only once every thread is addressed **and none is critical**.
6. **`on-hold` gate:** an `on-hold` label on the PR or its issue blocks merge
   and dispatch until the label is removed or a bot-handle comment signs off.
7. On issues, a `needs-info` label means wait; `ready-for-agent` means dispatch
   without asking (`agents/orca.md:104-106`).

**These gates are prompt instructions, not enforced code.** The executable
files in this repo are the watcher, the SessionStart hook, the installer, and
the test suite — none of them observe or block a merge. The gates hold exactly
as well as the model follows its playbook.

### Not verified, not implemented

- **Branch protection is unverified.** Nothing in this repo reads, respects, or
  handles branch protection rules. Orca merges with ordinary `gh` calls, so
  GitHub's own enforcement applies to it as to any other client — but that has
  not been tested here, and the playbook defines no handling for a merge GitHub
  rejects. The playbook does say never to commit or merge local `main`
  (`agents/orca.md:115`); work always goes through a branch and a PR.
- **There is no dry-run or approval mode.** No flag, environment variable, or
  setting in this repo makes orca plan without acting, or ask before it
  comments, pushes, or merges. Once running, it acts on its own.
- **Token cost per cycle is unmeasured.** Every watcher exit re-invokes the
  model, and the poll cadence adapts between 60s and ~1800s depending on
  activity (`agents/orca.md:54-57`), so cost scales with how busy the repo is.
  No measured figure is available; tracked in
  [#23](https://github.com/iQonAi/orca/issues/23).

## Tests

```sh
bash test/run.sh
```

The suite is hermetic: a stub `gh` replaces the network and
`GH_WATCH_STATE_DIR` redirects pidfiles to a temp dir, so a real watcher on
the machine is neither seen nor disturbed.

## License

MIT — see [LICENSE](LICENSE).
