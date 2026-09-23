## tperf — computed style for a 300-element document under all of Bootstrap.
## Prints timings; FAILs if the whole pass takes longer than a generous bound.
import std/[syncio, monotimes]
import css

var src = ""
try: src = readFile("bootstrap.css")
except: quit(1)

proc build(): Element =
  var body = elem("body")
  var i = 0
  while i < 30:
    let card = elem("div.card.mb-3",
      elem("div.card-header", elem("h5.card-title")),
      elem("div.card-body",
        elem("p.card-text.text-muted"),
        elem("a.btn.btn-primary[href=\"#\"]"),
        elem("ul.list-group",
          elem("li.list-group-item.active"),
          elem("li.list-group-item"))),
      elem("div.card-footer", elem("small.text-body-secondary")))
    body.appendChild(elem("div.col-md-4", card))
    inc i
  elem("html", body)

let doc = build()
let all = doc.descendants
let t0 = getMonoTime()
let eng = newStyleEngine()
eng.addUserAgentDefaults()
eng.addStylesheet(src)
let t1 = getMonoTime()
var n = 0
var sample = ""
let cs = computeTree(eng, doc)
n = cs.len
let t2 = getMonoTime()
for pair in cs:
  if pair.el.hasClass("btn-primary") and sample.len == 0:
    sample = pair.style.get("background-color") & " / " & pair.style.get("padding-left") &
             " / " & pair.style.get("font-size")
let addMs = (ticks(t1) - ticks(t0)) div 1_000_000
let computeMs = (ticks(t2) - ticks(t1)) div 1_000_000
echo "elements:        " & $n
echo "add sheet:       " & $addMs & " ms"
echo "compute all:     " & $computeMs & " ms  (" & $(if n > 0: (ticks(t2) - ticks(t1)) div int64(n) div 1000 else: 0) & " us/element)"
echo ".btn-primary:    " & sample
if computeMs > 2000: echo "FAIL perf: computing " & $n & " elements took " & $computeMs & " ms"
else: echo "perf ok"
