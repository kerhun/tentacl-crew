#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
C="$ROOT/scripts/create-project.sh"; V="$ROOT/scripts/validate-config.sh"
T=$(mktemp -d /tmp/agent-panel-cp.XXXXXX); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/code" "$T/wiki" "$T/roles"
for r in pm dev reviewer; do echo '{}' > "$T/roles/$r.json"; done
export TENTACL_ROLES_DIR="$T/roles" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
: > "$T/gitconfig"   # no git identity at all: the script must still be able to commit
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1: $2"; FAIL=$((FAIL+1)); }

# --- Other preset ---
expect other_preset_creates_0 0 "" bash "$C" "$T/code/recipe-box" "$T/wiki/recipe-box" recipe-box "Recipe Box" other
P="$T/wiki/recipe-box/agent-panel/project.json"
expect other_project_json_valid_0 0 "" bash "$V" "$P"
expect other_team_json_valid_0 0 "" bash "$V" "$T/wiki/recipe-box/agent-panel/team.json"
jq -e '.id=="recipe-box" and .name=="Recipe Box" and .repoPath=="'"$T/code/recipe-box"'" and .dataDir=="'"$T/wiki/recipe-box"'" and .screenshots==false and (has("simulator")|not) and (has("buildCommand")|not) and .maxParallel==2' "$P" >/dev/null && ok other_project_json_fields || no other_project_json_fields "$(cat "$P")"
[ "$(git -C "$T/code/recipe-box" rev-parse --abbrev-ref HEAD)" = main ] && [ "$(git -C "$T/code/recipe-box" log --oneline | wc -l | tr -d ' ')" = 1 ] && ok repo_has_main_and_one_commit || no repo_has_main_and_one_commit "$(git -C "$T/code/recipe-box" log --oneline 2>&1)"
grep -qx '.agent-worktrees/' "$T/code/recipe-box/.gitignore" && ok gitignore_has_worktrees || no gitignore_has_worktrees "$(cat "$T/code/recipe-box/.gitignore")"
[ -d "$T/wiki/recipe-box/tasks" ] && ok tasks_folder_exists || no tasks_folder_exists ""
jq -e '[.members[]|{(.role):.reportsTo}]|add == {"pm":null,"reviewer":"pm","dev":"reviewer"}' "$T/wiki/recipe-box/agent-panel/team.json" >/dev/null && ok team_uses_only_existing_roles || no team_uses_only_existing_roles "$(cat "$T/wiki/recipe-box/agent-panel/team.json")"
[ -z "$(git -C "$T/code/recipe-box" status --porcelain)" ] && ok repo_clean_after_creation || no repo_clean_after_creation ""

# --- iOS preset ---
expect ios_preset_creates_0 0 "" bash "$C" "$T/code/cicek" "$T/wiki/cicek" cicek "Çiçek" ios Cicek "iPhone 17 Pro"
P2="$T/wiki/cicek/agent-panel/project.json"
expect ios_project_json_valid_0 0 "" bash "$V" "$P2"
jq -e '.xcodeProject=="Cicek.xcodeproj" and .simulator.baseDevice=="iPhone 17 Pro" and .openWith=="Xcode" and (.buildCommand|contains("Cicek")) and (.buildCommand|contains("$UDID"))' "$P2" >/dev/null && ok ios_project_json_fields || no ios_project_json_fields "$(cat "$P2")"

# --- never overwrites ---
mkdir -p "$T/code/taken"; echo keep > "$T/code/taken/file.txt"
expect existing_repo_refused_1 1 "already exists" bash "$C" "$T/code/taken" "$T/wiki/taken" taken Taken other
[ ! -e "$T/wiki/taken" ] && [ "$(cat "$T/code/taken/file.txt")" = keep ] && ok existing_repo_untouched || no existing_repo_untouched ""
mkdir -p "$T/wiki/occupied"
expect existing_data_refused_1 1 "already exists" bash "$C" "$T/code/occupied" "$T/wiki/occupied" occupied Occupied other
[ ! -e "$T/code/occupied" ] && ok existing_data_leaves_no_repo || no existing_data_leaves_no_repo ""

