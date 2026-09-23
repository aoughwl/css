## tquickstart — the docs' quickstart (aoughwl.github.io/docs/css), checked.
## Every `want` below is printed in the docs; if one changes, change both.
import std/syncio
import css

var fails = 0
proc doc(got, want: string) =
  if got == want: echo "  ok   " & got
  else:
    inc fails
    echo "  FAIL got [" & got & "] want [" & want & "]"

doc($validateValue("width", "clamp(1rem, 2vw, 3rem)").valid, "true")
doc(validateValue("width", "clamp(1rem, 2vw)").error, "clamp() expects 3 arguments, got 2")
doc($validateValue("padding", "-5px").valid, "false")
doc($validateValue("width", "rgb(0 0 0)").valid, "false")
doc($validateSelector("li:nth-child(2n+1 of .item):not(:has(> a))").valid, "true")
doc($validateMediaQueryList("(400px <= width < 700px), print").valid, "true")
doc(validateMediaQueryList("(min-widht: 600px)").error, "unknown media feature 'min-widht'")
doc($validateDescriptor("@font-face", "unicode-range", "U+0-7F, U+4??").valid, "true")

let site = """h1 { color: red; }
@layer theme { .card .title { color: #336699 } }
.card { font-size: 1.25em; }
.card .title { font-size: 2em; }
p { colr: red }
"""
let ds = lintStylesheet(site)
doc($ds.len, "1")
if ds.len > 0: doc($ds[0], "5: error: colr is not a known CSS property   [colr: red]")

let d = elem("html",
  elem("body.dark",
    elem("div#app.card[style=\"padding: 2px\"]",
      elem("h1.title"), elem("p.lead"))))
let eng = newStyleEngine()
eng.addUserAgentDefaults()
eng.addStylesheet(site, oAuthor, "site.css")
let h1 = querySelector(d, "h1")
if h1 == nil:
  inc fails
  echo "  FAIL no h1"
else:
  let cs = eng.computedStyle(h1)
  doc(cs.get("color"), "rgb(255, 0, 0)")
  doc(cs.get("font-size"), "40px")
  doc(cs.get("margin-top"), "26.8px")
  doc(eng.why(h1, "color"),
      "color: red  from h1 (site.css:1)  [author, specificity (0,0,1)]\n" &
      "  beats #336699  from .card .title (site.css:2) @layer theme  [author, specificity (0,2,0)]")
doc(minifyStylesheet("a { color: #ff0000; margin: 0px auto; }"), "a{color:red;margin:0 auto}")
doc(normalizeColor("hsl(210 50% 40%)"), "rgb(51, 102, 153)")

echo (if fails == 0: "quickstart: all ok" else: "quickstart: " & $fails & " FAIL")
