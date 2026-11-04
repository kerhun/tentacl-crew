#!/usr/bin/env bash
# update-cask.sh <v-tag> <dist-dir> [--cask FILE]
# Writes version + sha256 of TentaclCrew-<version>.zip (from SHA256SUMS) into the cask. Local only.
set -u
cask="$(cd "$(dirname "$0")/.." && pwd)/packaging/homebrew/Casks/tentacl-crew.rb"
tag=${1:-}; dist=${2:-}; shift 2 2>/dev/null
while [ $# -gt 0 ]; do
  case $1 in --cask) cask=${2:-}; shift 2 ;; *) echo "unknown option: $1" >&2; exit 2 ;; esac
done
[ -n "$tag" ] && [ -n "$dist" ] || { echo "usage: update-cask.sh <v-tag> <dist-dir> [--cask FILE]" >&2; exit 2; }
case $tag in v[0-9]*) ;; *) echo "not a release tag: $tag" >&2; exit 1 ;; esac
version=${tag#v}
[[ $version =~ ^[0-9A-Za-z._-]+$ ]] || { echo "bad version: $version" >&2; exit 1; }
zip="TentaclCrew-$version.zip"
[ -f "$dist/$zip" ] || { echo "missing $dist/$zip (tag does not match the zip name?)" >&2; exit 1; }
[ -f "$dist/SHA256SUMS" ] || { echo "missing $dist/SHA256SUMS" >&2; exit 1; }
[ -f "$cask" ] || { echo "missing cask $cask" >&2; exit 1; }
sha=$(awk -v z="$zip" '$2==z || $2=="*"z {print $1}' "$dist/SHA256SUMS")
[[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "no valid sha256 for $zip in SHA256SUMS" >&2; exit 1; }
[ "$(shasum -a 256 "$dist/$zip" | awk '{print $1}')" = "$sha" ] || { echo "zip does not match SHA256SUMS" >&2; exit 1; }
tmp=$(mktemp) || exit 1; trap 'rm -f "$tmp"' EXIT
sed -E -e "s/^(  version )\".*\"/\1\"$version\"/" -e "s/^(  sha256 )\".*\"/\1\"$sha\"/" "$cask" > "$tmp" || exit 1
cat "$tmp" > "$cask"
echo "updated $cask: version $version, sha256 $sha"
