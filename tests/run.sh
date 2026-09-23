#!/usr/bin/env bash
# tests/run.sh [name...] — build + run each tests/t*.nim under nimony; prints one line per test.
# Exit 1 if any test fails to build, exits non-zero, or prints FAIL.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
NIMONY=${NIMONY:-/home/savant/nimony/bin/nimony}
PLUGIN=${PLUGIN:-$root/../aoughwl-plugin}
cd "$here"
names=("$@")
[ ${#names[@]} -eq 0 ] && names=($(ls t*.nim | sed 's/\.nim$//'))
rc=0
for n in "${names[@]}"; do
  n=${n%.nim}
  log=$(mktemp)
  if ! timeout 240 "$NIMONY" c --path:"$root" --path:"$PLUGIN" -o:"nimcache/$n.bin" "$n.nim" >"$log" 2>&1 || [ ! -x "nimcache/$n.bin" ]; then
    echo "BUILD-FAIL $n"; grep -E 'Error|error' "$log" | head -5; rc=1; rm -f "$log"; continue
  fi
  out=$(timeout 60 "./nimcache/$n.bin" 2>&1); code=$?
  if [ $code -ne 0 ] || grep -E 'FAIL' <<<"$out" | grep -qvE 'FAIL 0\b'; then
    echo "FAIL $n (exit $code)"; grep -E 'FAIL' <<<"$out" | grep -vE 'FAIL 0\b' | head -20; rc=1
  else
    echo "ok   $n  $(tail -1 <<<"$out")"
  fi
  rm -f "$log"
done
exit $rc
