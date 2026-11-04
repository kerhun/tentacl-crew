#!/usr/bin/env bash
# Adds ONE commit to the public repo: the private repo at <ref>, minus packaging/public-exclude.txt.
# Local only: never adds a remote, pushes, tags or creates a GitHub repo.
usage() { echo "usage: prepare-public.sh [--public-dir DIR] [--source DIR] [--dry-run] [--name N] [--email E] <ref>" >&2; exit 2; }
SRC=$(cd "$(dirname "$0")/.." && pwd); PUB="$HOME/Documents/GitHub/tentacl-crew"
NAME=kerhun; EMAIL=57590016+kerhun@users.noreply.github.com; DRY=0; REF=
while [ $# -gt 0 ]; do case $1 in
  --public-dir) PUB=${2:?}; shift 2;; --name) NAME=${2:?}; shift 2;; --email) EMAIL=${2:?}; shift 2;;
  --source) SRC=${2:?}; shift 2;; --dry-run) DRY=1; shift;; -*) usage;; *) REF=$1; shift;; esac; done
[ -n "$REF" ] || usage
git -C "$SRC" rev-parse --verify -q "$REF^{commit}" >/dev/null || { echo "unknown ref: $REF" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

NEW=$(mktemp -d); trap 'rm -rf "$NEW"' EXIT
if [ "$DRY" -eq 0 ]; then
  [ -d "$PUB/.git" ] || { mkdir -p "$PUB" && git init -q -b main "$PUB"; }
  [ -z "$(git -C "$PUB" status --porcelain)" ] || fail "public dir has uncommitted changes: $PUB"
fi

# 1. exact tree of the ref
git -C "$SRC" archive "$REF" | tar -x -C "$NEW"
# 2. remove excluded paths (gitignore patterns, via a scratch repo so git does the matching)
EXC=$(git -C "$SRC" show "$REF:packaging/public-exclude.txt" 2>/dev/null | grep -vE '^\s*(#|$)')
EXCLUDED=
if [ -n "$EXC" ]; then
  git -C "$NEW" init -q; printf '%s\n' "$EXC" > "$NEW/.git/info/exclude"
  EXCLUDED=$(git -C "$NEW" ls-files -o -i --exclude-standard -z | tr '\0' '\n')
  [ -z "$EXCLUDED" ] || printf '%s\n' "$EXCLUDED" | while IFS= read -r f; do rm -f "$NEW/$f"; done
  rm -rf "$NEW/.git"; find "$NEW" -type d -empty -delete
fi

# 3. checks on the new tree
GLC="$NEW/.gitleaks.toml"; [ -f "$GLC" ] || fail ".gitleaks.toml missing in $REF"
GL=$(gitleaks dir "$NEW" --no-banner -c "$GLC" -v 2>&1) || { printf '%s\n' "$GL" | grep -E "^(RuleID|File|Line)" >&2; fail "gitleaks found secrets"; }
P=$(grep -rnIE '/Users/ker[h]un|Users-ker[h]un|Obsidian/br[a]in' "$NEW" --exclude=no-personal-paths.test.sh | sed "s|$NEW/||" | cut -c1-160)
[ -z "$P" ] || { echo "$P" >&2; fail "personal paths in the tree"; }
M=$(grep -rnIoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$NEW" | sed "s|$NEW/||" \
  | grep -viE '@users\.noreply\.github\.com|noreply@|git@github\.com|@example\.(com|org)' | cut -c1-160)
[ -z "$M" ] || { echo "$M" >&2; fail "non-noreply e-mail addresses in the tree"; }

COUNT=$(find "$NEW" -type f | wc -l | tr -d ' ')
if [ "$DRY" -eq 1 ]; then
  echo "dry run: $REF → $COUNT files; checks passed (gitleaks, personal paths, e-mails)"
  echo "excluded paths ($(printf '%s' "$EXCLUDED" | grep -c .) files):"; printf '%s\n' "$EXCLUDED" | sed 's/^/  /'
  exit 0
fi

# 4. replace the public working tree, commit once
find "$PUB" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -a "$NEW"/. "$PUB"/
git -C "$PUB" add -A
if git -C "$PUB" diff --cached --quiet && git -C "$PUB" rev-parse -q --verify HEAD >/dev/null; then
  echo "nothing changed since the last public commit"; exit 0
fi
GIT_AUTHOR_NAME=$NAME GIT_AUTHOR_EMAIL=$EMAIL GIT_COMMITTER_NAME=$NAME GIT_COMMITTER_EMAIL=$EMAIL \
  git -C "$PUB" -c commit.gpgsign=false commit -q -m "Tentacl Crew $REF" || fail "commit failed"
echo "committed $(git -C "$PUB" rev-parse --short HEAD) in $PUB ($COUNT files)"
cat <<TXT
Next (by hand, nothing was done for you):
  1. create the empty repo kerhun/tentacl-crew on GitHub
  2. git -C "$PUB" remote add origin git@github.com:kerhun/tentacl-crew.git
  3. git -C "$PUB" push -u origin main
TXT
