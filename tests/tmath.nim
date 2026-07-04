import std/syncio
import css

var pass = 0
var fail = 0
proc t(val: string, want: bool) =
  let r = validateValue("width", val)
  if r.valid == want:
    inc pass
    echo "  ok   " & val & (if not r.valid: "   [" & r.error & "]" else: "")
  else:
    inc fail
    echo "  FAIL " & val & "  -> got " & $r.valid & " want " & $want &
         (if r.error.len > 0: "   [" & r.error & "]" else: "")

echo "math functions — valid (the value builds on itself):"
t("clamp(1rem, 2vw, 3rem)", true)
t("calc(100% - 20px)", true)
t("calc(1px + 2px * 3 - 4px / 2)", true)
t("calc(-5px + 10px)", true)
t("calc((1px + 2px) * 3)", true)
t("calc(2 * (10px + 5px))", true)
t("calc(pi * 2px)", true)
t("min(10px, 5vw)", true)
t("max(1px, 2px, 3px, 4px)", true)
t("clamp(calc(1rem + 2px), min(50%, 10vw), max(3rem, 5vh))", true)
t("clamp(1px, 50%, calc(min(2rem, 3vw) + 1px))", true)
t("calc(var(--x) + 10px)", true)
t("hypot(3px, 4px)", true)
t("round(up, 10px, 4px)", true)
t("round(10px, 4px)", true)
t("mod(10px, 3px)", true)
t("abs(-5px)", true)
t("calc( 1px + 2px )", true)

echo "math functions — invalid (precise errors):"
t("clamp(1rem, 2vw)", false)         # arity
t("clamp(1px)", false)               # arity
t("clamp(1, 2, 3, 4)", false)        # arity
t("min()", false)                    # empty
t("mod(10px)", false)                # arity
t("calc()", false)                   # empty
t("calc(100% - )", false)            # trailing operator
t("calc(1px +)", false)              # trailing operator
t("calc(+ 1px)", false)              # leading operator
t("calc(1px 2px)", false)            # missing operator
t("calc(1px + * 2px)", false)        # doubled operator
t("calc((1px + 2px)", false)         # unbalanced parens
t("min(1px,)", false)                # empty trailing arg

echo ""
echo "PASS " & $pass & "   FAIL " & $fail
