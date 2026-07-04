import css

proc check(desc: string, got, want: bool) =
  if got == want:
    echo "  ok   " & desc
  else:
    echo "  FAIL " & desc & " (got " & $got & ", want " & $want & ")"

echo "value validation:"
check("margin 0 auto",              validateValue("margin", "0 auto").valid, true)
check("width clamp()",              validateValue("width", "clamp(1rem, 2vw, 3rem)").valid, true)
check("color hex",                  validateValue("color", "#ff0000").valid, true)
check("box-shadow inset omitted",   validateValue("box-shadow", "0 0 2px red").valid, true)
check("color reject length",        validateValue("color", "10px").valid, false)
check("margin reject bareword",     validateValue("margin", "notaword").valid, false)

echo "data tables:"
check("is property display",        isProperty("display"), true)
check("is property bogus",          isProperty("dispaly"), false)
check("pseudo-class hover",         isPseudoClass("hover"), true)
check("pseudo-element before",      isPseudoElement("before"), true)
check("functional nth-child",       isFunctionalPseudoClass("nth-child"), true)
