#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
R="$ROOT/scripts/release-public.sh"
T=$(mktemp -d /tmp/agent-panel-pub.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$T/gitconfig"; export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
SRC="$T/src"; git init -q -b main "$SRC"; mkdir -p "$SRC/app"; echo x > "$SRC/app/f"; echo "echo installer" > "$SRC/install.sh"; git -C "$SRC" add -A; git -C "$SRC" commit -q -m one
git -C "$SRC" tag v1.0-beta.1; git -C "$SRC" tag stable-5; git -C "$SRC" branch notatag
echo '// local' > "$SRC/app/Signing.local.xcconfig"   # untracked; must never reach the build
# fake xcodebuild: records its arguments and whether Signing.local.xcconfig was present, makes an app
mkdir -p "$T/bin"; cat > "$T/bin/xcodebuild" <<'XEOF'
#!/bin/sh
echo "$*" > "$FAKE_LOG"; [ -e Signing.local.xcconfig ] && echo LOCAL_SEEN >> "$FAKE_LOG"
dd=""; while [ $# -gt 0 ]; do [ "$1" = "-derivedDataPath" ] && dd=$2; shift; done
a="$dd/Build/Products/Release/Tentacl.app"; mkdir -p "$a/Contents/Helpers"; echo tentacld > "$a/Contents/Helpers/tentacld"
cat > "$a/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleDisplayName</key><string>${FAKE_NAME:-Tentacl Crew}</string><key>CFBundleName</key><string>Tentacl Crew</string></dict></plist>
P
XEOF
cat > "$T/bin/codesign" <<'CEOF'
#!/bin/sh
case "$1" in -dvv) [ -n "$FAKE_AUTH" ] && echo "Authority=Apple Development: x" >&2; echo "Signature=adhoc" >&2 ;; esac
exit 0
CEOF
chmod +x "$T/bin/xcodebuild" "$T/bin/codesign"; export PATH="$T/bin:$PATH" FAKE_LOG="$T/log"
O="$T/out"; run() { bash "$R" --source "$SRC" --out "$O" "$@"; }

expect non_v_ref_1 1 "not a release tag" run stable-5
expect branch_not_tag_1 1 "not a release tag" run notatag
expect unknown_tag_1 1 "not a tag" run v9.9
expect developer_id_stops_1 1 "not set up yet" run --developer-id v1.0-beta.1
FAKE_AUTH=1 expect authority_refused_1 1 "Authority=" run v1.0-beta.1
[ ! -e "$O/SHA256SUMS" ] && ok_=1 || ok_=0; [ $ok_ = 1 ] && { echo "PASS  nothing_written_on_refusal"; PASS=$((PASS+1)); } || { echo "FAIL  nothing_written_on_refusal"; FAIL=$((FAIL+1)); }
FAKE_NAME=Tentacl expect old_name_refused_1 1 "CFBundleDisplayName" run v1.0-beta.1
expect release_0 0 "TentaclCrew-1.0-beta.1.zip" run v1.0-beta.1
grep -q "CODE_SIGN_IDENTITY=-" "$T/log" && grep -q "MARKETING_VERSION=1.0" "$T/log" && grep -q "TENTACL_RELEASE_LABEL=Beta 1" "$T/log" && grep -q "CURRENT_PROJECT_VERSION=5" "$T/log" && ! grep -q LOCAL_SEEN "$T/log" \
  && { echo "PASS  ad_hoc_forced_versions_set_local_signing_unused"; PASS=$((PASS+1)); } || { echo "FAIL  ad_hoc_forced: $(cat "$T/log")"; FAIL=$((FAIL+1)); }
( cd "$O" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ) && unzip -l "$O/TentaclCrew-1.0-beta.1.zip" | grep -q "Tentacl.app/Contents/Info.plist" \
  && { echo "PASS  zip_and_sums_match"; PASS=$((PASS+1)); } || { echo "FAIL  zip_and_sums_match"; FAIL=$((FAIL+1)); }
grep -q " install.sh" "$O/SHA256SUMS" && [ "$(cat "$O/install.sh")" = "echo installer" ] \
  && { echo "PASS  install_sh_in_output_and_sums"; PASS=$((PASS+1)); } || { echo "FAIL  install_sh_in_output_and_sums"; FAIL=$((FAIL+1)); }
finish
