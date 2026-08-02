## tools/run_validate.nim — a tiny driver that EXERCISES the css validator so the
## interpreter can watch it run. We validate a handful of property:value pairs
## that reach different corners of the grammar (a keyword, a type ref, an
## alternation, a list). Nothing here names a rule — the rules live in the
## validator's dispatch, and firing it is all we do.

import std/syncio
import ../validator

proc try2(prop, value: string) =
  let ok = valueMatches(prop, value)
  echo prop, ": ", value, "  ->  ", ok

when isMainModule:
  try2("color", "red")
  try2("color", "10px")
  try2("display", "flex")
  try2("margin", "10px 20px")
  try2("border", "1px solid black")
