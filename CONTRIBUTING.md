# Contributing

## Repository layout
- `app/` — the SwiftUI macOS app (see [Building from source](docs/building.md))
- `scripts/` — config validation, conflict check, agent spawn/stop, PM start and approve requests, wait for an agent, simulator isolation, review packet (see [Scripts](docs/scripts.md))
- `examples/` — project, team chart, role and task card examples
- `docs/` — user and maintainer docs; `docs/screenshots/` holds the README screenshots and the script that regenerates them; `docs/brand/` the icon, wordmark and font sources
- `tests/` — script tests
- `packaging/` — the Homebrew cask (see [Releasing](docs/releasing.md))

Project data (backlog, task cards, real configuration with personal paths) is never committed here; only example files are.

## Tests
```sh
bash tests/run.sh       # scripts
scripts/app-test.sh     # app unit tests (short summary, full log in app/build/test.log)
```
A real PM decision call can be tried with `TEST_RUNNER_TENTACL_LIVE_PM=1 scripts/app-test.sh -only-testing:AgentPanelTests/PMDeciderLiveTests` (uses `haiku`, costs about a cent).

Screenshots are never hand-made: regenerate them with `docs/screenshots/generate.sh` (see [`docs/screenshots/README.md`](docs/screenshots/README.md)).

## Sending a change
1. Work on a branch, in small focused commits.
2. Run both test commands above; for a UI change, attach screenshots of each new state.
3. Keep personal paths out of committed files, and keep the docs in step with the change (the screens in [Using Tentacl Crew](docs/guide.md), script behaviour in [Scripts](docs/scripts.md)).
4. Open a pull request against `main`. Changes merge fast-forward only, so rebase on `main` first.

## Credits
The terminal font menu ships JetBrains Mono (Regular, Bold, Italic, Bold Italic) in `app/AgentPanel/Resources/Fonts/`, © The JetBrains Mono Project Authors, SIL Open Font License 1.1 (`OFL-JetBrainsMono.txt` next to the fonts); Fira Code (`OFL-FiraCode.txt`) is shipped too. The wordmark uses JetBrains Mono ExtraBold and SemiBold, outlined.
