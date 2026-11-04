#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
T=$(mktemp -d /tmp/agent-panel-prep.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$T/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
SRC="$T/src" PUB="$T/pub"; git init -q -b main "$SRC"
mkdir -p "$SRC/packaging" "$SRC/spikes/x/logs" "$SRC/app"
cp "$ROOT/.gitleaks.toml" "$SRC/"; echo "spikes/**/logs/" > "$SRC/packaging/public-exclude.txt"
echo keep > "$SRC/app/a"; echo old > "$SRC/app/gone"; echo log > "$SRC/spikes/x/logs/l.log"
git -C "$SRC" add -A; git -C "$SRC" commit -qm one; git -C "$SRC" tag v1
git -C "$SRC" rm -q app/gone; echo new > "$SRC/app/b"; git -C "$SRC" add -A; git -C "$SRC" commit -qm two; git -C "$SRC" tag v2
P="$ROOT/scripts/prepare-public.sh"; run() { bash "$P" --source "$SRC" --public-dir "$PUB" "$@"; }
n() { git -C "$PUB" rev-list --count HEAD 2>/dev/null || echo 0; }
has() { [ -e "$PUB/$1" ] && echo yes || echo no; }

expect dry_run 0 "dry run" bash "$P" --source "$SRC" --public-dir "$PUB" --dry-run v1
[ ! -e "$PUB" ] && { echo "PASS dry_run_writes_nothing"; PASS=$((PASS+1)); } || { echo "FAIL dry_run_writes_nothing"; FAIL=$((FAIL+1)); }
expect first_run 0 "committed" run v1
[ "$(n)" = 1 ] && [ "$(git -C "$PUB" log -1 --format='%an <%ae> %cn <%ce> %s')" = "kerhun <57590016+kerhun@users.noreply.github.com> kerhun <57590016+kerhun@users.noreply.github.com> Tentacl Crew v1" ] \
  && { echo "PASS one_commit_noreply"; PASS=$((PASS+1)); } || { echo "FAIL one_commit_noreply"; FAIL=$((FAIL+1)); }
[ "$(has spikes/x/logs/l.log)" = no ] && [ "$(has app/gone)" = yes ] && { echo "PASS excluded_absent"; PASS=$((PASS+1)); } || { echo "FAIL excluded_absent"; FAIL=$((FAIL+1)); }
expect second_run 0 "committed" run v2
[ "$(n)" = 2 ] && [ "$(has app/gone)" = no ] && [ "$(has app/b)" = yes ] && { echo "PASS second_adds_one_drops_deleted"; PASS=$((PASS+1)); } || { echo "FAIL second_adds_one_drops_deleted"; FAIL=$((FAIL+1)); }
[ -z "$(git -C "$PUB" remote)" ] && { echo "PASS no_remote"; PASS=$((PASS+1)); } || { echo "FAIL no_remote"; FAIL=$((FAIL+1)); }

echo dirty > "$PUB/app/a"; expect dirty_refused 1 "uncommitted" run v2; git -C "$PUB" checkout -q .
bad() { # name, file content
  echo "$2" > "$SRC/app/bad"; git -C "$SRC" add -A; git -C "$SRC" commit -qm "$1"; git -C "$SRC" tag "$1"
  expect "$1" 1 "$3" run "$1"
  [ "$(n)" = 2 ] && { echo "PASS ${1}_nothing_committed"; PASS=$((PASS+1)); } || { echo "FAIL ${1}_nothing_committed"; FAIL=$((FAIL+1)); }
}
bad secret "token = \"ghp_""R8x2Kq9LmN4vB7tYcW3zD6fHjP1sGaE5uXoI\"" "gitleaks"
bad mail "contact me at someone@gm""ail.com" "e-mail"
bad path "see /Users/ker""hun/foo" "personal paths"
finish
