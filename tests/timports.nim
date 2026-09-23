import std/[syncio, tables]
import css

var fails = 0
proc check(desc: string, got, want: bool) =
  if got == want: echo "  ok   " & desc
  else:
    inc fails
    echo "  FAIL " & desc

proc contains(s, p: string): bool =
  var i = 0
  while i + p.len <= s.len:
    var j = 0
    while j < p.len and s[i+j] == p[j]: inc j
    if j == p.len: return true
    inc i
  false

var files = initTable[string, string]()
files["css/main.css"] = """@charset "UTF-8";
@layer reset, base;
@import url(parts/reset.css) layer(reset);
@import "parts/base.css" layer(base) supports(display: grid) screen and (min-width: 1px);
@import 'missing.css';
@import url("parts/loop.css");
body { color: red }
@import url(late.css);
"""
files["css/parts/reset.css"] = "* { margin: 0 }"
files["css/parts/base.css"] = "@charset \"UTF-8\";\n@import \"../shared/vars.css\";\nh1 { font-size: 2em }"
files["css/shared/vars.css"] = ":root { --x: 1 }"
files["css/parts/loop.css"] = "@import url(../main.css);\n.loop { color: blue }"

proc load(url: string): tuple[ok: bool, css: string] =
  if files.hasKey(url): (true, files.getOrDefault(url, "")) else: (false, "")

let r = resolveImports(files.getOrDefault("css/main.css", ""), "css/main.css", load)
echo r.css
for p in r.problems: echo "  problem: " & p

echo "resolution:"
check("url resolved relative",            resolveUrl("css/main.css", "parts/a.css") == "css/parts/a.css", true)
check("../ folds",                        resolveUrl("css/parts/base.css", "../shared/v.css") == "css/shared/v.css", true)
check("absolute kept",                    resolveUrl("css/a.css", "https://x/y.css") == "https://x/y.css", true)
check("root-relative kept",               resolveUrl("css/a.css", "/y.css") == "/y.css", true)
check("reset inlined in @layer reset",    r.css.contains("@layer reset {\n* { margin: 0 }"), true)
check("base wrapped media>supports>layer", r.css.contains("@media screen and (min-width: 1px) {\n@supports (display: grid) {\n@layer base {"), true)
check("nested import inlined",            r.css.contains(":root { --x: 1 }"), true)
check("nested @charset dropped",          r.css.contains("@layer base {\n@charset"), false)
check("own @charset kept",                r.css.contains("@charset \"UTF-8\";"), true)
check("layer statement kept",             r.css.contains("@layer reset, base;"), true)
check("body rule kept",                   r.css.contains("body { color: red }"), true)
check("loop body kept once",              r.css.contains(".loop { color: blue }"), true)
check("files listed",                     r.files.len == 4, true)
var sawMissing, sawCycle, sawLate = false
for p in r.problems:
  if p.contains("cannot load css/missing.css"): sawMissing = true
  if p.contains("cycle"): sawCycle = true
  if p.contains("after other rules"): sawLate = true
check("missing reported",                 sawMissing, true)
check("cycle reported",                   sawCycle, true)
check("late @import reported",            sawLate, true)
check("flattened sheet lints clean (but the late import)", lintStylesheet(r.css).len == 1, true)

echo "applies in the cascade:"
let eng = newStyleEngine()
eng.addStylesheet(r.css)
let h = elem("h1")
discard elem("html", elem("body", h))
check("imported h1 rule applies",         eng.computedStyle(h).get("font-size") == "32px", true)
check("layered import loses to unlayered", eng.computedStyle(h).get("color") == "rgb(255, 0, 0)", true)

echo (if fails == 0: "imports: all ok" else: "imports: " & $fails & " FAIL")
