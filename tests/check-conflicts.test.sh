#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
K="$ROOT/scripts/check-conflicts.sh"; C="$ROOT/tests/fixtures/cards"; P="$ROOT/tests/fixtures/config/valid_project.json"

expect separate_files_0                    0 ""                             bash "$K" "$C/a_separate.md" "$C/b_separate.md" "$P"
expect shared_file_1                       1 "CONFLICT: App/Shared.swift"   bash "$K" "$C/a_shared.md" "$C/b_shared.md" "$P"
expect sharedFiles_written_differently_1   1 "CONFLICT:"                    bash "$K" "$C/a_loc_full.md" "$C/b_loc_name.md" "$P"
expect one_card_touches_sharedFiles_0      0 ""                             bash "$K" "$C/a_loc_full.md" "$C/b_other.md" "$P"
expect card_without_files_1                1 "scope"                        bash "$K" "$C/a_separate.md" "$C/c_no_files.md" "$P"

# --- the same file written in different ways still conflicts (I-5) ---
T=$(mktemp -d /tmp/agent-panel-cc.XXXXXX); trap 'rm -rf "$T"' EXIT
mk() { f=$1; shift; { printf -- '---\nid: T\nstatus: todo\n'; printf '%s\n' "$@"; printf -- '---\n# card\n'; } > "$T/$f"; }
mk quoted.md 'files:' '  - "App/X.swift"'
mk dotslash.md 'files:' '  - ./App/X.swift'
mk dir.md 'files:' '  - App/Lost/'
mk inner.md 'files:' '  - App/Lost/LostView.swift'
mk flow.md 'files: [App/X.swift, App/Y.swift]'
expect quotes_and_dot_slash_normalised_1  1 "CONFLICT:" bash "$K" "$T/quoted.md" "$T/dotslash.md" "$P"
expect directory_covers_inner_file_1      1 "CONFLICT:" bash "$K" "$T/dir.md" "$T/inner.md" "$P"
expect flow_style_list_conflicts_1        1 "CONFLICT: App/X.swift" bash "$K" "$T/flow.md" "$T/quoted.md" "$P"
mk single.md 'files: App/Z.swift'
mk flowq.md "files: [\"App/Y.swift\", './App/W.swift']"
expect single_value_files_0               0 "" bash "$K" "$T/single.md" "$T/quoted.md" "$P"
expect single_value_files_conflict_1      1 "CONFLICT: App/Z.swift" bash "$K" "$T/single.md" "$T/single.md" "$P"
expect flow_quoted_items_normalised_1     1 "CONFLICT:" bash "$K" "$T/flowq.md" "$T/flow.md" "$P"
# CRLF cards
for f in quoted dir inner; do sed 's/$/\r/' "$T/$f.md" > "$T/crlf_$f.md"; done
expect crlf_cards_conflict_1              1 "CONFLICT:" bash "$K" "$T/crlf_dir.md" "$T/crlf_inner.md" "$P"
expect crlf_vs_lf_conflict_1              1 "CONFLICT:" bash "$K" "$T/crlf_quoted.md" "$T/dotslash.md" "$P"
# kind and files are read from the front matter only
printf -- '---\nid: T\nstatus: todo\nfiles:\n  - App/Lost/\n---\n# card\nkind: analysis\nfiles:\n  - Other.swift\n' > "$T/bodykind.md"
expect body_kind_analysis_ignored_1       1 "CONFLICT:" bash "$K" "$T/bodykind.md" "$T/inner.md" "$P"


# --- an analysis task (kind: analysis) changes nothing, so it never conflicts with another task ---
mka() { f=$1; shift; { printf -- '---\nid: T\nstatus: todo\nkind: analysis\n'; printf '%s\n' "$@"; printf -- '---\n# card\n'; } > "$T/$f"; }
mka analysis_dir.md 'files:' '  - App/'
mka analysis_dir2.md 'files:' '  - App/'
expect two_analysis_tasks_on_the_same_dir_0   0 ""          bash "$K" "$T/analysis_dir.md" "$T/analysis_dir2.md" "$P"
expect analysis_beside_a_writer_0             0 ""          bash "$K" "$T/analysis_dir.md" "$T/inner.md" "$P"
expect writer_beside_an_analysis_0            0 ""          bash "$K" "$T/inner.md" "$T/analysis_dir.md" "$P"
expect two_writers_still_conflict_1           1 "CONFLICT:" bash "$K" "$T/dir.md" "$T/inner.md" "$P"
mka analysis_noscope.md
expect analysis_without_files_is_fine_0       0 ""          bash "$K" "$T/analysis_noscope.md" "$T/inner.md" "$P"
sed 's/$/\r/' "$T/analysis_dir.md" > "$T/crlf_analysis.md"
expect crlf_analysis_never_conflicts_0        0 ""          bash "$K" "$T/crlf_analysis.md" "$T/inner.md" "$P"
finish
