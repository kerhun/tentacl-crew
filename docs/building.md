# Building from source

`app/` holds a SwiftUI macOS app called **Tentacl Crew** (macOS 14+, no external packages; Swift module `AgentPanel`, product `Tentacl.app`; icon, wordmark and font sources in [`brand/`](brand)). The repository and its folders still use the old name `agent-panel`; the app is **Tentacl Crew**. The Xcode project is generated with [xcodegen](https://github.com/yonaskolb/XcodeGen) from `app/project.yml` and committed.

## Requirements
- macOS 14 or newer, Xcode
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- the `claude` command-line tool (Claude Code) and `jq`, to run agents

## Build and sign
```sh
git clone <this repository> agent-panel && cd agent-panel
cd app && xcodegen generate
xcodebuild -project AgentPanel.xcodeproj -scheme AgentPanel -configuration Release -derivedDataPath build/release build
# the app is app/build/release/Build/Products/Release/Tentacl.app
```
The build is signed ad hoc by default. To keep macOS folder permissions between builds, add your own certificate in `app/Signing.local.xcconfig` (see [Code signing](#code-signing)). Check the pieces with `bash tests/run.sh` (scripts) and `scripts/app-test.sh` (app); see [Contributing](../CONTRIBUTING.md#tests).

```sh
cd app && xcodegen generate     # regenerate AgentPanel.xcodeproj
scripts/app-test.sh             # run the unit tests (short summary, full log in app/build/test.log)
```

## Code signing
So macOS stops asking for folder access after every build: by default the app is signed ad hoc, which gives it a new identity on every build, so macOS asks again for access to folders such as Documents each time. Create `app/Signing.local.xcconfig` (it is git-ignored) with your own certificate and team, as described in `app/Signing.xcconfig`, and rebuild: the identity then stays the same and the permission is asked once. `security find-identity -v -p codesigning` lists your certificates; the team is the `OU` in `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject` (not the number in parentheses).

## Developing Tentacl Crew with Tentacl Crew (stable copy)
Run the panel from a **stable copy** and develop in the normal checkout, so the panel never runs code that an agent is changing. `scripts/release-stable.sh <ref>` pins a second checkout (`~/Documents/GitHub/agent-panel-stable`, a git worktree) to a tag or commit, builds it in Release, installs `~/Applications/Tentacl.app` and, with `--set-scripts-dir ~/.config/tentacl/projects.json`, points `scriptsDir` at the stable scripts. The first stable is the tag `stable-1`. To move on, tag a commit you trust (`git tag -a stable-2`) and run the script again; it refuses a stable checkout with uncommitted changes. Tasks for Tentacl Crew itself are cards in the `agent-panel` project; agents are told never to stop or open the running app.

## Demo mode and snapshots
`Tentacl --demo` opens the panel with the sample project in `app/Demo/` and fake agents (no real project or terminal needed). Settings for a real project live in `~/.config/tentacl/projects.json`:

```json
{ "projects": ["/absolute/path/to/project.json"] }
```

To look at the layout without a screen, the unit tests can write the demo window to a PNG:

```sh
TEST_RUNNER_AGENT_PANEL_SNAPSHOT_PATH=/tmp/panel.png scripts/app-test.sh -only-testing:AgentPanelTests/SnapshotTests
```

(`Tentacl --demo --snapshot out.png` does the same from the app binary; it has only been exercised on a machine with a desktop session.) The design reference is [`design/panel-b-v2.html`](design/panel-b-v2.html).

The README and guide screenshots come from a live window with the demo data, light and dark: `docs/screenshots/generate.sh` (see [`screenshots/README.md`](screenshots/README.md)). Unlike the snapshots above it **needs a logged-in, unlocked screen**; on a locked screen it stops with an error instead of waiting.
