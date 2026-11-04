#!/usr/bin/env bash
# Builds the public Tentacl Crew release: an ad hoc signed Tentacl.app from a tag, as a zip plus SHA256SUMS. No network side effects.
# Usage: release-public.sh [--source DIR] [--out DIR] [--developer-id] <v-tag>      e.g. v1.0-beta.1
#   --source  the repository holding the tag (default: the repository this script is in)
#   --out     where TentaclCrew-<version>.zip and SHA256SUMS go (default dist/ in the source repository, git-ignored)
# Builds from the tag in a clean temporary copy (never the working tree), with the ad hoc identity forced: Signing.local.xcconfig is not used.
# Users open the app once via System Settings > Privacy & Security > Open Anyway.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
src=$(cd "$HERE/.." && pwd); out=""; ref=""; devid=0
while [ $# -gt 0 ]; do
  case "$1" in
    --source) src=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --developer-id) devid=1; shift ;;
    -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *) ref=$1; shift ;;
  esac
done
die() { echo "ERROR: $*" >&2; exit 1; }
[ -n "$ref" ] || { echo "usage: release-public.sh [--source DIR] [--out DIR] [--developer-id] <v-tag>" >&2; exit 2; }
# TODO(developer-id): when an Apple Developer account exists: sign with "Developer ID Application" + hardened runtime instead of "-",
# then `xcrun notarytool submit --wait`, `xcrun stapler staple Tentacl.app`, and re-zip. Until then the option only stops here.
[ "$devid" -eq 0 ] || die "--developer-id is not set up yet (no Apple Developer account); the public build is ad hoc signed"
case "$ref" in v[0-9]*) ;; *) die "$ref is not a release tag (expected v<version>, e.g. v1.0-beta.1)" ;; esac
git -C "$src" rev-parse --verify --quiet "refs/tags/$ref^{commit}" >/dev/null || die "$ref is not a tag of $src"
commit=$(git -C "$src" rev-parse "refs/tags/$ref^{commit}")
[ -n "$out" ] || out="$src/dist"

work=$(mktemp -d "${TMPDIR:-/tmp}/tentacl-public.XXXXXX") || die "could not make a temporary folder"
trap 'rm -rf "$work"' EXIT
# 1. A clean copy of the tag (no .git, no untracked files, so no Signing.local.xcconfig).
git -C "$src" archive "$commit" | tar -x -C "$work" || die "could not export $ref"
rm -f "$work/app/Signing.local.xcconfig"

# 2. Build with the same version values as release-stable.sh, ad hoc identity forced on the command line.
vers=${ref#v}; vers=${vers%%-*}; label=""
case "$ref" in *-beta.*) label="Beta ${ref##*-beta.}" ;; esac
build=$(git -C "$src" tag --points-at "$commit" --list 'stable-*' | sed 's/^stable-//' | sort -n | tail -1)
vsettings=("MARKETING_VERSION=$vers" "TENTACL_RELEASE_LABEL=$label")
[ -n "$build" ] && vsettings+=("CURRENT_PROJECT_VERSION=$build")
sign=("CODE_SIGN_IDENTITY=-" "DEVELOPMENT_TEAM=" "CODE_SIGN_STYLE=Manual")
xb() { ( cd "$work/app" && xcodebuild -skipPackagePluginValidation -project AgentPanel.xcodeproj -scheme AgentPanel -configuration Release -derivedDataPath build/dd "${vsettings[@]}" "${sign[@]}" "$@" build >"$work/build.log" 2>&1 ); }
if ! xb ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO; then
  echo "WARNING: the universal (arm64 + x86_64) build failed; building for this Mac only" >&2
  xb || { cp "$work/build.log" "${TMPDIR:-/tmp}/tentacl-public-build.log"; die "the build failed, see ${TMPDIR:-/tmp}/tentacl-public-build.log"; }
fi
app="$work/app/build/dd/Build/Products/Release/Tentacl.app"
[ -d "$app" ] || die "the build made no Tentacl.app"

# 3. Checks before packing.
codesign --verify --deep --strict "$app" 2>/dev/null || die "codesign --verify --deep --strict failed for Tentacl.app"
for b in "$app" "$app/Contents/Helpers/tentacld"; do
  info=$(codesign -dvv "$b" 2>&1) || die "codesign -dvv failed for $b"
  ! printf '%s\n' "$info" | grep -q '^Authority=' || die "$b is signed with a certificate (Authority= line); the public build must be ad hoc"
done
plist="$app/Contents/Info.plist"
for k in CFBundleDisplayName CFBundleName; do
  v=$(plutil -extract "$k" raw -o - "$plist" 2>/dev/null)
  [ "$v" = "Tentacl Crew" ] || grep -qa "\"$k\" *= *\"Tentacl Crew\"" "$app"/Contents/Resources/*.lproj/InfoPlist.strings 2>/dev/null || die "$k is not \"Tentacl Crew\" (got \"$v\")"
done
! grep -qa '/Users/' "$plist" || die "Info.plist contains a /Users/ path from the build machine"

# 4. Pack (install.sh comes from the tag too, and is listed in SHA256SUMS).
mkdir -p "$out" || die "could not create $out"
out=$(cd "$out" && pwd); zip="$out/TentaclCrew-${ref#v}.zip"
rm -f "$zip"
( cd "$(dirname "$app")" && ditto -c -k --keepParent Tentacl.app "$zip" ) || die "could not make the zip"
git -C "$src" show "$commit:install.sh" > "$out/install.sh" || die "the tag has no install.sh"
( cd "$out" && shasum -a 256 "$(basename "$zip")" install.sh > SHA256SUMS ) || die "could not write SHA256SUMS"
echo "$zip"; echo "$out/SHA256SUMS"
