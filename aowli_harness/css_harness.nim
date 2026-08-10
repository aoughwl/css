## css_harness.nim — a PROGRAM that exercises the CSS validator.
##
## This is the whole trick to "wiring aowli to the library": aowli-interp runs a
## MODULE, not a function. So we hand it a module. It imports the real library
## unchanged, calls the real public API, and prints the answers. Compile it and
## you get the reference; interpret the same .s.nif and you get the candidate.
## Byte-identical stdout is the acceptance test.
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
  check("color", "red")
  check("color", "#ff0000")
  check("color", "notacolor")
  check("width", "10px")
  check("width", "10")
  check("width", "calc(100% - 10px)")
  check("margin", "0 auto")
  check("display", "block")
  check("display", "blahblah")
  check("border", "1px solid red")
  check("font-size", "12pt")
  check("opacity", "0.5")
  check("z-index", "10")
  check("z-index", "abc")
  check("background-color", "rgb(1,2,3)")

main()
