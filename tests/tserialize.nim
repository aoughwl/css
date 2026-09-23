## tserialize — the minifier is checked against three oracles: the minified
## sheet lints clean, computes IDENTICAL styles for every element of a
## Bootstrap document, and is a fixed point of itself.
import std/[syncio, tables]
import css

var fails = 0
proc check(desc: string, ok: bool, detail = "") =
  if ok: echo "  ok   " & desc
  else:
    inc fails
    echo "  FAIL " & desc & (if detail.len > 0: "  " & detail else: "")

proc eq(desc, got, want: string) =
  check(desc & " = " & got, got == want, "(want " & want & ")")

echo "values:"
eq("zero units",        minifyStylesheet("a{margin:0px 0em 0.0rem 1px}"), "a{margin:0 0 0 1px}")
eq("leading zero",      minifyStylesheet("a{opacity:0.50}"), "a{opacity:.5}")
eq("negative",          minifyStylesheet("a{margin:-0.5em}"), "a{margin:-.5em}")
eq("hex shortened",     minifyStylesheet("a{color:#FFFFFF}"), "a{color:#fff}")
eq("hex -> name",       minifyStylesheet("a{color:#ff0000}"), "a{color:red}")
eq("rgb -> hex",        minifyStylesheet("a{color:rgb(51, 102, 153)}"), "a{color:#369}")
eq("names stay",        minifyStylesheet("a{color:white}"), "a{color:white}")
eq("flex keeps 0px",    minifyStylesheet("a{flex:1 1 0px}"), "a{flex:1 1 0px}")
eq("times keep units",  minifyStylesheet("a{transition:opacity 0s}"), "a{transition:opacity 0s}")
eq("calc spaces kept",  minifyStylesheet("a{width:calc(100% - 2px)}"), "a{width:calc(100% - 2px)}")
eq("comma spaces",      minifyStylesheet("a{font-family:Georgia , serif}"), "a{font-family:Georgia,serif}")
eq("slash spaces",      minifyStylesheet("a{font:12px / 1.5 serif}"), "a{font:12px/1.5 serif}")
eq("strings untouched", minifyStylesheet("a{content:\"  a  b \"}"), "a{content:\"  a  b \"}")
eq("custom prop kept",  minifyStylesheet("a{--x:  0px  #FFFFFF }"), "a{--x:0px  #FFFFFF}")
eq("!important",        minifyStylesheet("a{color:red !important}"), "a{color:red!important}")

echo "structure:"
eq("comments go",       minifyStylesheet("/* x */a{color:red}/* y */"), "a{color:red}")
eq("licence stays",     minifyStylesheet("/*! MIT */a{color:red}"), "/*! MIT */a{color:red}")
eq("empty rules go",    minifyStylesheet("a{}b{color:red}@media print{c{}}"), "b{color:red}")
eq("selector spaces",   minifyStylesheet("ul  >  li ,  a + b {color:red}"), "ul>li,a+b{color:red}")
eq("descendant kept",   minifyStylesheet("ul li{color:red}"), "ul li{color:red}")
eq("at-rules",          minifyStylesheet("@media (min-width: 600px) {\n a { color: red; }\n}"), "@media (min-width: 600px){a{color:red}}")
eq("statements",        minifyStylesheet("@import url(a.css);\n@layer a, b;"), "@import url(a.css);@layer a, b;")
eq("nesting",           minifyStylesheet(".a { color: red; &:hover { color: blue } }"), ".a{color:red;&:hover{color:blue}}")
eq("layer kept empty",  minifyStylesheet("@layer base {}"), "@layer base{}")

echo "Bootstrap oracles:"
var src = ""
try: src = readFile("bootstrap.css")
except: discard
let mini = minifyStylesheet(src)
let pretty = renderSheet(parseStylesheet(src))
echo "  bootstrap " & $src.len & " bytes -> minified " & $mini.len & " bytes (" &
     $(mini.len * 100 div (if src.len > 0: src.len else: 1)) & "%)"
check("minified lints clean", lintStylesheet(mini).len == 0)
check("pretty lints clean", lintStylesheet(pretty).len == 0)
let mini2 = minifyStylesheet(mini)
check("minify is a fixed point", mini2 == mini, "(" & $mini.len & " vs " & $mini2.len & " bytes)")
let miniP0 = minifyStylesheet(pretty)
# renderSheet works from the parsed tree, which has no comments: compare past
# the /*! licence */ header the minifier keeps from the original
var skip = 0
if mini.len > 3 and mini[0] == '/' and mini[1] == '*' and mini[2] == '!':
  while skip + 1 < mini.len and not (mini[skip] == '*' and mini[skip+1] == '/'): inc skip
  skip = skip + 2
var miniBody = ""
var sk = skip
while sk < mini.len:
  miniBody.add mini[sk]
  inc sk
let miniP = miniP0
var at = 0
while at < miniBody.len and at < miniP.len and miniBody[at] == miniP[at]: inc at
var ctxA = ""
var ctxB = ""
var q = at - 40
if q < 0: q = 0
while q < at + 40:
  if q < miniBody.len: ctxA.add miniBody[q]
  if q < miniP.len: ctxB.add miniP[q]
  inc q
check("minify(pretty) == minify(src) past the licence", miniP == miniBody, "first difference at " & $at & ":\n      src:    " & ctxA & "\n      pretty: " & ctxB)

proc build(): Element =
  var body = elem("body")
  var i = 0
  while i < 4:
    body.appendChild(elem("div.container",
      elem("div.row", elem("div.col-md-6",
        elem("div.card", elem("div.card-body", elem("h5.card-title"),
          elem("p.card-text.text-muted.small"),
          elem("a.btn.btn-outline-secondary.btn-lg[href=\"#\"]"),
          elem("span.badge.rounded-pill.text-bg-warning")))),
        elem("div.col-md-6", elem("table.table.table-striped",
          elem("tbody", elem("tr", elem("td"), elem("td.text-end"))))),
        elem("nav", elem("ul.pagination", elem("li.page-item.active", elem("a.page-link"))))),
      elem("form", elem("input.form-control[type=\"text\"]"), elem("select.form-select"),
           elem("div.form-check", elem("input.form-check-input[type=\"checkbox\"]"))),
      elem("div.alert.alert-danger.d-flex.align-items-center.p-3.mt-2.shadow-sm")))
    inc i
  elem("html", body)

let doc = build()
let e1 = newStyleEngine()
e1.addUserAgentDefaults()
e1.addStylesheet(src)
let e2 = newStyleEngine()
e2.addUserAgentDefaults()
e2.addStylesheet(mini)
let e3 = newStyleEngine()
e3.addUserAgentDefaults()
e3.addStylesheet(pretty)
let t1 = computeTree(e1, doc)
let t2 = computeTree(e2, doc)
let t3 = computeTree(e3, doc)
var diffs = 0
var props = 0
var shown = 0
var k = 0
while k < t1.len:
  for p, v0 in t1[k].style.values.pairs:
    inc props
    let v = t1[k].style.get(p)
    let v2 = t2[k].style.get(p)
    let v3 = t3[k].style.get(p)
    if v2 != v or v3 != v:
      inc diffs
      if shown < 8:
        echo "    diff " & $t1[k].el & " " & p & ": [" & v & "] min [" & v2 & "] pretty [" & v3 & "]"
        inc shown
  inc k
echo "  compared " & $props & " computed values over " & $t1.len & " elements"
check("minified + pretty compute identically", diffs == 0, $diffs & " differences")
check("the comparison is not empty", props > 1000)

echo (if fails == 0: "serialize: all ok" else: "serialize: " & $fails & " FAIL")
