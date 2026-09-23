import std/syncio
import css
import css/media

var fails = 0
proc check(desc: string, got, want: bool) =
  if got == want: echo "  ok   " & desc
  else:
    inc fails
    echo "  FAIL " & desc & " (got " & $got & ", want " & $want & ")"

var env = defaultEnv()          # screen 1280x720, light, 1dppx, hover, fine
proc m(q: string, want: bool) = check("@media " & q, evalMediaQueryList(q, env), want)

echo "desktop 1280x720:"
m("", true)
m("all", true)
m("screen", true)
m("print", false)
m("not print", true)
m("only screen", true)
m("(min-width: 600px)", true)
m("(max-width: 600px)", false)
m("(min-width: 1280px)", true)
m("(min-width: 1281px)", false)
m("(width >= 1280px)", true)
m("(width > 1280px)", false)
m("(600px <= width <= 1400px)", true)
m("(1400px > width > 600px)", true)
m("(1200px < width < 1270px)", false)
m("(min-width: 40em)", true)
m("(max-width: 79.99rem)", false)
m("(orientation: landscape)", true)
m("(orientation: portrait)", false)
m("(min-aspect-ratio: 16/9)", true)
m("(aspect-ratio: 16/9)", true)
m("(min-resolution: 2dppx)", false)
m("(min-resolution: 96dpi)", true)
m("(hover: hover) and (pointer: fine)", true)
m("(hover: none)", false)
m("(prefers-color-scheme: dark)", false)
m("(prefers-reduced-motion: no-preference)", true)
m("(prefers-reduced-motion)", false)
m("(hover)", true)
m("(color)", true)
m("(monochrome)", false)
m("(color-gamut: srgb)", true)
m("(color-gamut: p3)", false)
m("not (hover: none)", true)
m("screen and (max-width: 600px), print", false)
m("screen and (max-width: 600px), (min-width: 1000px)", true)
m("(min-widht: 1px)", false)
m("tv, screen", true)
m("screen and (min-width: 600px) and (max-width: 1400px)", true)
m("((min-width: 600px) and (max-width: 700px)) or (orientation: landscape)", true)

echo "phone 375x812 dark coarse 3dppx:"
env.width = 375.0
env.height = 812.0
env.colorScheme = "dark"
env.hover = false
env.pointer = "coarse"
env.resolution = 3.0
m("(max-width: 600px)", true)
m("(orientation: portrait)", true)
m("(prefers-color-scheme: dark)", true)
m("(hover: none) and (pointer: coarse)", true)
m("(-webkit-min-device-pixel-ratio: 2)", true)
m("(-webkit-min-device-pixel-ratio: 4)", false)
m("(min--moz-device-pixel-ratio: 2)", true)
m("(min-resolution: 2dppx)", true)
m("(min-resolution: 192dpi)", true)
m("screen and (min-width: 576px)", false)

echo "print:"
env.mediaType = "print"
m("print", true)
m("screen", false)
m("not screen", true)
m("(overflow-block: paged)", true)

echo "@supports:"
check("(display: grid)",                  evalSupports("(display: grid)"), true)
check("(display: gridd)",                 evalSupports("(display: gridd)"), false)
check("not (display: gridd)",             evalSupports("not (display: gridd)"), true)
check("(display: grid) and (gap: 1em)",   evalSupports("(display: grid) and (gap: 1em)"), true)
check("(x: y) or (color: red)",           evalSupports("(x: y) or (color: red)"), true)
check("selector(:has(a))",                evalSupports("selector(:has(a))"), true)
check("selector(:bogus)",                 evalSupports("selector(:bogus)"), false)
check("font-format(woff2)",               evalSupports("font-format(woff2)"), true)
check("(--x: 1)",                         evalSupports("(--x: 1)"), true)
check("garbage",                          evalSupports("display: grid"), false)

echo (if fails == 0: "media: all ok" else: "media: " & $fails & " FAIL")
