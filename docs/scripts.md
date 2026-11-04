# Scripts

The panel does its work through the shell scripts in [`scripts/`](../scripts); they call the `claude` (and, for Codex roles, `codex`) command-line tools and `jq`. This page lists what they do, what they check and what they write. How the screens use them is in [Using Tentacl Crew](guide.md).

- [What is in `scripts/`](#what-is-in-scripts)
- [Settings](#settings)
- [project.json](#projectjson)
- [Starting agents](#starting-agents)
- [Claude Code's trust question](#claude-codes-trust-question)
- [Review, approve and fix](#review-approve-and-fix)
- [Roles and agent settings](#roles-and-agent-settings)
- [The team chart](#the-team-chart)
- [Parallel work](#parallel-work)
- [Requests from the PM](#requests-from-the-pm)
- [create-project.sh](#create-projectsh)

## What is in `scripts/`
Config validation (`validate-config.sh`), conflict check (`check-conflicts.sh`), agent spawn/stop (`spawn-agent.sh`, `stop-agent.sh`), PM start and approve requests (`request-start.sh`, `request-approve.sh`), answering an agent (`answer-question.sh`), wait for an agent (`wait-agent.sh`), simulator isolation (`sim-for-agent.sh`), review packet (`review-packet.sh`: builds and screenshots, or report-only for `kind: analysis` tasks), merge (`merge-task.sh`), folder trust (`trust-folder.sh`), new projects (`create-project.sh`), the public snapshot (`prepare-public.sh`, see [Releasing](releasing.md)), and the build, test and release helpers described in [Building from source](building.md), [Contributing](../CONTRIBUTING.md) and [Releasing](releasing.md).

## Settings
Add the scripts folder to `~/.config/tentacl/projects.json` and, in each `project.json`, the role file used for developer agents:

```json
{ "projects": ["/abs/project.json"], "scriptsDir": "/abs/path/to/agent-panel/scripts" }
```
```json
{ "...": "...", "roles": { "dev": "/abs/path/to/roles/dev.json" } }
```
Without `scriptsDir` the panel stays read-only. (Roles can also live in the shared and per-project role folders, see [Roles and agent settings](#roles-and-agent-settings).)

## project.json
Only `id`, `name`, `repoPath`, `dataDir`, `maxParallel` and `sharedFiles` are required; each of these is optional and turns a capability on:
- `buildCommand`: when set, a review packet runs it in the agent's worktree (`$UDID` is replaced when the project has a simulator). Without it the packet says "Build: none" and Approve does not ask for a build.
- `testCommand` (optional): the command that runs the project's tests. The PM may run it (and the build) while it writes the project summary.
- `simulator` (`{"baseDevice": "iPhone 17 Pro"}`): when set, every agent gets a simulator of its own. Without it none is created and none is mentioned to the agent.
- `xcodeProject`, `openWith`: "Open in Xcode" and the opener. Both are left out for projects that have no Xcode.
- `copyFiles` (list of relative paths): untracked local files (signing settings, `.env`) that `spawn-agent.sh` copies from the repository into every new worktree. Absolute paths, `..` and `.git` are refused by `validate-config.sh`.
- `screenshots` (true/false): whether a review takes a screenshot. A project without the key keeps the old behaviour (screenshot required, so existing projects work as before); new projects are written with `false`. No project needs screenshots to be approved unless it says so.

Examples: [`project.example.json`](../examples/project.example.json), [`project.minimal.example.json`](../examples/project.minimal.example.json). Check a file with `scripts/validate-config.sh /path/to/project.json`.

## Starting agents
*Start agent* runs `spawn-agent.sh`, hands the agent its card and marks the card `doing`. If any step fails, the agent, its worktree, simulator and fresh branch are removed again.

`spawn-agent.sh` gives every agent `--add-dir` for the attachments folder (`~/Library/Application Support/Tentacl/attachments`; override with `AGENT_PANEL_ATTACHMENTS`), so reading an image you attached never stops at a permission prompt. It keeps `.agent-worktrees/` out of git with the local `.git/info/exclude`.

**What the panel writes:** the `status`, `agent`, `branch` and `from` lines of the card's front matter (atomically, and not if the card changed since it was read), the cards you create or edit with *New task* / *Edit*, plus a one-line-per-action record in `~/Library/Application Support/Tentacl/actions.log`. Card values are treated as untrusted: the task id and branch name must be plain ASCII names before they reach any script.

## Claude Code's trust question
An agent started in a folder Claude Code does not trust yet stops at "Do you trust the files in this folder?" and never gets its task (the start then fails with "blocked during startup"). The start sheet shows a *Trust* line when the project's folder is not in Claude's trust list; confirming the start runs `scripts/trust-folder.sh`, which sets `hasTrustDialogAccepted` for that folder in `~/.claude.json` (everything else is kept, the old file is saved as `~/.claude.json.tentacl-backup`, and a file that is not valid JSON is never touched).

## Review, approve and fix
**`review-packet.sh`** builds the app on the agent's own simulator, takes a screenshot and summarises the diff. The packet also records the branch tip it was built from (`Head:`). The packet is built from one fixed commit: the worktree must be clean before the build, whatever the build rewrites in tracked files is undone, and the packet is refused if the branch moved during the build.

**`merge-task.sh`** merges fast-forward only (`git merge --ff-only`) into `mainBranch` from `project.json` (default `main`), so small commits stay in the history. Your own files are protected, including git-ignored ones. Everything that could lose work is checked first and refuses without changing anything:

| `merge-task.sh` exit | Meaning |
| --- | --- |
| 0 | merged (or the branch had no commits of its own) |
| 2 | usage error or a branch name that is not a plain name |
| 3 | the repository is not on the main branch |
| 4 | not a fast-forward: the main branch has newer commits (ask the agent to rebase) |
| 5 | your unsaved changes in the repository touch files the branch changes (the files are listed) |
| 6 | unsaved work in the agent's worktree (closing it would delete that work) |
| 7 | the branch tip is not the one you reviewed (the agent committed after the packet) |
| 8 | git itself refused the merge (its message is shown) |

The merge itself cannot be undone by the panel. If a step after it fails (the card cannot be written, the agent cannot be closed) the panel says what is done and what to do by hand. A task that is `doing`, `needs-fix` or `review` counts against the project's `maxParallel`, because its agent still holds a worktree and a simulator.

Besides the front matter lines and the cards you write in *New task* / *Edit*, the panel writes only the `## Fix notes` (appended) and `## Decision` sections of a card.

## Roles and agent settings
- **Where roles live.** Shared roles: `~/.config/tentacl/roles/<name>.json` with `<name>.md` (instructions) next to it; on the first launch (when that folder does not exist) `pm` (Opus), `dev` (Sonnet) and `reviewer` (Opus) are created. A project's own roles: the `roles/` folder next to its `project.json`. A role there with the same name replaces the shared one in that project. Roles named in `project.json` under `"roles"` still work and are shown read-only. Lookup order: the `roles` entry, the project's folder, the shared folder. Examples: [`examples/roles/`](../examples/roles).
- **Tool.** A role runs on `claude` or `codex` (`"tool"` in the role file; `validate-config.sh` refuses anything else). The PM runs on Claude Code.
- **`env`** is rejected by `validate-config.sh` (and in the form): do not put secrets in role files, define them in your terminal.
- **Preview.** *What will be started* on the Team screen runs the real `spawn-agent.sh --print-flags` on a temporary copy of the draft, so it shows exactly what a start uses. It also lists which of your other Claude settings (permissions, hooks, MCP servers) still apply, by name and count only, never by value.
- **Safety.** The panel writes only to the shared roles folder and a project's `roles/` folder, only plain role names, never through a symbolic link, and never to `project.json` or cards for roles.

## The team chart
`team.json` next to a project's `project.json` (example: [`examples/team.example.json`](../examples/team.example.json)):

```json
{"version": 1, "members": [{"role": "pm", "reportsTo": null}, {"role": "reviewer", "reportsTo": "pm"}]}
```
`null` means the role reports to you. A role may give tasks only to the roles below it (see [Templates and the team chart](guide.md#templates-and-the-team-chart)).
- **Instructions.** With a chart, `spawn-agent.sh` adds a *Your place in the team* section to the agent's instructions (who it reports to, who it may give tasks to, who it may not) and the *What will be started* preview shows it. Without a chart nothing is added or checked.
- **A broken `team.json`** (bad JSON, a cycle, a role twice, an unknown manager) stops starts in that project and is shown on the Chart tab; it is never silently ignored. A role without a role file is only a warning.

## Parallel work
Two tasks that touch the same file (a listed directory covers every file in it) are not started side by side (`check-conflicts.sh`). Analysis tasks (`kind: analysis`) only read, so they never conflict with any task, and they need no `files:` list.

## Requests from the PM
- **`request-start.sh <data folder> "<your words>" N18 N19`** writes `<data folder>/.tentacl/start-requests/<id>.json` (`requestedBy: pm`, your words, the card ids; at most 8). The panel reads it, deletes it and checks every card with its normal start rules.
- **`request-approve.sh <data folder> "<your words>" N18 N19`** writes `<data folder>/.tentacl/approve-requests/<id>.json` the same way.
- With **PM authority** on, both work with an empty string for the words: the PM runs `request-start.sh <data folder> "" <card id>` (same for `request-approve.sh`).

What the panel then does with a request in each autopilot mode is in [PM autopilot](guide.md#pm-autopilot).

### Session key
The authority works only for requests that carry a secret key that only the PM got. The panel makes a random 256-bit key per PM session (pane) and keeps it in memory only, never on disk; a PM the app starts gets the key in its environment as `TENTACL_PM_KEY` (a restart makes a new one; task agents never get it), so nothing appears in the chat. Only a PM pane started before this existed gets it once in a `Panel:` message (when the authority is on and the PM is idle; again if it wrote a request without a key). `request-start.sh`, `request-approve.sh` and `answer-question.sh` read `$TENTACL_PM_KEY` when `--key <key>` is left out. The PM must never write the key into a file, a card or a message to another agent. The request file holds the key until the panel has read it, so keep it out of anything else.

## create-project.sh
Makes the repository (`git init -b main`, `.gitignore`, `README.md`, first commit), the data folder (`tasks/`, `agent-panel/project.json`, a default `team.json` from the shared roles you have) and checks the result with `validate-config.sh`. It never overwrites an existing folder, and if a step fails it removes only what that run made.
