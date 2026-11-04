#!/usr/bin/env bash
# Installs Tentacl Crew from a GitHub Release (needs no admin rights; ad hoc signed build).
#   curl -fsSL https://github.com/kerhun/tentacl-crew/releases/latest/download/install.sh | bash
#   bash install.sh [--version v1.0-beta.1] [--dir DIR] [--yes] [--open] [--uninstall [--purge]]
# --open: after the install (or a failed one, which leaves the old app) opens the app; the in-app update uses it.
# Tests only: TENTACL_INSTALL_BASE replaces https://github.com/kerhun/tentacl-crew (release files at $BASE/releases/download/<tag>/),
# TENTACL_INSTALL_API replaces the "latest release" JSON URL. Everything is inside main(), called on the last line,
# so a cut-off download does nothing.
main() {
  set -euo pipefail
  local base=${TENTACL_INSTALL_BASE:-https://github.com/kerhun/tentacl-crew}
  local api=${TENTACL_INSTALL_API:-https://api.github.com/repos/kerhun/tentacl-crew/releases/latest}
  local version="" dir="" yes=0 open=0 uninstall=0 purge=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version=${2:?--version needs a tag}; shift 2 ;;
      --dir) dir=${2:?--dir needs a folder}; shift 2 ;;
      --yes) yes=1; shift ;;
      --open) open=1; shift ;;
      --uninstall) uninstall=1; shift ;;
      --purge) purge=1; shift ;;
      -h|--help) sed -n 2,5p "$0" 2>/dev/null || true; return 0 ;;
      *) echo "ERROR: unknown option $1" >&2; return 2 ;;
    esac
  done
  open_app() { [ "$open" -eq 1 ] && [ -d "${target:-}" ] && open "$target"; return 0; }
  die() { echo "ERROR: $*" >&2; open_app; exit 1; }
  # ask <question>: yes with --yes; else asks on the terminal (/dev/tty, so it works under `curl | bash`); no terminal = no.
  # TENTACL_INSTALL_TTY replaces /dev/tty (tests only).
  ask() {
    [ "$yes" -eq 1 ] && return 0
    local a=""
    printf '%s [y/N] ' "$1" >&2
    { read -r a; } < "${TENTACL_INSTALL_TTY:-/dev/tty}" 2>/dev/null || { echo >&2; return 1; }
    case "$a" in y|Y|yes) return 0 ;; *) return 1 ;; esac
  }
  [ "$(uname -s)" = Darwin ] || die "Tentacl Crew is for macOS only"
  local os; os=$(sw_vers -productVersion) || die "could not read the macOS version"
  [ "${os%%.*}" -ge 14 ] || die "macOS 14 or newer is needed (this Mac has $os)"

  local target
  if [ -n "$dir" ]; then target="$dir/Tentacl.app"
  elif [ "$uninstall" -eq 1 ] && [ ! -d /Applications/Tentacl.app ]; then target="$HOME/Applications/Tentacl.app"
  elif [ -w /Applications ]; then target=/Applications/Tentacl.app
  else target="$HOME/Applications/Tentacl.app"; fi

  # Quit a running copy of this exact app first, only after asking.
  quit_running() {
    local pids; pids=$(pgrep -f "$target/Contents/MacOS/" || true)
    [ -n "$pids" ] || return 0
    ask "Tentacl Crew is running from $target. Quit it now?" || die "Tentacl Crew is running; quit it and run this again (or use --yes)"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$target/Contents/MacOS/" >/dev/null || return 0; sleep 1; done
    die "Tentacl Crew did not quit; quit it yourself and run this again"
  }

  if [ "$uninstall" -eq 1 ]; then
    quit_running
    if [ -d "$target" ]; then rm -rf "$target"; echo "Removed $target"; else echo "Nothing to remove at $target"; fi
    if [ "$purge" -eq 1 ]; then
      local p=("$HOME/.config/tentacl" "$HOME/Library/Application Support/Tentacl" "$HOME/Library/Preferences/com.kerhun.Tentacl.plist")
      echo "--purge would also remove (settings, projects list, logs):"; printf '  %s\n' "${p[@]}"
      if ask "Remove these?"; then rm -rf "${p[@]}"; echo "Removed."; else echo "Kept your data (run with --yes to remove it without asking)."; fi
    fi
    return 0
  fi

  for t in curl shasum ditto codesign; do command -v "$t" >/dev/null || die "$t is needed but not found"; done
  if [ -z "$version" ]; then
    version=$(curl -fsSL "$api" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1) || true
    [ -n "$version" ] || die "could not find the latest release ($api)"
  fi
  case "$version" in v[0-9]*) ;; *) die "$version is not a release tag (expected v<version>)" ;; esac
  local zip="TentaclCrew-${version#v}.zip" tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tentacl-install.XXXXXX") || die "could not make a temporary folder"
  trap "rm -rf '$tmp'" EXIT
  echo "Downloading Tentacl Crew $version ..."
  curl -fsSL -o "$tmp/$zip" "$base/releases/download/$version/$zip" || die "could not download $zip"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/releases/download/$version/SHA256SUMS" || die "could not download SHA256SUMS"
  # Check only the zip's line; the sums file also lists install.sh.
  ( cd "$tmp" && grep -F " $zip" SHA256SUMS | shasum -a 256 -c - >/dev/null 2>&1 ) || die "checksum mismatch for $zip; nothing was installed"
  mkdir "$tmp/x" && ditto -x -k "$tmp/$zip" "$tmp/x" || die "could not unpack $zip"
  [ -d "$tmp/x/Tentacl.app" ] || die "$zip contains no Tentacl.app"
  codesign --verify --deep --strict "$tmp/x/Tentacl.app" 2>/dev/null || die "the app's signature does not verify; nothing was installed"

  quit_running
  mkdir -p "$(dirname "$target")" || die "could not create $(dirname "$target")"
  local old=""
  if [ -e "$target" ]; then old="$target.old.$$"; mv "$target" "$old" || die "could not move the existing app aside"; fi
  if ! ditto "$tmp/x/Tentacl.app" "$target"; then
    rm -rf "$target"; [ -z "$old" ] || mv "$old" "$target"
    die "could not install to $target; the previous app was restored"
  fi
  [ -z "$old" ] || rm -rf "$old"
  open_app
  cat <<MSG
Installed $target
Open Tentacl Crew from Applications. This build is ad hoc signed (not notarized).
If macOS says it cannot verify the app: System Settings → Privacy & Security → Open Anyway.
MSG
}
main "$@"
