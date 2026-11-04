# Releasing

Maintainer steps for a public release. Users install with `install.sh` or Homebrew, see [Install and update](guide.md#install-and-update).

## Steps
0. `scripts/prepare-public.sh <ref>` adds one commit (noreply author, message `Tentacl Crew <ref>`) to the local public repo (`~/Documents/GitHub/tentacl-crew`, `--public-dir`) with the tree of `<ref>` minus `packaging/public-exclude.txt`. It runs gitleaks, a personal-path check and an e-mail check first, and never adds a remote or pushes; `--dry-run` only reports. Create the GitHub repo, `git remote add` and `git push` yourself.
1. `scripts/release-public.sh v<version>` builds `TentaclCrew-<version>.zip` and `SHA256SUMS`.
2. Upload the zip, `SHA256SUMS` and `install.sh` as assets of the GitHub release `v<version>`.
3. `scripts/update-cask.sh v<version> <dist-dir>` writes version and sha256 into `packaging/homebrew/Casks/tentacl-crew.rb` (local only).
4. Copy that file to `~/Documents/GitHub/homebrew-tap/Casks/` (remote `kerhun/homebrew-tap`), commit as `kerhun <57590016+kerhun@users.noreply.github.com>` with message `tentacl-crew <version>` (no co-author trailer) and push.
5. Check: `brew audit --cask --online kerhun/tap/tentacl-crew`.

The GitHub release must not be marked prerelease: `install.sh` and the cask `livecheck` use `releases/latest`.

## Tags
Use a new tag for every public release (`v1.0-beta.2`, …); a moved tag is invisible to installed apps, because Settings → *Version and updates* checks GitHub Releases for a newer tag.

## Homebrew
The cask installs the same ad hoc signed build: `brew tap kerhun/tap && brew trust kerhun/tap && brew install --cask tentacl-crew`; `brew uninstall --cask --zap tentacl-crew` also removes settings and data. The build is not notarized, so users open it once via System Settings → Privacy & Security → *Open Anyway*.
