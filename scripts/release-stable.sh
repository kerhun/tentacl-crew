#!/usr/bin/env bash
# Makes a stable copy of Tentacl: a separate checkout pinned to one commit, built and installed as an app, so Tentacl can be
# developed with Tentacl without the panel running code that is being changed.
# Usage: release-stable.sh [--source DIR] [--stable-dir DIR] [--app-dir DIR] [--set-scripts-dir SETTINGS.json] <ref>
#   <ref>              a tag, branch or commit of the source repository: a release (v1.0-beta.1, v1.0) or a build tag (stable-1)
#   --source           the development repository (default: the repository this script is in)
#   --stable-dir       the pinned checkout, a git worktree of the source (default ~/Documents/GitHub/agent-panel-stable)
#   --app-dir          where Tentacl.app is installed (default ~/Applications)
#   --set-scripts-dir  also point "scriptsDir" in that settings file (~/.config/tentacl/projects.json) at the stable scripts
# The stable checkout is never edited by hand; a checkout with uncommitted changes is refused. Prints the commit that is now stable.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
src=$(cd "$HERE/.." && pwd); stable="$HOME/Documents/GitHub/agent-panel-stable"; apps="$HOME/Applications"; settings=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) src=$2; shift 2 ;;
    --stable-dir) stable=$2; shift 2 ;;
    --app-dir) apps=$2; shift 2 ;;
    --set-scripts-dir) settings=$2; shift 2 ;;
    -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *) ref=$1; shift ;;
  esac
done
[ -n "$ref" ] || { echo "usage: release-stable.sh [--source DIR] [--stable-dir DIR] [--app-dir DIR] [--set-scripts-dir FILE] <ref>" >&2; exit 2; }
die() { echo "ERROR: $*" >&2; exit 1; }

commit=$(git -C "$src" rev-parse --verify --quiet "$ref^{commit}") || die "$ref is not a commit of $src"
if [ -n "$settings" ]; then
  [ -f "$settings" ] && jq empty "$settings" 2>/dev/null || die "$settings is not valid JSON, so it was left as it is"
fi

# 1. The pinned checkout.
if [ -e "$stable/.git" ]; then
  [ -z "$(git -C "$stable" status --porcelain --untracked-files=no 2>/dev/null)" ] || die "$stable has uncommitted changes; the stable copy is never edited by hand"
  git -C "$stable" checkout -q --detach "$commit" || die "could not check out $commit in $stable"
else
  [ ! -e "$stable" ] || die "$stable exists and is not a checkout"
  git -C "$src" worktree add -q --detach "$stable" "$commit" || die "could not create the stable checkout at $stable"
fi
# The signing identity lives in a file that is not committed; without it the stable app would be signed differently from the development one.
[ -f "$src/app/Signing.local.xcconfig" ] && cp "$src/app/Signing.local.xcconfig" "$stable/app/Signing.local.xcconfig"

# 2. Build it. A v<version>[-beta.N] tag sets the app's version (1.0, label "Beta N"); the build number is the stable-N tag on the commit.
vers=""; label=""
case "$ref" in v[0-9]*) vers=${ref#v}; vers=${vers%%-*}; case "$ref" in *-beta.*) label="Beta ${ref##*-beta.}" ;; esac ;; esac
build=$(git -C "$src" tag --points-at "$commit" --list 'stable-*' | sed 's/^stable-//' | sort -n | tail -1)
case "$ref" in stable-[0-9]*) build=${ref#stable-} ;; esac
vsettings=()
[ -n "$vers" ] && vsettings+=("MARKETING_VERSION=$vers" "TENTACL_RELEASE_LABEL=$label")
[ -n "$build" ] && vsettings+=("CURRENT_PROJECT_VERSION=$build")
( cd "$stable/app" && xcodebuild -skipPackagePluginValidation -project AgentPanel.xcodeproj -scheme AgentPanel -configuration Release -derivedDataPath build/dd ${vsettings[@]+"${vsettings[@]}"} build >"$stable/app/build.log" 2>&1 ) \
  || die "the build failed, see $stable/app/build.log"
built="$stable/app/build/dd/Build/Products/Release/Tentacl.app"
[ -d "$built" ] || die "the build made no Tentacl.app"

# 3. Install it (the old app is moved aside first and removed only when the new one is in place).
mkdir -p "$apps" || die "could not create $apps"
if [ -d "$apps/Tentacl.app" ]; then mv "$apps/Tentacl.app" "$apps/Tentacl.app.old" || die "could not move the old app aside"; fi
if ! ditto "$built" "$apps/Tentacl.app"; then
  rm -rf "$apps/Tentacl.app"; [ -d "$apps/Tentacl.app.old" ] && mv "$apps/Tentacl.app.old" "$apps/Tentacl.app"; die "could not install the app"
fi
rm -rf "$apps/Tentacl.app.old"
rm -rf "$built"   # the installed app is the only Tentacl.app left (a second copy confuses Launch Services and Spotlight)

# 4. Optionally make the panel use the stable scripts.
if [ -n "$settings" ]; then
  tmp=$(mktemp "$settings.XXXXXX") && jq --arg d "$stable/scripts" '.scriptsDir = $d' "$settings" > "$tmp" && mv "$tmp" "$settings" || { rm -f "${tmp:-}"; die "could not update $settings"; }
  echo "scriptsDir in $settings now points at $stable/scripts"
fi
echo "stable is now $(git -C "$src" rev-parse --short "$commit") ($ref): app $apps/Tentacl.app, scripts $stable/scripts"
