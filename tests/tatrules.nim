import std/syncio
import css
import css/atrules

var fails = 0
proc check(desc: string, r: tuple[valid: bool, error: string], want: bool) =
  if r.valid == want:
    echo "  ok   " & desc & (if r.valid: "" else: "   [" & r.error & "]")
  else:
    inc fails
    echo "  FAIL " & desc & " (got " & $r.valid & ", want " & $want & ")  " & r.error

proc media(q: string, want: bool) = check("@media " & q, validateMediaQueryList(q), want)
proc supp(q: string, want: bool) = check("@supports " & q, validateSupportsCondition(q), want)
proc cont(q: string, want: bool) = check("@container " & q, validateContainerCondition(q), want)
proc at(kw, p: string, want: bool, blk = true) =
  check("@" & kw & " " & p & (if blk: " {}" else: ";"), validateAtRulePrelude(kw, p, blk), want)

echo "@media — valid:"
for q in ["screen", "print", "all and (min-width: 600px)", "(max-width: 767.98px)",
          "only screen and (orientation: landscape)", "not print",
          "screen, print", "(width >= 600px)", "(400px <= width < 700px)",
          "(1024px > width)", "(min-resolution: 2dppx)", "(resolution: infinite)",
          "(prefers-color-scheme: dark)", "(prefers-reduced-motion: reduce)",
          "(hover: hover) and (pointer: fine)", "(color)", "(grid: 0)",
          "not (hover)", "((width > 1px) and (height > 1px)) or (orientation: portrait)",
          "(-webkit-min-device-pixel-ratio: 2)", "(min--moz-device-pixel-ratio: 2)",
          "(aspect-ratio: 16/9)", "(min-aspect-ratio: 4 / 3)", "(min-width: calc(40em + 1px))",
          "", "screen and (min-width: 0)"]:
  media(q, true)
echo "@media — invalid:"
for q in ["(min-widht: 600px)", "(orientation: sideways)", "(min-orientation: portrait)",
          "(width: red)", "screen and", "screen or (color)", "(width > 1px) and (x)",
          "(width > 1px) and (height > 1px) or (color)", "tablet", "(400px > width < 700px)",
          "(min-width >= 600px)", "(orientation > portrait)", "(color: -1)", "screen,",
          "and (color)", "(aspect-ratio: 16/)"]:
  media(q, false)

echo "@supports:"
for q in ["(display: grid)", "not (display: grid)", "(display: grid) and (gap: 1em)",
          "((position: -webkit-sticky) or (position: sticky))", "selector(:has(a))",
          "font-tech(color-COLRv1)", "(--x: 1)", "(display: flex) or (display: grid)"]:
  supp(q, true)
for q in ["display: grid", "(display)", "(display: grid) and (gap: 1em) or (x: y)",
          "selector(:bogus)", "", "foo(bar)", "(display:)"]:
  supp(q, false)

echo "@container:"
for q in ["(min-width: 400px)", "card (width > 30em)", "sidebar", "style(--dark: true)",
          "card (inline-size > 30em) and style(--responsive: true)",
          "not (width < 10px)", "scroll-state(stuck: top)", "(orientation: portrait)"]:
  cont(q, true)
for q in ["(min-widht: 1px)", "none (width > 1px)", "(color)", "style(colour: red)",
          "style(color: 10px)", ""]:
  cont(q, false)

echo "other at-rules:"
at("import", "url(a.css)", true, false)
at("import", "\"a.css\" screen", true, false)
at("import", "url(a.css) layer(base) supports(display: grid) screen and (min-width: 1px)", true, false)
at("import", "url(a.css) layer", true, false)
at("import", "url(a.css) layer(1bad)", false, false)
at("import", "a.css", false, false)
at("import", "url(a.css)", false, true)
at("layer", "base, components.cards", true, false)
at("layer", "base", true, true)
at("layer", "", true, true)
at("layer", "", false, false)
at("layer", "a b", false, true)
at("layer", "a..b", false, false)
at("keyframes", "spin", true)
at("keyframes", "\"my anim\"", true)
at("keyframes", "none", false)
at("keyframes", "a b", false)
at("-webkit-keyframes", "spin", true)
at("font-face", "", true)
at("font-face", "x", false)
at("page", ":first", true)
at("page", "wide:left, :blank", true)
at("page", ":middle", false)
at("namespace", "svg url(http://www.w3.org/2000/svg)", true, false)
at("namespace", "\"http://x\"", true, false)
at("namespace", "svg", false, false)
at("charset", "\"UTF-8\"", true, false)
at("charset", "'UTF-8'", false, false)
at("counter-style", "thumbs", true)
at("counter-style", "decimal", false)
at("counter-style", "none", false)
at("property", "--brand", true)
at("property", "brand", false)
at("scope", "(.card) to (.content)", true)
at("scope", "(.card)", true)
at("scope", "(:bogus)", false)
at("font-feature-values", "Font One, \"Font Two\"", true)
at("starting-style", "", true)
at("media", "screen", false, false)
at("bogus-rule", "", false)
at("-moz-document", "url-prefix()", true)

echo "keyframe selectors:"
check("from", validateKeyframeSelector("from"), true)
check("0%, 50%", validateKeyframeSelector("0%, 50%"), true)
check("entry 10%", validateKeyframeSelector("entry 10%"), true)
check("150%", validateKeyframeSelector("150%"), false)
check("middle", validateKeyframeSelector("middle"), false)
check("50", validateKeyframeSelector("50"), false)

echo (if fails == 0: "atrules: all ok" else: "atrules: " & $fails & " FAIL")
