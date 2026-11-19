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
> instruction addressed to itself. The playbook tells it to act only on
> mentions from accounts with write access or better, but that is a prompt
> instruction, not enforced code. On a public repo that is an unauthenticated
> command channel into a session holding the bot's GitHub token, running
> shell commands on your machine, and merging its own PRs to `main`.
>
> Read access is enough to comment, so even on a private repo the audience is
> everyone with read access or better. See
> [Safety and blast radius](#safety-and-blast-radius) before you install.

## Components

| Path                          | What it is                                                                 |
| ----------------------------- | -------------------------------------------------------------------------- |
| `agents/orca.md`              | The orchestrator playbook — a Claude Code agent definition.                 |
| `scripts/gh-watch.sh`         | Polls a repo's open issues and PRs every 30s (`gh issue list` plus `gh pr list`); exits on any change that a second fetch confirms. Its exit re-invokes orca as a harness task-notification, giving ~30s change detection, ~35s on the poll that sees the change. On a project whose tracker is Linear, it also polls the team's open Linear issues. Enforces one watcher per repo via a pidfile, with `--status`, `--takeover` and `--ignore` modes; `--ignore` records the issue/PR numbers and Linear identifiers orca currently owns, so its own workers' pushes and comments do not wake it. |
| `hooks/orca-start-watcher.sh` | SessionStart hook. When the session is orca, it injects a directive telling orca to launch the watcher for the repo resolved from the git remote. No network calls; always exits 0. |
| `scripts/orca-project.sh`     | Reads one field of the project data file, `.orca/project.json`, and prints it. With no file it answers the defaults (GitHub tracker, repo from the git remote); a broken file is an error, never a default. See [Project data](#project-data). |
| `bin/orca`                    | The launcher, and how a session is started. Runs the preflight checks — tools on `PATH`, the bot's token file and the login it authenticates, the bot's write access on the repository, the installed files and hook wiring, no second orca on the repository — then exports `GH_TOKEN` and the bot's git identity and execs `claude --agent orca`. `orca --check` runs the checks alone; `orca init` writes the project data file and opens a PR with it. |
| `test/run.sh`                 | Hermetic test suite for the scripts, the installer and the launcher (stubbed `gh` and `claude`, temp HOMEs and state dirs). |

## Requirements

- Claude Code CLI
- `gh` (GitHub CLI). Orca authenticates with the bot's own token (see
  [Bot identity](#bot-identity)), so it needs no `gh auth login` of its own
- `jq`
- bash, git
- a GitHub account for the bot, with write access to the repos orca manages
- "Allow auto-merge" turned on in each repo orca manages (Settings, General,
  Pull Requests). Orca merges through auto-merge, so you approve and GitHub
  merges (see [What gates a merge](#what-gates-a-merge))
- for a Linear project: the Linear MCP server, connected as a dedicated bot
  Linear user that is a member of the project's Linear team. Setting up that
  user is up to you; orca names the account it finds in its first digest.
  The watcher also needs a Linear personal API key in `LINEAR_API_KEY` (see
  [Linear polling](#linear-polling))

## Install

One line — it prompts for which configuration style to install:

```sh
curl -fsSL https://raw.githubusercontent.com/iQonAi/orca/main/install.sh | sh
```

Piped into a terminal it still prompts while `ORCA_STYLE` is unset, because
the prompt reads `/dev/tty`. With no tty (CI, a container build) set
`ORCA_STYLE` explicitly; if it is unset there, the script exits 2 and does
not touch `~/.claude` or `CLAUDE_HOME`:

```sh
curl -fsSL https://raw.githubusercontent.com/iQonAi/orca/main/install.sh | ORCA_STYLE=claude sh
```

Or, to read before you run:

```sh
git clone https://github.com/iQonAi/orca.git && cd orca && ./install.sh
```

Styles:

- **claude** — symlinks the agent, hook, watcher, and project data reader into
  `~/.claude/{agents,hooks,scripts}` and wires the SessionStart hook into
  `~/.claude/settings.json` (needs `jq`; prints the snippet to add by hand
  if `jq` is missing).
- **agents** — **experimental and untested**; for AGENTS.md-convention agents
  (Codex/Cursor/Gemini-class). It installs the watcher to
  `~/.local/bin/gh-watch`, the project data reader to
  `~/.local/bin/orca-project`, and the playbook to `~/.config/orca/AGENTS.md`. The
  SessionStart hook is Claude-specific and is skipped; launch the watcher
  yourself per the playbook. The install itself works (the files land; no
  hook is wired), but orca has never been run under any of those harnesses.
  The playbook depends on these Claude Code features, and each needs a
  working equivalent before this style can be considered supported:
  - subagents through the Agent tool (workers and reviewers);
  - a git worktree per worker;
  - `ScheduleWakeup`, which drives the poll loop;
  - background jobs whose exit re-invokes the session (the watcher's exit is
    what wakes orca);
  - the SessionStart hook that tells orca to launch the watcher
    (`hooks/orca-start-watcher.sh`).

Both styles also install the launcher, `bin/orca`, to `~/.local/bin/orca`
(`ORCA_BIN`); it is how a session is started (see [Usage](#usage)).

Environment overrides:

| Variable      | Default                | Meaning                                        |
| ------------- | ---------------------- | ---------------------------------------------- |
| `ORCA_STYLE`  | (prompt)               | `claude` or `agents`; skips the prompt. Required when there is no tty: without it the script exits 2 |
| `ORCA_REPO`   | `~/.local/share/orca`  | where the piped install clones the repo        |
| `ORCA_URL`    | `https://github.com/iQonAi/orca.git` | the repository the piped install clones from, and fetches from on re-run; set it to a fork or a mirror. `ORCA_REF` selects the ref within it |
| `ORCA_REF`    | `v0.1.0`               | the release tag the piped install checks out, and moves an existing clone to on re-run; `ORCA_REF=main` for development |
| `ORCA_MODE`   | `link`                 | `copy` to copy files instead of symlinking     |
| `CLAUDE_HOME` | `~/.claude`            | claude-style destination                       |
| `ORCA_BIN`    | `~/.local/bin`         | launcher destination (both styles), and agents-style watcher and project data reader destination |
| `ORCA_TOKEN_FILE` | `~/.config/orca/token` | (launcher) the bot's token file; `~/.config` follows `XDG_CONFIG_HOME` |
| `ORCA_GIT_NAME` | the bot's login      | (launcher) git author and committer name orca commits with |
| `ORCA_GIT_EMAIL` | `<id>+<login>@users.noreply.github.com` | (launcher) git author and committer email orca commits with |
| `LINEAR_API_KEY` | unset             | (watcher) a Linear personal API key; required when `.orca/project.json` names the `linear` tracker, unused otherwise |
| `GH_WATCH_CONFIRM_DELAY` | `5`         | (watcher) seconds between a poll that differs from the baseline and the fetch that has to differ from it too before the watcher exits. Anything that is not a positive integer is reported on stderr and replaced by the default |

Re-runs are idempotent. Anything replaced is backed up to
`~/.orca-backups/<timestamp>/`.

`~/.claude/scripts/` is the home for runtime helper scripts. Do not use
`~/.claude/jobs/` — Claude Code reserves it for background-job state.

### Bot identity

Orca runs as a GitHub account of its own, so every comment, branch and PR it
makes is the bot's, and a mention from you is unambiguously an instruction.
The launcher, `orca`, supplies that identity; your own `gh auth` session is
neither used nor changed. Setup, once:

1. Create the bot account on GitHub — an ordinary user account.
2. Give it **write** access on each repository orca will manage (repository
   Settings → Collaborators and teams).
3. Signed in as the bot, mint a **fine-grained personal access token** scoped
   to those repositories only, with these repository permissions: Contents
   read/write, Issues read/write, Pull requests read/write, Metadata read.
   Add Workflows read/write only if orca must edit files under
   `.github/workflows/`.
4. Store it where only you can read it — the launcher refuses a token file
   that is empty or whose mode is not `0600` or `0400`:

   ```sh
   mkdir -p ~/.config/orca
   (umask 077 && cat > ~/.config/orca/token)   # paste the token, Enter, Ctrl-D
   chmod 600 ~/.config/orca/token
   ```

   `ORCA_TOKEN_FILE` points the launcher at another file; `~/.config`
   follows `XDG_CONFIG_HOME`.
5. From a checkout of a managed repository, run `orca --check`. It prints
   one `ok:` or `fail:` line per check, names every failure in one run, and
   launches nothing; `running as <login>` is the account it found. Then
   start orca with `orca`.

What the launcher does once the checks pass: it exports the token as
`GH_TOKEN`, sets `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`
and `GIT_COMMITTER_EMAIL` to the bot (`ORCA_GIT_NAME` / `ORCA_GIT_EMAIL`
override; the defaults are the login and its
`<id>+<login>@users.noreply.github.com` address, which GitHub links to the
account), and execs `claude --agent orca`. `gh`, `git`, the watcher and every
worker inherit them; nothing else on the machine changes account. The token
file is yours: install, `--uninstall` and `--restore` never create, back up,
or remove it, and the launcher never prints it.

### Claude Code permissions

Bot identity, above, is the GitHub token's scopes. This section is a
different thing: Claude Code's own tool-use allowlist, the one that decides
whether orca can run a command without a permission prompt.

Orca's worker lifecycle needs these `gh` subcommand groups pre-approved in
`permissions.allow`, in `~/.claude/settings.json`:

```json
"Bash(gh pr *)",
"Bash(gh issue *)",
"Bash(gh api *)",
"Bash(gh repo view*)"
```

`gh repo view` is separate from the other three: orca and the watcher both
run it at startup to detect the repo from the current directory.

Orca cannot add these itself, even with your explicit go-ahead in chat.
Editing its own permission grants is a hard safety boundary, and it holds
regardless of conversational approval. Add them by hand.

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

- `~/.claude/{agents/orca.md,hooks/orca-start-watcher.sh,scripts/gh-watch.sh,scripts/orca-project.sh}`
- `~/.local/bin/gh-watch`, `~/.local/bin/orca-project` and
  `~/.config/orca/AGENTS.md` (plus
  `~/.config/orca` itself, if empty)
- `~/.local/bin/orca`, the launcher (both styles)
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

- **Your backups.** `~/.orca-backups/<timestamp>/` is never touched, and
  never restored from blind: there can be several runs, and only you know
  which one. Uninstall prints the path; putting a run back is a separate,
  explicit step (see [Restore](#restore)).
- **Everything else in `settings.json`.** Only entries equal to the one the
  installer wrote are dropped; other `SessionStart` entries, other hook
  types, and unrelated keys survive. An entry you merged the orca command
  *into* is not one the installer wrote, so it stays, with a note on stdout.
  Emptied `hooks.SessionStart` / `hooks` containers are pruned; the file
  itself is kept. (`jq` rewrites the file, so its indentation is normalized —
  the same thing install does when it wires the hook.)
- **Directories that are not orca's** — `~/.claude/*` and `~/.local/bin` stay
  whatever else they hold.
- **The bot's token.** `~/.config/orca/token` — and the launcher's
  `sessions/` records beside it — are never created, backed up, or removed
  by install, uninstall, or restore. `~/.config/orca` is only ever removed
  when it is empty.
- **The checkout at `~/.local/share/orca`.** Delete it yourself if you want
  it gone.

Without `jq` it changes no JSON: it prints the exact entry to delete from
`settings.json` by hand, mirroring what install does. With `$HOME` unset or
empty it refuses outright rather than building paths under `/`.

#### Restore

Each run directory holds a `MANIFEST`: one line per file it moved aside — the
backup name (`01-orca.md`, `02-settings.json`, …), a tab, and the absolute
path it came from. `--restore` reads it:

```sh
./install.sh --restore              # list the runs and what each one holds
./install.sh --restore <timestamp>  # put that run back
```

Or piped, like `--uninstall`: `curl -fsSL … | sh -s -- --restore <timestamp>`.

It copies each file back only if nothing is at its original path; anything
already there is printed as `skipped: exists` and never overwritten, so run
`--uninstall` first. The backup copies stay where they are. Two things it
never does:

- **Restore `settings.json`.** The backup is the entire pre-install file, so
  copying it back would revert every setting changed since. `--uninstall`
  already removes the hook entry surgically; anything else in that copy is a
  manual merge, and `--restore` prints its path and leaves it to you.
- **Guess.** An unknown run exits non-zero and changes nothing, and a run
  made before the manifest existed is listed as `no manifest: restore by
  hand`.

Like `--uninstall`, it never clones, fetches, or re-executes anything, and it
honours the same `$HOME` guard.

## Usage

From the project you want orca to manage:

```sh
orca
```

The launcher runs its preflight checks first and refuses to start if any
fails, naming every failure in one run:

1. `gh`, `git`, `jq` and `claude` on `PATH`;
2. the token file exists, is not empty and is mode `0600` or `0400`, and
   `gh api user` accepts it (`running as <login>`);
3. the repository, detected from the checkout's `origin` remote
   (`--repo owner/repo` overrides), and the bot's permission on it — write,
   maintain or admin;
4. the installed files — the playbook, the hook, the watcher and the
   project data reader — resolve to real files (a dangling symlink is named
   with its target) and, claude style, the `SessionStart` hook is wired in
   `settings.json`;
5. no other orca holds this repository
   (`~/.config/orca/sessions/<repo-slug>` records the running one's pid; a
   record left by a dead session never blocks).

`orca --check` runs the same checks and exits without launching. Anything
else on the command line is passed through to `claude`.

On session start the hook injects the watcher directive; orca launches
`gh-watch.sh <owner>/<repo>` as a background job and begins its cycle:
assess open issues, plan, dispatch, review, merge, digest. The first digest
names the account it runs as.

Orca reads the tracker, GitHub or Linear, from the project data file; see
[Project data](#project-data). When a session starts without the file,
orca asks you for the values, runs `orca init` with your answers, and takes
the init PR through review to merge like any other PR. In either tracker,
work is modelled as epics and tasks:

- An **epic** is an issue with the `epic` label, on GitHub and on Linear. An
  issue that already has sub-issues is treated the same way. Orca never
  dispatches the epic itself.
- Orca splits an epic only when it carries a dispatch signal. It then comments a plan on the epic, creates each task as a
  sub-issue and adds `ready-for-agent` to each one. An epic without that
  signal is left as it is.
- A **task** is a sub-issue. Orca dispatches each task to a worker, which
  opens one PR for it. Code, branches and PRs stay on GitHub with both
  trackers.
- An issue without the `epic` label and without sub-issues is a task on its
  own, so a single issue works as before.
- A task labelled `HITL` (human in the loop) is dispatched as usual, but
  orca never merges its PR. It asks you before any step that changes
  direction and lists the PR in the digest as waiting for a human. Orca adds
  `HITL` itself when it splits an epic and a task needs a human, or when the
  epic or the task says so.
- An issue labelled `no-agent` is never dispatched, on GitHub or Linear,
  even when it is assigned to orca or labelled `ready-for-agent`.
- When every task is closed, orca closes the epic and reports it under
  Landed. The digest groups running and queued tasks under their epic.

On Linear, orca uses the Linear MCP tools and takes the priority from
Linear's priority field. At startup it reads the Linear account it acts as
and names it in the first digest (`linear as <name>`). A `ready-for-agent`
label, or assignment to that account, is the signal, whoever created the
issue. Assignment counts only when the account is a dedicated bot user. A
comment that mentions orca is an instruction only when a member of the
Linear team named in `.orca/project.json` wrote it; see
[Issue and PR comments are an instruction channel](#issue-and-pr-comments-are-an-instruction-channel).
The watcher polls the team's open Linear issues beside GitHub, so a change
on Linear wakes orca the same way; see [Linear polling](#linear-polling).
Orca then reads the recently updated Linear issues and their comments.

Signals orca reacts to on GitHub:

- An issue **assigned to the bot handle** is dispatchable agent work.
- Any **@bot-handle mention** in an issue or PR comment is a message to orca —
  unless the number is one orca currently owns, which it does not wake for; see
  [The ignore set](#the-ignore-set).

The bot handle is the login orca runs as. Orca's own comments are never
signals, and it acts on an instruction only when its author has write access
or better on the repository; anything else is surfaced in the digest. A
project `CLAUDE.md` may still name the handle for the assignment convention;
that value is the fallback for a session started without the launcher.

### Project data

`.orca/project.json`, at the root of the project's repository, tells orca
where the project's work is tracked. Commit it with the project. It holds
names only, never a token or any other secret:

```json
{ "version": 1, "name": "Devbox", "tracker": "linear",
  "github": { "repo": "iQonAi/devbox-control-plane" },
  "linear": { "team": "IQONAI", "project": "Devbox" } }
```

| Field            | Required                        | Value |
| ---------------- | ------------------------------- | ----- |
| `version`        | yes                             | `1` |
| `name`           | yes                             | the project's display name |
| `tracker`        | yes                             | `github` or `linear` |
| `github.repo`    | yes, with either tracker        | `owner/repo`; code and PRs live on GitHub either way |
| `linear.team`    | when `tracker` is `linear`      | the Linear team |
| `linear.project` | no                              | the Linear project |

Without the file, orca uses GitHub issues: `tracker` is `github`,
`github.repo` comes from the `origin` remote, and `name` is the repository
part of it. The `linear` fields are not set.

`scripts/orca-project.sh <field>` reads one field and prints it, for
example `orca-project.sh tracker` or `orca-project.sh linear.team`. It finds
the file at the git root of the current directory and checks the whole file
on every read. A malformed file, an unknown tracker, or a missing required
field exits 1 with the reason on stderr; a broken file is never read as a
missing one. An absent `linear.project` prints an empty line.

To write the file, run this from the project:

```sh
orca init
```

It first fetches the default branch from `origin`. It refuses to run when
`.orca/project.json` already exists in your working tree, in `HEAD` or on
`origin`'s default branch, or when the branch `chore/orca-init` exists
locally or on `origin`. All of these checks run before the first question.
It proposes each value from the `origin` remote; press enter to keep a
proposal or type a new value. The reader checks the answers before anything
is written. Then `orca init` commits the file on the new branch
`chore/orca-init`, branched from `origin`'s default branch in a worktree of
its own, pushes the branch to `origin`, and opens a PR against the default
branch with `gh pr create`. Commits on the branch you have checked out are
never pushed or put in the PR, even when you run it from a feature branch.
That branch and your working tree do not change, so the file reaches the
default branch only through the PR. The push and the PR use your own `git`
and `gh` credentials, not the bot's token.

Orca also runs `orca init` itself when a session starts without the file.
It asks you for each value first and feeds your answers to `orca init` on
stdin. It then handles the init PR like any other PR: review, approval,
merge, teardown. Inside the orca session, `gh` uses the bot's token that
the launcher exported, so that PR is opened as the bot.

### gh-watch.sh exit codes

| Exit | Meaning                                                                     |
| ---- | --------------------------------------------------------------------------- |
| 0    | Change detected, ~55min quiet expiry, or stopped by a signal — restart it. In `--status` mode: no watcher holds this repo. In `--ignore` mode: the set was written. |
| 1    | Could not start (no repo, unusable state dir, baseline fetch failed, `.orca/project.json` rejected by the reader, Linear tracker without `LINEAR_API_KEY`), or `--ignore` was given something that is not a list of numbers and Linear identifiers — fix the cause. |
| 3    | A watcher already holds this repo. In `--status` mode its pid is printed. `--takeover` replaces an incumbent that is not yours. |

### The ignore set

Orca's own workers push commits, open PRs and post review comments all through
a dispatch cycle, and every one of those is a change the watcher exits on — so
orca is re-invoked to be told about work it just did itself.
`gh-watch.sh --ignore "20 45" <owner>/<repo>` records the numbers orca
currently owns: it writes them beside the pidfile and exits 0 without launching
anything, and a change confined to those numbers is no longer a wake-up. Issue
and PR numbers are one namespace, because an owner owns an issue and its PR
together. On a Linear project, Linear identifiers go in the same set:
`--ignore "53 54 IQONAI-28"`. `--ignore ""` clears the set, and `--status`
reports it.

The set is re-read on **every poll**, so it moves without restarting the
watcher — which matters, because a restart is itself the re-invocation the
feature removes. A number can be released in the same 30s gap in which it
changed (merge, then release): the poll that sees both filters with the union
of the previous and the current set, and keeps the raw snapshot as its next
baseline, so the merge does not fire and the number is compared normally from
the next poll on.

The blind spot is deliberate and worth knowing: an external comment, an
`@bot-handle` mention or an `on-hold` label on an ignored number does not wake
the watcher either. Nothing in the snapshot can tell those from orca's own
work, since both act as the same login. Orca compensates with its own poll
cadence — 60s while comments are flowing — and re-reads its own PRs before
it turns on auto-merge. While a PR waits for a human, orca takes the PR and
its issue out of the ignore set, so the approval, the merge and any `on-hold`
label wake it.

## Safety and blast radius

Orca is an autonomous agent holding the bot's GitHub token, with write access
to your repo and a shell on your machine. Read this before pointing it at
anything.

### Issue and PR comments are an instruction channel

`agents/orca.md` defines two signals: an issue **assigned to the bot handle**
is dispatchable work, and **any `@bot-handle` mention** in an issue or PR
comment is "a message TO this orchestrator session; read it and dispatch/act
accordingly" (`agents/orca.md:163-170`).

The playbook tells orca to ignore its own comments and to act only on
instructions from accounts with write access or better, surfacing the rest in
the digest (`agents/orca.md:171-178`). That is a prompt instruction, not
enforced code: no script in this repo checks the author, so treat it as a
mitigation, not a boundary. On a public repo, every drive-by commenter is
still addressing an agent that can run commands on your machine and merge to
`main` — an unauthenticated prompt-injection channel.

**Run orca on private repos only.** That shrinks the audience to people you
have granted some access — but be precise about who that is: **read access is
enough to comment on an issue or PR.** A private repo shared read-only with a
contractor, an outside collaborator, or a broad org team still has this channel
wide open. The trust boundary is everyone with read access or better, not just
the people who can write or merge.

On a public repo the audience is everyone, and you are the allow-list: read
every incoming comment yourself.

On a Linear project the trust boundary is different, and wider. Linear has
no repository permission check. The dispatch boundary is anyone who can
label or assign an issue: any issue labelled `ready-for-agent` or assigned
to orca's Linear user is dispatched, whoever created it, integrations
included. The opt-out is the `no-agent` label, which stops dispatch on any
issue. Comments are narrower: orca acts on a mention only when a member of
the Linear team named in `.orca/project.json` wrote it, whether or not they
have access to the repository. A mention from anyone else is surfaced in
the digest and not acted on. Orca should act as a dedicated bot Linear
user. If it finds a human account instead, it says so in the digest and
ignores assignments, because every issue that person assigns to themselves
would otherwise look like work for orca.

### What orca can do

On your machine:

- Runs `gh-watch.sh` as a long-lived background job polling GitHub every 30s,
  and Linear too on a Linear project (`scripts/gh-watch.sh`).
- Creates git worktrees and branches under `.claude/worktrees/`, and writes
  scratch state under `.claude/scratch/` (`agents/orca.md:274-279`).
- Dispatches subagent workers that edit files and run the project's
  `build | lint | typecheck | test` commands (`agents/orca.md:283-284`).
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
- Both styles install the launcher to `~/.local/bin/orca`. It reads
  `~/.config/orca/token` and nothing else there. On launch it creates
  `~/.config/orca/sessions/` if it is absent and writes one file in it,
  `<repo-slug>`, holding the pid of the running orca; it removes that file
  when that orca exits, and the directory stays.

On your repo: comments on issues, sets labels, pushes branches, opens PRs,
posts and resolves review threads, requests reviewers, and merges its own PRs.

The agent frontmatter in `agents/orca.md` sets only `name`, `description`, and
`model`. It declares no tool restriction, so orca and its workers run with
whatever tool permissions your Claude Code session already grants.

### GitHub token scopes

`install.sh` never invokes `gh` — it neither checks nor requests scopes. Orca
does not use your `gh auth` session at all: the launcher exports the bot's own
token from `~/.config/orca/token` as `GH_TOKEN`, and everything orca runs —
`gh`, `git`, the watcher, the workers — acts as the bot, with the least
privilege that token carries (see [Bot identity](#bot-identity)). Your own
session is untouched, and revoking the bot's token stops orca without
touching anything else. Before anything starts, the launcher confirms the
token authenticates and that the bot has write access on the repository.

These are the operations orca performs over a full issue-to-merge run. Only the
rows that name a script are executable `gh` calls in this repo; every other row
is a step the playbook instructs the model to take, so the "Where" column points
at prose, not at code that enforces it.

| Operation                                                        | Where                                                            | Needs                    |
| ---------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------ |
| Verify the token and read the bot's login and id                 | `bin/orca` — `gh api user`                                       | read user profile        |
| Read the bot's permission on the repository                      | `bin/orca` — `gh api repos/<repo>/collaborators/<login>/permission` | read repo metadata    |
| Poll open issues and PRs every 30s — number, `updatedAt`, labels only | `scripts/gh-watch.sh:567` — `gh issue list`, `gh pr list`    | read issues and PRs      |
| Resolve `<owner>/<repo>` from the cwd                            | `scripts/gh-watch.sh:123` — `gh repo view`, when no repo is given; `agents/orca.md:52` reads it with `orca-project.sh github.repo`, which makes no API call | read repo metadata       |
| Read issue assignees and recent comments each cycle              | `agents/orca.md:166-167`                                           | read issues              |
| Comment the plan on an issue; set priority and workflow labels   | `agents/orca.md:270-273`                                         | write issues             |
| Push the worker branch                                           | `agents/orca.md:285`                                             | write repo contents      |
| Open the PR, post review comments, reply to and resolve threads  | `agents/orca.md:285`, `agents/orca.md:295-299`                   | write pull requests      |
| Request an external reviewer                                     | `agents/orca.md:291` — `gh api -X POST .../requested_reviewers`  | write pull requests      |
| Turn on auto-merge for the PR, or turn it off                    | `agents/orca.md:303`, `agents/orca.md:314`                       | write contents and PRs   |

Net, for the bot's fine-grained token: Metadata: read, Issues: read/write,
Contents: read/write, Pull requests: read/write — plus Workflows: write if a
worker ever changes a file under `.github/workflows/` — scoped to the repos
you want orca to manage, and no others. (A classic token would need `repo`,
whose private-repo access covers all of the above, plus `workflow` for that
same case; prefer the fine-grained one.)

Three properties of the 30s poll are worth knowing, since it is the one piece of
this that really is code. Each poll runs `gh issue list` and `gh pr list`, both
`--limit 50`, so only the 50 most recent open items of each kind are watched; on
a busier repo, changes below that cut-off are missed. The two listings are
separate calls because `gh issue list` excludes pull requests, and their results
are concatenated and sorted, so listing order alone never looks like a change.
And a listing that succeeds holding no items is taken at face value: a repo with
nothing open yet is watched normally, and only a listing that FAILS makes the
snapshot inconclusive.

These are the CLI's GraphQL-backed listings rather than the REST
`repos/<repo>/issues` endpoint, which is what the watcher used to poll. That
endpoint served inconsistent empty responses for minutes at a time — answering
`[]` while `gh pr list` returned the PR that was open — and every one of them
looked to the watcher like every issue closing at once
([#32](https://github.com/iQonAi/orca/issues/32)).

A poll that differs from the baseline costs one extra pair of requests: the
watcher re-fetches after `GH_WATCH_CONFIRM_DELAY` seconds and exits only if that
answer differs from the baseline as well.

The watcher makes roughly 240 requests per hour per repo (two per poll, one poll
every 30s), counting against the bot token's GraphQL rate limit.

### Linear polling

The watcher reads the tracker from `.orca/project.json` in its working
directory, through `orca-project.sh`; its command line is the same for both
trackers. Without the file, or with `tracker` set to `github`, it polls
GitHub only. With `linear`, each poll also queries
`https://api.linear.app/graphql` for the open issues of `linear.team`, and of
`linear.project` when it is set. Open means any state except completed and
canceled. Each issue gives one row beside the GitHub rows:

```
IQONAI-28 In_Progress|alice|9c1e2f4a-0b7d-4c55-a2e1-3f6d8b9a1c00|2026-11-16T10:00:00.000Z bug,p1
```

That is the identifier, then the status, the assignee, and the id and
`updatedAt` of the newest comment (`-` for none, whitespace as `_`), then the
labels. The query asks for the newest comment explicitly, so a new or edited
comment changes the row however many comments the issue has. The rows join
one snapshot, so the confirm, the ignore set and the ~55min expiry work on
them as on GitHub rows.

The query reads every open issue. It pages through the results 50 at a time,
ordered by creation, up to 20 pages (1,000 issues), and at most 50 labels per
issue. A team with more open issues than that fails the fetch; the watcher
never watches a silently shorter list.

A failed Linear fetch on the baseline exits 1, as a failed GitHub listing
does. After the baseline, a failed Linear fetch keeps the last good Linear
rows and still compares the GitHub rows, so a revoked key or a rate limit
does not hide GitHub changes. The watcher prints one line on stderr when the
Linear failures start and one when they recover.

Linear mode needs a Linear personal API key in `LINEAR_API_KEY`; without it
the watcher exits 1. curl reads the `Authorization` header on stdin, so the
key never shows in the process list, on disk or in the watcher's output.
`gh-watch.sh --status` prints `linear: <team>[/<project>]` when the live
watcher polls Linear. Linear mode adds about 120 requests per hour per page
of open issues against the key's Linear rate limit.

### What gates a merge

The worker lifecycle in `agents/orca.md:289-321` specifies:

1. An internal review agent is spawned for every PR, checking issue completion,
   security, maintainability, and bugs. Its findings are posted as PR review
   comments, so they become resolvable threads.
2. If the project's `CLAUDE.md` names an external reviewer, that reviewer is
   requested in parallel.
3. Orca waits for the internal review and every requested external review.
4. Every thread must be addressed — fixed, then replied to with the fix and its
   commit hash; or replied to with a justification. Silent resolution is
   forbidden.
5. Orca merges through GitHub auto-merge, because branch protection needs a
   human approval and orca cannot approve its own PR. Once CI passes, every
   thread is resolved **and none is critical**, orca runs
   `gh pr merge <n> --auto --squash` and asks you to review. GitHub merges
   the PR when you approve. If the PR is already mergeable, `gh` merges it
   at once. Before orca pushes to the PR, or when a new review thread
   appears, orca turns auto-merge off. It turns it on again only after every
   gate passes again. The repo needs "Allow auto-merge" turned on. If the
   `gh` command fails for any reason, orca reports the error under Blocked,
   and you approve and merge the PR yourself.
6. **`on-hold` gate:** an `on-hold` label on the PR or its issue blocks
   auto-merge and dispatch until the label is removed or a bot-handle comment
   signs off. If auto-merge is already on, orca turns it off with
   `gh pr merge <n> --disable-auto`.
7. On issues, a `needs-info` label means wait; `ready-for-agent` means dispatch
   without asking (`agents/orca.md:270-273`).
8. **`HITL` gate:** orca never turns on auto-merge for the PR of a task
   labelled `HITL`. The human merges it, and orca lists the PR in the digest
   as waiting for a human (`agents/orca.md:320-321`).

**These gates are prompt instructions, not enforced code.** The executable
files in this repo are the watcher, the SessionStart hook, the installer, and
the test suite — none of them observe or block a merge. The gates hold exactly
as well as the model follows its playbook.

### Not verified, not implemented

- **Branch protection is unverified.** Nothing in this repo reads, respects, or
  handles branch protection rules. Orca merges with ordinary `gh` calls, so
  GitHub's own enforcement applies to it as to any other client — but that has
  not been tested here. The playbook assumes a rule that needs a human
  approval and merges through auto-merge for that reason
  (`agents/orca.md:300-321`). The playbook does say never to commit or merge local `main`
  (`agents/orca.md:285-286`); work always goes through a branch and a PR.
- **There is no dry-run or approval mode.** No flag, environment variable, or
  setting in this repo makes orca plan without acting, or ask before it
  comments, pushes, or merges. Once running, it acts on its own.
- **Token cost per cycle is unmeasured.** Every watcher exit re-invokes the
  model, and the poll cadence adapts between 60s and ~1800s depending on
  activity (`agents/orca.md:187-190`), so cost scales with how busy the repo is.
  No measured figure is available; tracked in
  [#23](https://github.com/iQonAi/orca/issues/23).
- **The `agents` install style is untested.** Orca has never been run under a
  Codex, Cursor, or Gemini-class harness; the Claude Code features it would
  need are listed under [Install](#install).

## Tests

```sh
bash test/run.sh
```

The suite is hermetic: a stub `gh` (a stub `curl` for the Linear API, and a
stub `claude` for the launcher) replaces the network, temp HOMEs stand in for `~`, and `GH_WATCH_STATE_DIR`
redirects pidfiles to a temp dir, so a real watcher on the machine is neither
seen nor disturbed.

The shell scripts are formatted with `shfmt` v3.14.0 (`shfmt -i 2 -ci`), and
CI fails on any diff from that style.

## License

MIT — see [LICENSE](LICENSE).