# --- bad arguments ---
expect bad_id_2 2 "id" bash "$C" "$T/code/x1" "$T/wiki/x1" "../x" X other
expect bad_preset_2 2 "preset" bash "$C" "$T/code/x2" "$T/wiki/x2" x2 X windows
expect relative_path_2 2 "absolute" bash "$C" "code/x3" "$T/wiki/x3" x3 X other
expect missing_parent_1 1 "parent" bash "$C" "$T/nope/x4" "$T/wiki/x4" x4 X other
[ ! -e "$T/wiki/x4" ] && ok missing_parent_creates_nothing || no missing_parent_creates_nothing ""

# --- a failure half way undoes only what this run made ---
mkdir -p "$T/bin"; printf '#!/bin/sh\ncase " $* " in *" commit "*) echo boom >&2; exit 1 ;; esac\nexec /usr/bin/git "$@"\n' > "$T/bin/git"; chmod +x "$T/bin/git"
expect failing_commit_1 1 "initial commit" env PATH="$T/bin:$PATH" bash "$C" "$T/code/halfway" "$T/wiki/halfway" halfway Halfway other
[ ! -e "$T/code/halfway" ] && [ ! -e "$T/wiki/halfway" ] && ok half_made_project_removed || no half_made_project_removed "$(ls "$T/code" "$T/wiki")"
[ -d "$T/code/recipe-box" ] && [ -d "$T/wiki/recipe-box" ] && ok earlier_projects_untouched || no earlier_projects_untouched ""

# --- --existing: register a repository that is already there; only the data folder is written ---
git init -q -b trunk "$T/code/old"; git -C "$T/code/old" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first; echo mine > "$T/code/old/mine.txt"
before=$(git -C "$T/code/old" status --porcelain; git -C "$T/code/old" log --oneline)
expect existing_mode_0 0 "" bash "$C" --existing --branch trunk "$T/code/old" "$T/wiki/old" old "Old One" other
after=$(git -C "$T/code/old" status --porcelain; git -C "$T/code/old" log --oneline)
[ "$before" = "$after" ] && [ ! -e "$T/code/old/.gitignore" ] && ok existing_repo_not_modified || no existing_repo_not_modified "$after"
expect existing_project_json_valid_0 0 "" bash "$V" "$T/wiki/old/agent-panel/project.json"
jq -e '.mainBranch=="trunk" and .repoPath=="'"$T/code/old"'"' "$T/wiki/old/agent-panel/project.json" >/dev/null && ok existing_records_main_branch || no existing_records_main_branch "$(cat "$T/wiki/old/agent-panel/project.json")"
git init -q -b main "$T/code/main1"; git -C "$T/code/main1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
bash "$C" --existing --branch main "$T/code/main1" "$T/wiki/main1" main1 "Main One" other >/dev/null 2>&1
jq -e 'has("mainBranch") | not' "$T/wiki/main1/agent-panel/project.json" >/dev/null && ok main_branch_main_is_default || no main_branch_main_is_default ""
expect existing_mode_missing_repo_1 1 "not a git repository" bash "$C" --existing "$T/code/ghost" "$T/wiki/ghost" ghost Ghost other
mkdir -p "$T/code/plain"; expect existing_mode_plain_folder_1 1 "not a git repository" bash "$C" --existing "$T/code/plain" "$T/wiki/plain" plain Plain other
[ ! -e "$T/wiki/plain" ] && [ ! -e "$T/wiki/ghost" ] && ok existing_failures_write_nothing || no existing_failures_write_nothing ""
expect existing_mode_reuses_data_0 0 "project.json" bash "$C" --existing "$T/code/old" "$T/wiki/old" old2 "Old Two" other
[ -d "$T/code/old/.git" ] && [ -f "$T/code/old/mine.txt" ] && ok failed_existing_keeps_repo || no failed_existing_keeps_repo ""

