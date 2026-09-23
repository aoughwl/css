import std/[syncio, math]
import css

var fails = 0
proc eq(desc, got, want: string) =
  if got == want: echo "  ok   " & desc & " = " & got
  else:
    inc fails
    echo "  FAIL " & desc & ": got [" & got & "] want [" & want & "]"

proc near(desc: string, c: tuple[ok: bool, color: Color], r, g, b: float, tol = 1.5) =
  let ok = c.ok and abs(c.color.r - r) <= tol and abs(c.color.g - g) <= tol and abs(c.color.b - b) <= tol
  if ok: echo "  ok   " & desc & " ≈ " & serializeColor(c.color)
  else:
    inc fails
    echo "  FAIL " & desc & ": got ok=" & $c.ok & " " & serializeColor(c.color) & " want ≈ (" & $r & ", " & $g & ", " & $b & ")"

proc bad(s: string) =
  if not parseColor(s).ok: echo "  ok   rejects " & s
  else:
    inc fails
    echo "  FAIL accepted " & s

echo "named / hex / system:"
eq("148 named colours",          $namedColors().len, "148")
eq("aliceblue (first entry)",    normalizeColor("aliceblue"), "rgb(240, 248, 255)")
eq("rebeccapurple",              normalizeColor("rebeccapurple"), "rgb(102, 51, 153)")
eq("Red (case)",                 normalizeColor("Red"), "rgb(255, 0, 0)")
eq("transparent",                normalizeColor("transparent"), "rgba(0, 0, 0, 0)")
eq("#abc",                       normalizeColor("#abc"), "rgb(170, 187, 204)")
eq("#abcd",                      normalizeColor("#abcd"), "rgba(170, 187, 204, 0.867)")
eq("#336699",                    normalizeColor("#336699"), "rgb(51, 102, 153)")
eq("#33669980",                  normalizeColor("#33669980"), "rgba(51, 102, 153, 0.502)")
eq("CanvasText",                 normalizeColor("CanvasText"), "rgb(0, 0, 0)")
eq("currentcolor passes",        normalizeColor("currentColor"), "currentcolor")
eq("not a colour passes",        normalizeColor("10px"), "10px")

echo "rgb / hsl / hwb:"
eq("rgb legacy",                 normalizeColor("rgb(255, 0, 0)"), "rgb(255, 0, 0)")
eq("rgba legacy",                normalizeColor("rgba(0, 0, 0, .5)"), "rgba(0, 0, 0, 0.5)")
eq("rgb modern / alpha",         normalizeColor("rgb(0 128 255 / 25%)"), "rgba(0, 128, 255, 0.25)")
eq("rgb percentages",            normalizeColor("rgb(100% 50% 0%)"), "rgb(255, 128, 0)")
eq("rgb clamps",                 normalizeColor("rgb(300 -5 0)"), "rgb(255, 0, 0)")
eq("rgb none",                   normalizeColor("rgb(none 255 0)"), "rgb(0, 255, 0)")
eq("hsl modern",                 normalizeColor("hsl(210 50% 40%)"), "rgb(51, 102, 153)")
eq("hsl legacy",                 normalizeColor("hsl(120, 100%, 50%)"), "rgb(0, 255, 0)")
eq("hsla",                       normalizeColor("hsla(0, 100%, 50%, 0.3)"), "rgba(255, 0, 0, 0.3)")
eq("hsl turn",                   normalizeColor("hsl(0.5turn 100% 50%)"), "rgb(0, 255, 255)")
eq("hwb",                        normalizeColor("hwb(120 20% 20%)"), "rgb(51, 204, 51)")
eq("hwb gray",                   normalizeColor("hwb(0 60% 60%)"), "rgb(128, 128, 128)")
bad("rgb(255, 0)")
bad("rgb(255 0 0 0)")
bad("rgb(255, 50%, 0)")
bad("hsl(10, 50, 50)")
bad("#12345")
bad("notacolor")

echo "modern spaces (converted for the API; serialised as written):"
near("oklch red",                parseColor("oklch(62.8% 0.2577 29.23)"), 255.0, 0.0, 0.0)
near("oklab red",                parseColor("oklab(0.628 0.2249 0.1258)"), 255.0, 0.0, 0.0)
near("lab red",                  parseColor("lab(54.29% 80.82 69.9)"), 255.0, 0.0, 0.0)
near("lch red",                  parseColor("lch(54.29 106.84 40.85)"), 255.0, 0.0, 0.0)
near("lab white",                parseColor("lab(100 0 0)"), 255.0, 255.0, 255.0)
near("color(srgb)",              parseColor("color(srgb 1 0.5 0)"), 255.0, 127.5, 0.0)
near("color(srgb-linear)",       parseColor("color(srgb-linear 0.214 0.214 0.214)"), 128.0, 128.0, 128.0)
near("color(display-p3) green",  parseColor("color(display-p3 0.4584 0.9853 0.2983)"), 0.0, 255.0, 0.0, 3.0)
near("color(xyz-d65) white",     parseColor("color(xyz-d65 0.9505 1 1.089)"), 255.0, 255.0, 255.0)
eq("oklch keeps its space",      normalizeColor("oklch(70% 0.1 200)"), "oklch(70% 0.1 200)")

echo "color-mix:"
near("srgb red+blue",            parseColor("color-mix(in srgb, red, blue)"), 127.5, 0.0, 127.5)
near("srgb 25%",                 parseColor("color-mix(in srgb, red 25%, blue)"), 63.75, 0.0, 191.25)
near("srgb-linear",              parseColor("color-mix(in srgb-linear, black, white)"), 188.0, 188.0, 188.0)
near("oklab black/white",        parseColor("color-mix(in oklab, black, white)"), 99.0, 99.0, 99.0, 2.0)
near("hsl hue short way",        parseColor("color-mix(in hsl, hsl(350 100% 50%), hsl(10 100% 50%))"), 255.0, 0.0, 0.0)
let tr = parseColor("color-mix(in srgb, red 20%, blue 20%)")
eq("sum < 100% scales alpha",    serializeColor(tr.color), "rgba(128, 0, 128, 0.4)")

echo "contrast:"
eq("white/black 21",             $int(round(contrastRatio(parseColor("white").color, parseColor("black").color))), "21")
let cr = contrastRatio(parseColor("#777").color, parseColor("#fff").color)
eq("#777 on white ≈ 4.48",       $(int(round(cr * 100.0))), "448")
eq("toHex",                      toHex(parseColor("rebeccapurple").color), "#663399")

echo (if fails == 0: "color: all ok" else: "color: " & $fails & " FAIL")
