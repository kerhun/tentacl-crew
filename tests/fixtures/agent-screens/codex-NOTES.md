# Codex screens (N150)

Captured 2026-10-19 from the agent's terminal screen, Codex 0.163.0 unless the name says `-0.147`.
`.ansi` = same screen with `--format ansi`. Status = the agent state at capture time.

| file | screen | keys | status |
|---|---|---|---|
| codex-idle | `› Ask Codex to do anything`, footer `GPT-5.6-Luna low · <cwd>`, `? for shortcuts` | — | done/idle |
| codex-working | `• Working (1s • esc to interrupt)`, spinner at footer end | Esc interrupts | working |
| codex-done | `• Ran …` output, `Worked for 6s • 22:13`, empty composer | — | done |
| codex-approval-command | `Would you like to run the following command?` `Reason:` `$ <cmd>` `› 1. Yes, proceed (y)` `2. Yes, and don't ask again for commands that start with \`touch\` (p)` `3. No, and tell Codex what to do differently (esc)` | y / p / Esc, digits + Enter | blocked |
| codex-approval-command-after | `✔ You approved codex to run … this time` | — | still `blocked` for a few s, then done |
| codex-approval-edit | `• Edited notes.txt (+1 -0)` diff (drawn before approval!) + `Would you like to make the following edits?` `Destination:` `› 1. Yes, proceed (y)` `2. Yes, and don't ask again for these files (a)` `3. No, … (esc)` | y / a / Esc | blocked |
| codex-approval-edit-after-esc | `■ Conversation interrupted - use /feedback if something went wrong`; file not changed | — | done |
| codex-question | plain text question `• Which color do you prefer: red or blue?` then `Worked for 2s` | answer with a normal prompt | done |
| codex-question-menu | `/plan` mode `request_user_input`: `Question 1/1 (1 unanswered)`, `› 1. hi … 3. None of the above`, `tab to add notes \| enter to submit answer \| esc to interrupt` | digit submits at once (one question); Tab notes; Esc | blocked |
| codex-question-menu-after-2 | `Proposed Plan`, working | — | working |
| codex-plan-approval | `Implement this plan?` `› 1. Yes, implement this plan` `2. Yes, clear context and implement` `3. No, stay in Plan mode` `enter select · esc back` | digit, Enter, Esc | **done** (not blocked) |
| codex-readonly-refusal | `-s read-only -a never`, `touch` fails: only `Worked for 5s`, no text (error only in the rollout) | — | done |
| codex-hooks-review | startup: `Hooks need review` `› 1. Review hooks 2. Trust all and continue 3. Continue without trusting (hooks won't run)` `enter confirm · esc skip` | digit (3 = no write) | unknown; `agent start` times out |
| codex-trust-0.147 | startup: `Do you trust the contents of this directory?` `› 1. Yes, continue 2. No, quit` | digit acts at once; 1 writes config.toml | unknown; `agent start` times out |
| codex-update-0.147 | startup: `✨ Update available! … 1. Update now 2. Skip 3. Skip until next version` | digit; 1 installs | blocked (`agent_not_ready`) |
| codex-auth-error-0.147 | `■ Your access token could not be refreshed …` after a prompt | — | done |
