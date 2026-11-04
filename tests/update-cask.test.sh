#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
U="$ROOT/scripts/update-cask.sh"
T=$(mktemp -d /tmp/agent-panel-cask.XXXXXX); trap 'rm -rf "$T"' EXIT
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }; no() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
D="$T/dist"; mkdir -p "$D"; echo zipdata > "$D/TentaclCrew-1.2.zip"
( cd "$D" && shasum -a 256 TentaclCrew-1.2.zip > SHA256SUMS )
sha=$(awk '{print $1}' "$D/SHA256SUMS")
C="$T/c.rb"; cp "$ROOT/packaging/homebrew/Casks/tentacl-crew.rb" "$C"; cp "$C" "$T/orig"
ruby -c "$ROOT/packaging/homebrew/Casks/tentacl-crew.rb" >/dev/null && ok ruby_syntax || no ruby_syntax

expect update_0 0 "version 1.2" bash "$U" v1.2 "$D" --cask "$C"
grep -q "^  version \"1.2\"" "$C" && grep -q "^  sha256 \"$sha\"" "$C" && ok file_updated || no file_updated
ruby -c "$C" >/dev/null && ok ruby_after || no ruby_after
[ "$(sed -n '/livecheck do/,/^  end/p' "$C")" = "$(sed -n '/livecheck do/,/^  end/p' "$T/orig")" ] && grep -q github_latest "$C" && ok livecheck_unchanged || no livecheck_unchanged

cp "$C" "$T/good"
expect tag_mismatch_1 1 "missing" bash "$U" v1.3 "$D" --cask "$C"
expect no_v_prefix_1 1 "not a release tag" bash "$U" 1.2 "$D" --cask "$C"
expect no_args_2 2 "usage" bash "$U"
expect no_cask_1 1 "missing cask" bash "$U" v1.2 "$D" --cask "$T/none.rb"
mkdir "$T/d2"; cp "$D/TentaclCrew-1.2.zip" "$T/d2/"
expect no_sums_1 1 "SHA256SUMS" bash "$U" v1.2 "$T/d2" --cask "$C"
echo "$(printf 0%.0s {1..64})  TentaclCrew-1.2.zip" > "$T/d2/SHA256SUMS"
expect wrong_sum_1 1 "does not match" bash "$U" v1.2 "$T/d2" --cask "$C"
cmp -s "$C" "$T/good" && ok unchanged_on_error || no unchanged_on_error
finish
