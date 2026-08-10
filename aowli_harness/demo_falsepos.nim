## demo_falsepos.nim — exercises validateValue for the debugging case study.
import std/syncio
import ../css/validator

proc check(prop, value: string) =
  let r = validateValue(prop, value)
  write stdout, prop
  write stdout, " | "
  write stdout, value
  write stdout, " | "
  write stdout, (if r.valid: "VALID" else: "INVALID")
  write stdout, " | "
  write stdout, r.error
  write stdout, "\n"

proc main() =
  check("color", "red")         # one color — VALID
  check("color", "red green")   # two colors for `color` — must be INVALID

main()
