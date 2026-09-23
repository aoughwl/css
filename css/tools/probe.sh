#!/usr/bin/env bash
# css/tools/probe.sh ARGS… — (re)build cssprobe when any css source is newer, then run it.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bin="$here/nimcache/cssprobe"
NIMONY=${NIMONY:-/home/savant/nimony/bin/nimony}
if [ ! -x "$bin" ] || [ -n "$(find "$root/css" "$root/css.nim" -name '*.nim' -newer "$bin" 2>/dev/null | head -1)" ]; then
  mkdir -p "$here/nimcache"
  (cd "$here" && timeout 240 "$NIMONY" c --path:"$root" -o:"nimcache/cssprobe" cssprobe.nim >"$here/nimcache/build.log" 2>&1) \
    || { grep -E 'Error' "$here/nimcache/build.log" | head -5; exit 1; }
fi
exec "$bin" "$@"
