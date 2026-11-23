#!/bin/sh
# Runs tests/e2e.lua inside the running Hammerspoon (needs require("hs.ipc")
# in init.lua). Takes over focus, the mouse and the primary screen's space
# for about half a minute once the user has been idle for 15 seconds.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
[ build/RetileFixture -nt tests/fixture/RetileFixture.swift ] || swiftc -O tests/fixture/RetileFixture.swift -o build/RetileFixture
rm -f build/e2e.out
# The test runs asynchronously and writes build/e2e.out when done.
# Without </dev/null, hs keeps reading commands from a piped stdin and stays
# connected.
perl -e 'alarm 20; exec @ARGV' hs -c "dofile('$PWD/tests/e2e.lua')" </dev/null
i=0
while [ ! -f build/e2e.out ] && [ $i -lt 150 ]; do sleep 2; i=$((i + 1)); done
cat build/e2e.out
grep -q '^PASS' build/e2e.out
