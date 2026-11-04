#!/usr/bin/env bash
# Usage: relaunch-app.sh <app path> <pid>
# Waits until process <pid> is gone (at most 30 s; RELAUNCH_WAIT_SECS overrides, for tests), then opens the app once.
# The panel starts this detached and quits itself, so the new copy opens after the old one is gone.
usage() { echo "usage: relaunch-app.sh <app path> <pid>" >&2; exit 2; }
[ $# -eq 2 ] || usage
app=$1 pid=$2
case "$pid" in ''|*[!0-9]*) usage ;; esac
[ -d "$app" ] || { echo "ERROR: $app not found" >&2; exit 1; }
limit=${RELAUNCH_WAIT_SECS:-30}
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do sleep 1; waited=$((waited+1)); done
exec open "$app"
