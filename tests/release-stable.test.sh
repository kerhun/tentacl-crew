#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
R="$ROOT/scripts/release-stable.sh"
T=$(mktemp -d /tmp/agent-panel-rel.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
export GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$T/gitconfig"; export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# a throwaway source repository shaped like agent-panel
SRC="$T/src"; git init -q -b main "$SRC"; mkdir -p "$SRC/app/AgentPanel.xcodeproj" "$SRC/scripts"; echo v1 > "$SRC/scripts/a.sh"; echo '// local' > "$SRC/app/Signing.local.xcconfig"
git -C "$SRC" add scripts app/AgentPanel.xcodeproj 2>/dev/null; touch "$SRC/app/AgentPanel.xcodeproj/project.pbxproj"; git -C "$SRC" add -A -f scripts app/AgentPanel.xcodeproj; git -C "$SRC" commit -q -m one; git -C "$SRC" tag stable-1
echo v2 > "$SRC/scripts/a.sh"; git -C "$SRC" commit -q -am two; git -C "$SRC" tag stable-2
# a fake xcodebuild that "builds" an app and remembers where it was told to build
mkdir -p "$T/bin"; cat > "$T/bin/xcodebuild" <<'XEOF'
#!/bin/sh
dd=""; while [ $# -gt 0 ]; do [ "$1" = "-derivedDataPath" ] && dd=$2; shift; done
mkdir -p "$dd/Build/Products/Release/Tentacl.app/Contents"; echo "built from $(cat ../scripts/a.sh)" > "$dd/Build/Products/Release/Tentacl.app/Contents/marker"
XEOF
chmod +x "$T/bin/xcodebuild"; export PATH="$T/bin:$PATH"
ST="$T/stable"; APPS="$T/apps"; mkdir -p "$APPS"
run() { bash "$R" --source "$SRC" --stable-dir "$ST" --app-dir "$APPS" "$@"; }

expect first_release_0 0 "stable-1" run stable-1
[ "$(cat "$ST/scripts/a.sh")" = v1 ] && ok stable_checkout_is_at_the_tag || no stable_checkout_is_at_the_tag "$(cat "$ST/scripts/a.sh")"
grep -q "built from v1" "$APPS/Tentacl.app/Contents/marker" && ok app_copied || no app_copied ""
[ -f "$ST/app/Signing.local.xcconfig" ] && ok local_signing_copied || no local_signing_copied ""
expect second_release_updates_0 0 "stable-2" run stable-2
[ "$(cat "$ST/scripts/a.sh")" = v2 ] && grep -q "built from v2" "$APPS/Tentacl.app/Contents/marker" && ok update_replaces_checkout_and_app || no update_replaces_checkout_and_app ""
[ ! -d "$APPS/Tentacl.app.old" ] && ok no_leftover_old_app || no no_leftover_old_app ""
echo dirty > "$ST/scripts/a.sh"
expect dirty_stable_refused_1 1 "uncommitted" run stable-1
[ "$(cat "$ST/scripts/a.sh")" = dirty ] && ok dirty_stable_untouched || no dirty_stable_untouched ""
git -C "$ST" checkout -q -- scripts/a.sh
expect unknown_ref_1 1 "not a commit" run no-such-ref
rm -rf "$T/apps2"; mkdir "$T/apps2"
printf '{"scriptsDir":"/old","projects":["/p/project.json"]}\n' > "$T/projects.json"
expect set_scripts_dir_0 0 "scriptsDir" bash "$R" --source "$SRC" --stable-dir "$ST" --app-dir "$T/apps2" --set-scripts-dir "$T/projects.json" stable-1
jq -e --arg d "$ST/scripts" '.scriptsDir == $d and .projects == ["/p/project.json"]' "$T/projects.json" >/dev/null && ok scripts_dir_updated_keys_kept || no scripts_dir_updated_keys_kept "$(cat "$T/projects.json")"
echo '{ broken' > "$T/bad.json"
expect corrupt_settings_untouched_1 1 "not valid" bash "$R" --source "$SRC" --stable-dir "$ST" --app-dir "$T/apps2" --set-scripts-dir "$T/bad.json" stable-1
[ "$(cat "$T/bad.json")" = '{ broken' ] && ok corrupt_settings_kept || no corrupt_settings_kept ""
finish
