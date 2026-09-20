import std/syncio
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

echo "!important (belongs to the DECLARATION, not to any value grammar):"
check("cursor !important",          validateValue("cursor", "row-resize !important").valid, true)
check("cursor bare (control)",      validateValue("cursor", "row-resize").valid, true)
check("display !important",         validateValue("display", "none !important").valid, true)
check("case-insensitive",           validateValue("display", "none !IMPORTANT").valid, true)
check("space after the bang",       validateValue("display", "none ! important").valid, true)
# The two directions that keep the strip from becoming a blanket "ends in a
# word => accept": a TYPO must still fail, and so must a bad value that happens
# to carry a valid !important. Without these, `return (value, false)` could be
# `return ("", true)` and every assert above would still pass.
check("typo !importnat rejected",   validateValue("display", "none !importnat").valid, false)
check("bad value + !important",     validateValue("color", "10px !important").valid, false)
check("bare word 'important'",      validateValue("display", "important").valid, false)

echo "data tables:"
check("is property display",        isProperty("display"), true)
check("is property bogus",          isProperty("dispaly"), false)
check("pseudo-class hover",         isPseudoClass("hover"), true)
check("pseudo-element before",      isPseudoElement("before"), true)
check("functional nth-child",       isFunctionalPseudoClass("nth-child"), true)

echo "hex colours:"
# A hash token is not a colour. `#ff` and `#main` both lex as one, and
# accepting them meant `color: #ff` validated - two hex digits is not a
# colour in any CSS, and a renderer trusting this paints something arbitrary
# instead of skipping the declaration. Found by cross-checking against one.
check("#ff is not a colour",        validateValue("color", "#ff").valid, false)
check("#f is not a colour",         validateValue("color", "#f").valid, false)
check("#fffff is not a colour",     validateValue("color", "#fffff").valid, false)
check("#fffffff is not a colour",   validateValue("color", "#fffffff").valid, false)
check("#main is not a colour",      validateValue("color", "#main").valid, false)
check("non-hex digits rejected",    validateValue("color", "#12345g").valid, false)
check("#fff",                       validateValue("color", "#fff").valid, true)
check("#FFF uppercase",             validateValue("color", "#FFF").valid, true)
check("#ffff with alpha",           validateValue("color", "#ffff").valid, true)
check("#ff0000",                    validateValue("color", "#ff0000").valid, true)
check("#FF0000FF with alpha",       validateValue("color", "#FF0000FF").valid, true)
check("hex inside a shorthand",     validateValue("border", "1px solid #ccc").valid, true)
