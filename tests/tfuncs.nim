import std/syncio
import css

var pass = 0
var fail = 0
proc t(prop, val: string, want: bool) =
  let r = validateValue(prop, val)
  if r.valid == want:
    inc pass
    echo "  ok   " & prop & ": " & val & (if not r.valid: "   [" & r.error & "]" else: "")
  else:
    inc fail
    echo "  FAIL " & prop & ": " & val & "  -> got " & $r.valid & " want " & $want &
         (if r.error.len > 0: "   [" & r.error & "]" else: "")

echo "colour functions — valid:"
t("color", "rgb(255, 0, 0)", true)
t("color", "rgb(255 0 0)", true)
t("color", "rgb(100%, 0%, 0%)", true)
t("color", "rgb(255, 0, 0, 0.5)", true)
t("color", "rgb(255 0 0 / 50%)", true)
t("color", "rgba(255, 0, 0, 0.5)", true)
t("color", "hsl(120, 50%, 50%)", true)
t("color", "hsl(120 50% 50%)", true)
t("color", "hsl(120deg 50% 50% / 0.5)", true)
t("color", "hwb(120 30% 40%)", true)

echo "colour functions — INVALID (the gaps):"
t("color", "rgb(1, 2)", false)              # too few
t("color", "rgb(1, 2, 3, 4, 5)", false)     # too many
t("color", "hsl(120)", false)               # too few
t("color", "rgb()", false)                  # empty
t("color", "notafunction(1, 2)", false)     # unknown function

echo "math inside colour (builds up):"
t("color", "rgb(calc(200 + 55), 0, 0)", true)
t("color", "hsl(calc(60 * 2), 50%, 50%)", true)

echo "gradients — valid:"
t("background", "linear-gradient(45deg, red, blue)", true)
t("background", "linear-gradient(to right, red, blue)", true)
t("background", "linear-gradient(red, blue)", true)
t("background-image", "radial-gradient(circle, red, blue)", true)

echo "transforms — valid:"
t("transform", "translate(10px, 20px)", true)
t("transform", "translateX(10px)", true)
t("transform", "scale(1.5)", true)
t("transform", "scale(1.5, 2)", true)
t("transform", "rotate(45deg)", true)
t("transform", "matrix(1, 0, 0, 1, 0, 0)", true)
t("transform", "translate(10px, 20px) rotate(45deg) scale(2)", true)

echo "transforms — INVALID:"
t("transform", "translate()", false)             # needs at least 1
t("transform", "scale(1, 2, 3)", false)          # too many
t("transform", "rotate(45deg, 90deg)", false)    # too many

echo "timing (inline-defined funcs) — valid:"
t("transition-timing-function", "cubic-bezier(0.1, 0.7, 1, 0.1)", true)
t("transition-timing-function", "steps(4, end)", true)
t("animation-timing-function", "ease-in-out", true)

echo "var()/env() substitution — valid (dynamic):"
t("width", "var(--w)", true)
t("width", "var(--w, 10px)", true)
t("width", "calc(var(--w) + 10px)", true)
t("margin", "var(--m, 0 auto)", true)

echo "nested unknown inside a known function — INVALID:"
t("background", "linear-gradient(45deg, notacolor-fn(1), blue)", false)

echo ""
echo "PASS " & $pass & "   FAIL " & $fail
