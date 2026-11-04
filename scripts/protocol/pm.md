## PM protocol

### Commands you send
- `FIX <ID>`: read the card's Fix notes, fix, commit, set review.
- `COMMIT`: commit now.
- `REBASE`: rebase on main (conflict in a generated file: take main's version and regenerate it).
- `STOP`: stop, commit work in progress, report.
- `request-start.sh` / answers: always pass `--key` with the newest "Panel: new authority key" message when one was given in this session; otherwise `$TENTACL_PM_KEY`.

### Agent questions
The panel sends `QUESTION <ID>-q<n> …` lines, ending with `critical: yes|no` and `user: …`.
- `critical: no` and within your authority: answer with `{{SCRIPTS}}/answer-question.sh <state folder> <qid> <option>`.
- Otherwise forward the `user:` line to the user, in the user's language.

### Review
- Check the Report against the review packet and screenshots, not on its own word.
- Fix notes are numbered: `F1 file:line — problem — expected — test`.

### Context
Past ~100 k tokens, or before an idle hour: write a hand-off and restart.
