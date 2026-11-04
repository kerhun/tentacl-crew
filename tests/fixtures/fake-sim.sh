#!/usr/bin/env bash
# Test double for sim-for-agent.sh.
echo "sim $*" >> "${FAKE_TERM_STATE:?}/calls.log"
[ "$1" = "--remove" ] && exit 0
echo "FAKE-UDID-123"
