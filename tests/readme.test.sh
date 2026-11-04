#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }
R="$ROOT/README.md"; G="$ROOT/docs/guide.md"; S="$ROOT/docs/scripts.md"; B="$ROOT/docs/building.md"

# README: the short GitHub page.
for h in 'Quick start' 'Install' 'How it works' 'Requirements' 'Docs' 'License'; do
  grep -q "^## $h\$" "$R" && ok "readme_has_$h" || no "readme_has_$h" "missing heading"
done
grep -q '^```mermaid' "$R" && ok readme_has_mermaid || no readme_has_mermaid ""
for d in docs/guide.md docs/building.md docs/scripts.md docs/releasing.md CONTRIBUTING.md; do
  grep -qF "]($d)" "$R" && [ -s "$ROOT/$d" ] && ok "readme_docs_table_$d" || no "readme_docs_table_$d" "not linked or missing"
done
for w in light dark; do
  f="docs/brand/wordmark/tentacl-crew-wordmark-$w.png"
  grep -qF "$f" "$R" && [ -s "$ROOT/$f" ] && [ -s "$ROOT/${f%.png}.svg" ] && ok "readme_wordmark_$w" || no "readme_wordmark_$w" "missing"
done
grep -q 'docs/screenshots/dashboard.png' "$R" && ok readme_has_dashboard || no readme_has_dashboard ""

# Screenshots referenced from README (markdown or <img src>) and docs/*.md exist.
shots=$( { grep -oE '(\(|src=")docs/screenshots/[^)"]+\.png' "$R" | sed -E 's/^(\(|src=")//';
           grep -ohE '\(screenshots/[^)]+\.png' "$ROOT"/docs/*.md | sed 's/^(/docs\//'; } | sort -u)
[ -n "$shots" ] && ok readme_references_screenshots || no readme_references_screenshots "none"
for s in $shots; do [ -s "$ROOT/$s" ] && ok "exists_$s" || no "exists_$s" "missing"; done
# Every <img src> and <source srcset> in README.md and docs/*.md points at a file (relative to that page), and every screenshot
# <picture> has a dark twin (<name>-dark.png) next to its light one (N383).
for page in "$R" "$ROOT"/docs/*.md; do
  base=$(dirname "$page"); rel=${page#"$ROOT"/}
  for p in $(grep -oE '(src|srcset)="[^"]+"' "$page" | sed -E 's/^(src|srcset)="//; s/"$//' | grep -v '^https\?:'); do
    [ -s "$base/$p" ] && ok "img_exists_${rel}_$p" || no "img_exists_${rel}_$p" "missing"
  done
  for p in $(grep -oE 'src="[^"]*screenshots/[^"]+\.png"' "$page" | sed -E 's/^src="//; s/"$//'); do
    grep -qF "srcset=\"${p%.png}-dark.png\"" "$page" && ok "dark_twin_${rel}_$p" || no "dark_twin_${rel}_$p" "no dark <source>"
  done
done
grep -q 'reshoot before release' "$R" "$ROOT"/docs/*.md && no no_reshoot_markers "marker left" || ok no_reshoot_markers
[ -x "$ROOT/docs/screenshots/generate.sh" ] && ok generate_script_executable || no generate_script_executable ""
for f in project.example.json project.minimal.example.json; do
  expect "validate_$f" 0 "" bash "$ROOT/scripts/validate-config.sh" "$ROOT/examples/$f"
done
jq -e '.version == 1 and (.members | length) > 0' "$ROOT/examples/team.example.json" >/dev/null && ok team_example_valid || no team_example_valid ""

# docs/guide.md: one short section per screen, the autopilot's exact limits and the newer features.
grep -q '^## The screens' "$G" && ok guide_has_screens || no guide_has_screens ""
for h in 'Tasks' 'Task detail' 'New task' 'Agents and Chat on the Dashboard' 'Plan a round' 'Plan' 'Stats' 'Settings'; do
  grep -qF "**$h.**" "$G" && ok "guide_screen_$h" || no "guide_screen_$h" "missing section"
done
for t in 'Update stable' 'Relaunch now' 'Clean up' 'Start PM' 'priority' 'What matters for this round' 'Ask the agent to commit' 'estimated cost' 'Phase notices'; do
  grep -qF "$t" "$G" && ok "guide_mentions_$t" || no "guide_mentions_$t" "missing"
done
grep -q 'merges it' "$G" && ok guide_autopilot_says_it_merges_on_request || no guide_autopilot_says_it_merges_on_request ""
for s in dashboard settings; do grep -q "src=\"screenshots/$s.png\"" "$G" && ok "guide_has_$s" || no "guide_has_$s" ""; done
grep -qF 'copyFiles' "$S" && ok scripts_mentions_copyFiles || no scripts_mentions_copyFiles "missing"
grep -qF 'merge-task.sh` exit' "$S" && ok scripts_has_merge_exit_codes || no scripts_has_merge_exit_codes "missing"
grep -qF 'release-stable.sh' "$B" && ok building_mentions_stable_copy || no building_mentions_stable_copy "missing"

# Old claims stay out of README.md and every docs page.
docs=("$R" "$ROOT"/docs/*.md)
grep -q 'the autopilot never touches them' "${docs[@]}" && no docs_autopilot_not_contradicting "old claim" || ok docs_autopilot_not_contradicting
grep -q 'screenshots/pm-tab.png' "${docs[@]}" && no docs_no_pm_tab_image "old name" || ok docs_no_pm_tab_image
grep -q 'Agents column' "${docs[@]}" && no docs_no_agents_column "old name" || ok docs_no_agents_column

# License and brand.
grep -q 'MIT License\](LICENSE)' "$R" && grep -q '(THIRD_PARTY_NOTICES)' "$R" && ok readme_names_mit_license || no readme_names_mit_license "README must link MIT LICENSE and THIRD_PARTY_NOTICES"
grep -qF 'are not covered: you may not use them to name or brand your own fork or product' "$R" && ok readme_brand_not_covered || no readme_brand_not_covered "missing"
[ -f "$ROOT/LICENSE" ] && [ -f "$ROOT/THIRD_PARTY_NOTICES" ] && ok license_files_exist || no license_files_exist "missing"
grep -qxF 'Copyright (c) 2026 Ibrahim Torus (kerhun)' "$ROOT/LICENSE" && ok license_copyright_line || no license_copyright_line "wrong line"
finish
