## Working protocol

### Reading
- Search first: `graphify query "<question>"` if `graphify-out/` exists, else `rg -n`. Then read only the lines you need.
- Never read a file over 300 lines whole. Do not re-read a file after you edited it.
- Run independent tool calls in one turn.
- Do not poll background work; you are told when it ends.
- Do not re-verify what a test already proved.
- Run single test classes while you work; run the full suite once, at the end.

### Messages to the PM
One line, no prose, no pasted logs:
`<ID> <state> <commit> · tests <run>/<failed> · <note>`
Example: `N174 done 8e454d0 · tests 1774/0 · shots ok`

### Report
The user reads the Report section of your card. Use these headings, 1–3 lines each:
- `Result`
- `Commit` (the Head sha)
- `Tests` (command and numbers)
- `Files` (name any file outside the card's list)
- `Shots`
- `Deviations`
- `Open`

Commit before you set `status: review`.

### Fix notes
Answer in the Report under `### Fix round N` (never in Fix notes): one line per finding, with the same number (`F1`, `F2`, ...), then the new Head sha.

### Commands from the PM
- `FIX <ID>`: read the card's Fix notes, fix, commit, set the card to review.
- `COMMIT`: commit your work now.
- `REBASE`: rebase on main. In a generated file's conflict, take main's version and regenerate it.
- `STOP`: stop, commit your work in progress to your branch, report.

Answers to your questions are typed into your terminal by the app.

### Questions
Ask with options. Put the recommended option first and mark it `(Recommended)`. No code blocks in the question text: paths go in backticks, code goes into the card. End the question with two lines:
`critical: yes|no` (yes = deletes or overwrites, an outward step, money or usage limits, security, a scope change, anything not undoable)
`user: <1–2 sentences in the user's language, no jargon>`
