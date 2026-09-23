## cssprobe — ask the library one question from the shell.
##
##   css/tools/probe.sh <prop> <value>              validate a declaration value
##   css/tools/probe.sh -d <@rule> <desc> <value>   validate an at-rule descriptor
##   css/tools/probe.sh -x <syntax> <value>         validate against any grammar
##   css/tools/probe.sh -s <selector>               validate a selector (+ specificity)
import std/[syncio, cmdline]
import ../../css

proc show(r: tuple[valid: bool, error: string]) =
  if r.valid: echo "valid"
  else: echo "INVALID: " & r.error

let n = paramCount()
if n >= 4 and paramStr(1) == "-d":
  show validateDescriptor(paramStr(2), paramStr(3), paramStr(4))
elif n >= 3 and paramStr(1) == "-x":
  show validateAgainst(paramStr(2), paramStr(3))
elif n >= 2 and paramStr(1) == "-s":
  show validateSelector(paramStr(2))
  echo "specificity " & $specificity(paramStr(2))
elif n >= 2:
  show validateValue(paramStr(1), paramStr(2))
else:
  echo "usage: cssprobe <prop> <value> | -d @rule desc value | -x syntax value | -s selector"
  quit(2)
