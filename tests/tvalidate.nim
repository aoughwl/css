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

echo "function slots are TYPED (a function is not a wildcard):"
check("width: rgb() rejected",      validateValue("width", "rgb(0 0 0)").valid, false)
check("width: calc() accepted",     validateValue("width", "calc(100% - 2px)").valid, true)
check("color: calc() rejected",     validateValue("color", "calc(1px + 2px)").valid, false)
check("color: rgba() accepted",     validateValue("color", "rgba(0, 0, 0, .5)").valid, true)
check("bg-image: url()",            validateValue("background-image", "url(a.png)").valid, true)
check("bg-image: gradient",         validateValue("background-image", "linear-gradient(red, blue)").valid, true)
check("bg-image: rgb() rejected",   validateValue("background-image", "rgb(0 0 0)").valid, false)
check("inline fit-content(len)",    validateValue("width", "fit-content(20em)").valid, true)
check("inline fit-content(red)",   validateValue("width", "fit-content(red)").valid, false)
check("grid repeat() accepted",     validateValue("grid-template-columns", "repeat(3, 1fr)").valid, true)
check("transform: two fns",         validateValue("transform", "translate(10px, 20px) rotate(45deg)").valid, true)
check("transform: rgb() rejected",  validateValue("transform", "rgb(1 2 3)").valid, false)

echo "numeric ranges from the grammar (<length [0,∞]>):"
check("padding: -5px rejected",     validateValue("padding", "-5px").valid, false)
check("padding: 5px",               validateValue("padding", "5px").valid, true)
check("margin: -5px (unbounded)",   validateValue("margin", "-5px").valid, true)
check("padding: calc(-5px) kept",   validateValue("padding", "calc(0px - 5px)").valid, true)
check("opacity .5",                 validateValue("opacity", ".5").valid, true)

echo "literal tokens and custom idents:"
check("grid line names [a] 1fr",    validateValue("grid-template-columns", "[full-start] 1fr [full-end]").valid, true)
check("animation-name: inherit",    validateValue("animation-name", "inherit").valid, true)
check("counter-reset: default bad", validateValue("counter-reset", "default").valid, false)
check("custom property anything",   validateValue("--x", "{ a b }").valid, true)
check("uppercase property name",    validateValue("COLOR", "red").valid, true)

echo "validateAgainst / descriptors:"
check("<length> | auto : 10px",     validateAgainst("<length> | auto", "10px").valid, true)
check("<length> | auto : red",      validateAgainst("<length> | auto", "red").valid, false)
check("no CSS-wide keyword",        validateAgainst("<length>", "inherit").valid, false)
check("font-face font-display",     validateDescriptor("@font-face", "font-display", "swap").valid, true)
check("font-face font-display bad", validateDescriptor("@font-face", "font-display", "fast").valid, false)
check("font-face src",              validateDescriptor("@font-face", "src", "url(a.woff2) format(\"woff2\"), local(Arial)").valid, true)
check("font-face unicode-range",    validateDescriptor("@font-face", "unicode-range", "U+0000-00FF, U+0131, U+4??").valid, true)
check("font-face unicode-range bad",validateDescriptor("@font-face", "unicode-range", "0000-00FF").valid, false)
check("font-face not a descriptor", validateDescriptor("@font-face", "color", "red").valid, false)
check("descriptor !important",      validateDescriptor("@font-face", "font-display", "swap !important").valid, false)
check("counter-style system",       validateDescriptor("@counter-style", "system", "fixed 3").valid, true)
check("property inherits",          validateDescriptor("@property", "inherits", "false").valid, true)
