#!/usr/bin/env bash
# Stands in for stop-agent.sh: records its arguments.
echo "$*" >> "$FAKE_STOP_LOG"
