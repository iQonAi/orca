# Security policy

## Reporting a vulnerability

Use GitHub private vulnerability reporting:
[Report a vulnerability](https://github.com/iQonAi/orca/security/advisories/new),
under the [Security tab](https://github.com/iQonAi/orca/security) of this
repository. Do not file a public issue or pull request first; a public report
reaches every reader before a fix exists.

Include:

- The version: the `installed orca <version>` line that `install.sh` prints.
  It is a tag such as `v0.1.0`, or a short commit hash for a `main` checkout.
- The install style: `claude` or `agents`.
- A reproduction: the issue, comment, or input that triggers the problem, and
  what orca did with it.

Reports are answered on the advisory thread. No response time is promised.

## Threat model

Orca is an autonomous agent. It holds a live `gh` token, has write access to
the repository it manages, and runs a shell on the machine that hosts it. The
README section [Safety and blast radius](README.md#safety-and-blast-radius)
holds the detail. In short:

- **Orca acts as the maintainer who runs it.** It uses that account's token
  and repository write access. What it does on the machine and on the
  repository is listed under [What orca can do](README.md#what-orca-can-do);
  the operations it performs, and the token scopes they need, are under
  [GitHub token scopes](README.md#github-token-scopes). Orca uses whatever
  scopes your `gh auth` session already has.
- **Issue and PR comments are an instruction channel.** Orca treats any
  `@bot-handle` mention as an instruction to itself, and nothing checks who
  wrote it. Everyone who can comment is inside the trust boundary, and read
  access is enough to comment. On a public repository that is anyone with a
  GitHub account. Run orca on private repositories only. See
  [Issue and PR comments are an instruction channel](README.md#issue-and-pr-comments-are-an-instruction-channel).
- **The executable files in this repository are four scripts:** the watcher
  (`scripts/gh-watch.sh`), the SessionStart hook
  (`hooks/orca-start-watcher.sh`), the installer (`install.sh`), and the test
  suite (`test/run.sh`). The installer wires only the first two into your
  session. The playbook `agents/orca.md` is prose that the model follows. See
  [What gates a merge](README.md#what-gates-a-merge) and
  [What orca can do](README.md#what-orca-can-do).
- **Merge gates are prompt instructions, not enforced code.** Review, thread
  resolution, and the `on-hold` label hold only as well as the model follows
  its playbook. See [What gates a merge](README.md#what-gates-a-merge) and
  [Not verified, not implemented](README.md#not-verified-not-implemented).

## Supported versions

| Version  | Supported | Notes          |
| -------- | --------- | -------------- |
| `v0.1.0` | Yes       | Latest release |
| `main`   | No        | Development    |

Fixes go to the latest tagged release only. The piped installer checks out
that release by default; `ORCA_REF` selects another ref (see
[Install](README.md#install)).