# --- review fixes ---
# I1: the data folder never lands inside (or on) the repository
git init -q -b main "$T/code/host"; git -C "$T/code/host" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
expect data_inside_existing_repo_1 1 "inside" bash "$C" --existing "$T/code/host" "$T/code/host/data" host1 Host1 other
[ ! -e "$T/code/host/data" ] && ok data_inside_repo_writes_nothing || no data_inside_repo_writes_nothing "$(ls "$T/code/host")"
expect data_equals_existing_repo_1 1 "ERROR" bash "$C" --existing "$T/code/host" "$T/code/host" host2 Host2 other
expect new_repo_and_data_same_folder_1 1 "same" bash "$C" "$T/code/same" "$T/code/same" same Same other
# I4: a newline cannot sneak past the format checks
expect newline_in_id_2 2 "line break" bash "$C" "$T/code/n1" "$T/wiki/n1" $'ab\n../evil' N other
expect newline_in_xcode_name_2 2 "line break" bash "$C" "$T/code/n2" "$T/wiki/n2" n2 N ios $'Foo\n$(touch /tmp/pwned-cp)' "iPhone 17 Pro"
expect newline_in_name_2 2 "line break" bash "$C" "$T/code/n3" "$T/wiki/n3" n3 $'N\nx' other
[ ! -e /tmp/pwned-cp ] && ok no_injection_file || no no_injection_file "created"
# I5: an Xcode project name with a space or a dash is accepted and quoted in the build command
git init -q -b main "$T/code/xc"; git -C "$T/code/xc" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
expect xcode_name_with_space_0 0 "" bash "$C" --existing "$T/code/xc" "$T/wiki/xc" xc "Xc App" ios "My App" "iPhone 17 Pro"
jq -e '.xcodeProject=="My App.xcodeproj" and (.buildCommand|contains("-project '"'"'My App.xcodeproj'"'"'")) and (.buildCommand|contains("-scheme '"'"'My App'"'"'"))' "$T/wiki/xc/agent-panel/project.json" >/dev/null && ok xcode_name_quoted_in_build_command || no xcode_name_quoted_in_build_command "$(jq -r .buildCommand "$T/wiki/xc/agent-panel/project.json")"
expect xcode_name_with_dash_0 0 "" bash "$C" "$T/code/xd" "$T/wiki/xd" xd "Xd" ios "Recipe-Box" "iPhone 17 Pro"
expect xcode_name_with_quote_2 2 "Xcode name" bash "$C" "$T/code/xe" "$T/wiki/xe" xe "Xe" ios "A'b" "iPhone 17 Pro"
# I3: a killed run removes what it made (a commit that hangs, as with a GPG prompt, is interrupted too)
mkdir -p "$T/bin2"; printf '#!/bin/sh\ncase " $* " in *" commit "*) sleep 30 ;; esac\nexec /usr/bin/git "$@"\n' > "$T/bin2/git"; chmod +x "$T/bin2/git"
PATH="$T/bin2:$PATH" bash "$C" "$T/code/hang" "$T/wiki/hang" hang Hang other >/dev/null 2>&1 &
pid=$!; for i in 1 2 3 4 5 6 7 8 9 10; do [ -d "$T/code/hang/.git" ] && break; sleep 0.3; done; sleep 0.5
kill -TERM "$pid" 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
[ ! -e "$T/code/hang" ] && [ ! -e "$T/wiki/hang" ] && ok killed_run_removes_its_folders || no killed_run_removes_its_folders "$(ls "$T/code" | tr '\n' ' ')"
pkill -f "$T/bin2" 2>/dev/null
# the commit ignores a global signing setup and hooks
printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = /nonexistent\n' > "$T/gitconfig2"
expect commit_ignores_gpg_signing_0 0 "" env GIT_CONFIG_GLOBAL="$T/gitconfig2" bash "$C" "$T/code/signed" "$T/wiki/signed" signed Signed other

