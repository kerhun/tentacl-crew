# Screenshots

The PNGs here are used by the top-level README and by `docs/guide.md`. They are not hand-made: `ReadmeShotsTests` opens a real, on-screen window that hosts the app's own views with the demo data (`app/Demo`, with `/Users/you/…` paths), once in light and once in dark, and writes `<name>.png` and `<name>-dark.png`. README and guide show them with `<picture>` and `prefers-color-scheme`, so GitHub shows the one that matches the reader.

```
docs/screenshots/generate.sh
```

This runs only `ReadmeShotsTests` with `TEST_RUNNER_AGENT_PANEL_README_SHOTS` pointing at a temporary folder, then copies every shot here at 1400 px wide (`sips`). To change which screens are used, edit the test, the list in `generate.sh` and the README or guide. It does not start or touch the Tentacl app.

**It needs a logged-in, unlocked screen**: the window is drawn on screen, and a locked screen draws no window materials. The script checks this first and stops with an error (exit 2) when the screen is locked or there is no screen session (for example over ssh); it never waits for the screen. Without `AGENT_PANEL_README_SHOTS` the shot tests are skipped, so the normal test run is not affected.
