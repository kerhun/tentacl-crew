#!/usr/bin/env bash
# No tracked file may carry the author's home path, notes-vault path or the retired example name (repo goes public).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
self=tests/no-personal-paths.test.sh
# The other project's name is built from pieces so this file passes its own check.
other="floo""fle"
# Retired example project name (N391), in all spellings.
pet="pet""[ -]?""diary"
hits=$(git -C "$ROOT" grep -nIiE "/Users/kerhun|Users-kerhun|Obsidian/brain|$other|$pet" -- . ":!$self")
if [ -z "$hits" ]; then echo "PASS no_personal_paths"; echo "-- 1 passed, 0 failed"; else echo "FAIL no_personal_paths"; echo "$hits" | cut -c1-160; echo "-- 0 passed, 1 failed"; exit 1; fi