# --- --existing with a data folder that is already there (a project whose notes are already in the wiki) ---
git init -q -b main "$T/code/kept"; git -C "$T/code/kept" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
mkdir -p "$T/wiki/kept/tasks"; echo "my card" > "$T/wiki/kept/tasks/A1.md"; echo "notes" > "$T/wiki/kept/notes.md"
expect existing_data_without_settings_0 0 "" bash "$C" --existing "$T/code/kept" "$T/wiki/kept" kept Kept other
[ "$(cat "$T/wiki/kept/tasks/A1.md")" = "my card" ] && [ "$(cat "$T/wiki/kept/notes.md")" = notes ] && ok existing_data_files_untouched || no existing_data_files_untouched ""
expect existing_data_gets_project_json_0 0 "" bash "$V" "$T/wiki/kept/agent-panel/project.json"
# when the settings are already there, they are used as they are
git init -q -b main "$T/code/ready"; git -C "$T/code/ready" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
mkdir -p "$T/wiki/ready/agent-panel"; jq -n --arg r "$T/code/ready" --arg d "$T/wiki/ready" '{id:"ready",name:"Ready Made",repoPath:$r,dataDir:$d,maxParallel:3,sharedFiles:["x"]}' > "$T/wiki/ready/agent-panel/project.json"
sum=$(shasum "$T/wiki/ready/agent-panel/project.json")
expect existing_settings_reused_0 0 "project.json" bash "$C" --existing "$T/code/ready" "$T/wiki/ready" ready "Other Name" other
[ "$sum" = "$(shasum "$T/wiki/ready/agent-panel/project.json")" ] && ok existing_settings_not_rewritten || no existing_settings_not_rewritten ""
# a failure never removes a data folder that was there before
git init -q -b main "$T/code/broken"; git -C "$T/code/broken" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
mkdir -p "$T/wiki/broken/agent-panel"; echo '{"id":"broken"}' > "$T/wiki/broken/agent-panel/project.json"; echo keep > "$T/wiki/broken/keep.txt"
expect existing_invalid_settings_1 1 "not valid" bash "$C" --existing "$T/code/broken" "$T/wiki/broken" broken Broken other
[ "$(cat "$T/wiki/broken/keep.txt")" = keep ] && ok failure_keeps_old_data_folder || no failure_keeps_old_data_folder ""
# a new project still refuses an existing data folder
expect new_project_still_refuses_data_1 1 "already exists" bash "$C" "$T/code/fresh" "$T/wiki/kept" fresh Fresh other
# --- testCommand (N162) ---
expect test_command_0 0 "" bash "$C" --test-command "make test" "$T/code/tc" "$T/wiki/tc" tc Tc other
jq -e '.testCommand=="make test"' "$T/wiki/tc/agent-panel/project.json" >/dev/null && ok test_command_written || no test_command_written "$(cat "$T/wiki/tc/agent-panel/project.json")"
expect test_command_valid_0 0 "" bash "$V" "$T/wiki/tc/agent-panel/project.json"
jq -e 'has("testCommand")|not' "$P" >/dev/null && ok test_command_absent_by_default || no test_command_absent_by_default ""
expect test_command_empty_2 2 "test command" bash "$C" --test-command "" "$T/code/tc2" "$T/wiki/tc2" tc2 Tc other
expect test_command_newline_2 2 "line break" bash "$C" --test-command $'a\nb' "$T/code/tc3" "$T/wiki/tc3" tc3 Tc other
git init -q -b main "$T/code/tc4"; git -C "$T/code/tc4" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
expect test_command_existing_0 0 "" bash "$C" --existing --test-command "npm test" "$T/code/tc4" "$T/wiki/tc4" tc4 Tc other
jq -e '.testCommand=="npm test"' "$T/wiki/tc4/agent-panel/project.json" >/dev/null && ok test_command_existing_written || no test_command_existing_written ""

# --- --build-command and --no-git (N164) ---
expect build_command_0 0 "" bash "$C" --existing --build-command "npm run build" "$T/code/tc4" "$T/wiki/bc" bc Bc other
jq -e '.buildCommand=="npm run build"' "$T/wiki/bc/agent-panel/project.json" >/dev/null && ok build_command_written || no build_command_written "$(cat "$T/wiki/bc/agent-panel/project.json")"
git init -q -b main "$T/code/bx"; git -C "$T/code/bx" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
expect build_command_replaces_ios_template_0 0 "" bash "$C" --existing --build-command "xcodebuild -scheme 'Other' build" "$T/code/bx" "$T/wiki/bx" bx Bx ios Bx "iPhone 17 Pro"
jq -e '.buildCommand=="xcodebuild -scheme '"'"'Other'"'"' build" and .xcodeProject=="Bx.xcodeproj"' "$T/wiki/bx/agent-panel/project.json" >/dev/null && ok build_command_replaces_ios_template || no build_command_replaces_ios_template "$(cat "$T/wiki/bx/agent-panel/project.json")"
expect build_command_empty_2 2 "build command" bash "$C" --build-command "" "$T/code/bc2" "$T/wiki/bc2" bc2 Bc other
mkdir -p "$T/code/nogit"; echo x > "$T/code/nogit/x.txt"
expect no_git_0 0 "" bash "$C" --existing --no-git "$T/code/nogit" "$T/wiki/nogit" nogit "No Git" other
[ ! -e "$T/code/nogit/.git" ] && [ "$(ls -A "$T/code/nogit")" = x.txt ] && ok no_git_leaves_the_folder_alone || no no_git_leaves_the_folder_alone "$(ls -A "$T/code/nogit")"
expect no_git_valid_0 0 "" bash "$V" "$T/wiki/nogit/agent-panel/project.json"
expect no_git_without_existing_2 2 "--existing" bash "$C" --no-git "$T/code/nogit2" "$T/wiki/nogit2" nogit2 Ng other
expect no_git_on_a_repo_1 1 "already a git repository" bash "$C" --existing --no-git "$T/code/tc4" "$T/wiki/nogit3" nogit3 Ng other
mkdir -p "$T/code/tc4/sub"; expect no_git_inside_a_repo_1 1 "inside" bash "$C" --existing --no-git "$T/code/tc4/sub" "$T/wiki/nogit4" nogit4 Ng other
expect no_git_missing_folder_1 1 "not a folder" bash "$C" --existing --no-git "$T/code/ghost2" "$T/wiki/nogit5" nogit5 Ng other
expect no_git_with_init_git_2 2 "init-git" bash "$C" --existing --no-git --init-git --files "$T/list.txt" "$T/code/nogit" "$T/wiki/nogit6" nogit6 Ng other

# --- --init-git: an existing folder without git (N162) ---
mkdir -p "$T/code/np/src" "$T/code/np/node_modules/x"; echo a > "$T/code/np/src/a.txt"; echo b > "$T/code/np/b.txt"; echo junk > "$T/code/np/node_modules/x/j.js"; echo "node_modules/" > "$T/code/np/.gitignore"; echo secret > "$T/code/np/.env"
mkdir -p "$T/code/np/.agent-worktrees/w"; echo w > "$T/code/np/.agent-worktrees/w/f"
out=$(bash "$C" --existing --init-git --list-files "$T/code/np" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(echo "$out" | head -1)" = 4 ] && echo "$out" | grep -qx 'src/a.txt' && echo "$out" | grep -qx 'b.txt' && echo "$out" | grep -qx '.env' && echo "$out" | grep -qx '.gitignore' && ! echo "$out" | grep -q 'node_modules\|agent-worktrees' && ok list_files_count_and_paths || no list_files_count_and_paths "rc=$rc $out"
[ ! -e "$T/code/np/.git" ] && [ "$(cat "$T/code/np/.gitignore")" = "node_modules/" ] && ok list_files_writes_nothing || no list_files_writes_nothing "$(ls -A "$T/code/np")"
printf 'src/a.txt\nb.txt\n' > "$T/list.txt"
expect init_git_0 0 "" bash "$C" --existing --init-git --files "$T/list.txt" "$T/code/np" "$T/wiki/np" np Np other
[ "$(git -C "$T/code/np" rev-parse --abbrev-ref HEAD)" = main ] && [ "$(git -C "$T/code/np" log --oneline | wc -l | tr -d ' ')" = 1 ] && ok init_git_one_commit_on_main || no init_git_one_commit_on_main "$(git -C "$T/code/np" log --oneline 2>&1)"
[ "$(git -C "$T/code/np" ls-tree -r --name-only HEAD | sort | tr '\n' ' ')" = ".gitignore b.txt src/a.txt " ] && ok init_git_commits_only_confirmed_files || no init_git_commits_only_confirmed_files "$(git -C "$T/code/np" ls-tree -r --name-only HEAD | tr '\n' ' ')"
[ "$(git -C "$T/code/np" status --porcelain --ignored | grep -c '.env')" = 1 ] && [ "$(git -C "$T/code/np" ls-files .env)" = "" ] && ok init_git_leaves_unlisted_file_alone || no init_git_leaves_unlisted_file_alone ""
printf 'node_modules/\n.agent-worktrees/\n' | cmp -s - "$T/code/np/.gitignore" && ok init_git_appends_to_gitignore || no init_git_appends_to_gitignore "$(cat "$T/code/np/.gitignore")"
expect init_git_project_json_valid_0 0 "" bash "$V" "$T/wiki/np/agent-panel/project.json"
# no .gitignore yet: one is made with just the worktrees line
mkdir -p "$T/code/ng"; echo x > "$T/code/ng/x.txt"; : > "$T/list0.txt"; echo x.txt > "$T/list1.txt"
expect init_git_no_gitignore_0 0 "" bash "$C" --existing --init-git --files "$T/list1.txt" "$T/code/ng" "$T/wiki/ng" ng Ng other
[ "$(cat "$T/code/ng/.gitignore")" = ".agent-worktrees/" ] && ok init_git_creates_gitignore || no init_git_creates_gitignore "$(cat "$T/code/ng/.gitignore")"
# an empty list still makes the repository and an (empty-ish) first commit
mkdir -p "$T/code/ne"; echo x > "$T/code/ne/x.txt"
expect init_git_empty_list_0 0 "" bash "$C" --existing --init-git --files "$T/list0.txt" "$T/code/ne" "$T/wiki/ne" ne Ne other
git -C "$T/code/ne" ls-files --error-unmatch x.txt >/dev/null 2>&1 && no init_git_empty_list_stages_nothing "x.txt staged" || ok init_git_empty_list_stages_nothing
# refusals
expect init_git_without_existing_2 2 "--existing" bash "$C" --init-git --files "$T/list1.txt" "$T/code/zz" "$T/wiki/zz" zz Zz other
mkdir -p "$T/code/nf"; expect init_git_without_files_2 2 "--files" bash "$C" --existing --init-git "$T/code/nf" "$T/wiki/nf" nf Nf other
expect init_git_missing_list_2 2 "list" bash "$C" --existing --init-git --files "$T/nolist.txt" "$T/code/nf" "$T/wiki/nf" nf Nf other
expect init_git_already_repo_1 1 "already" bash "$C" --existing --init-git --files "$T/list1.txt" "$T/code/old" "$T/wiki/old9" old9 Old other
mkdir -p "$T/code/old/sub"; echo y > "$T/code/old/sub/y.txt"; echo sub/y.txt > "$T/list2.txt"
expect init_git_inside_repo_1 1 "inside" bash "$C" --existing --init-git --files "$T/list2.txt" "$T/code/old/sub" "$T/wiki/old8" old8 Old other
mkdir -p "$T/code/nt"; echo x > "$T/code/nt/x.txt"
for bad in '../x.txt' '/etc/passwd' '.git/config' 'missing.txt'; do
  echo "$bad" > "$T/listbad.txt"
  expect "init_git_bad_path_$(echo "$bad" | tr -c 'a-z' _)_2" 2 "list" bash "$C" --existing --init-git --files "$T/listbad.txt" "$T/code/nt" "$T/wiki/nt" nt Nt other
done
[ ! -e "$T/code/nt/.git" ] && [ ! -e "$T/code/nt/.gitignore" ] && [ ! -e "$T/wiki/nt" ] && ok init_git_refusals_write_nothing || no init_git_refusals_write_nothing "$(ls -A "$T/code/nt")"
# a failed commit undoes only the .git and the added line
mkdir -p "$T/code/uf"; echo x > "$T/code/uf/x.txt"; printf 'keep/\n' > "$T/code/uf/.gitignore"; echo x.txt > "$T/list3.txt"
expect init_git_failing_commit_1 1 "initial commit" env PATH="$T/bin:$PATH" bash "$C" --existing --init-git --files "$T/list3.txt" "$T/code/uf" "$T/wiki/uf" uf Uf other
[ ! -e "$T/code/uf/.git" ] && [ "$(cat "$T/code/uf/.gitignore")" = "keep/" ] && [ "$(cat "$T/code/uf/x.txt")" = x ] && [ ! -e "$T/wiki/uf" ] && ok init_git_failure_undoes_only_its_own || no init_git_failure_undoes_only_its_own "$(ls -A "$T/code/uf")"
mkdir -p "$T/code/uf2"; echo x > "$T/code/uf2/x.txt"
expect init_git_failing_commit_no_gitignore_1 1 "initial commit" env PATH="$T/bin:$PATH" bash "$C" --existing --init-git --files "$T/list3.txt" "$T/code/uf2" "$T/wiki/uf2" uf2 Uf other
[ ! -e "$T/code/uf2/.git" ] && [ ! -e "$T/code/uf2/.gitignore" ] && [ -f "$T/code/uf2/x.txt" ] && ok init_git_failure_removes_made_gitignore || no init_git_failure_removes_made_gitignore "$(ls -A "$T/code/uf2")"
finish
