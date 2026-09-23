import std/syncio
import css

var fails = 0
proc eq(desc, got, want: string) =
  if got == want: echo "  ok   " & desc & " = " & got
  else:
    inc fails
    echo "  FAIL " & desc & ": got [" & got & "] want [" & want & "]"

# <html><body class="dark"><div id="app" class="card" style="padding: 2px">
#   <h1 class="title">…</h1><p class="lead">…</p><a href="#">…</a></div></body></html>
let h1 = elem("h1.title")
let p = elem("p.lead")
let a = elem("a[href=\"#\"]")
let card = elem("div#app.card[style=\"padding: 2px; --gap: 7px\"]", h1, p, a)
let body = elem("body.dark", card)
let html = elem("html", body)

let eng = newStyleEngine()
eng.addUserAgentDefaults()
eng.addStylesheet("""
@layer base, theme;
:root { --brand: #336699; --size: 20px; font-size: 16px }
body { color: black; font-family: Georgia, serif; margin: 0 }
.dark { color: white }
#app { color: rgb(1 2 3) }
.card { margin: 1em 2em; border: 1px solid var(--brand); padding: 10px !important; font-size: 1.25em }
.card > .title { font-size: 2em; margin: 0 0 .5em }
h1 { color: red !important }
.lead { font: italic bold 12px/1.5 Arial, sans-serif; width: 50vw; text-indent: 3pt }
a { color: var(--brand); text-decoration: var(--deco, underline dotted) }
p { background: var(--missing) }
@media (max-width: 600px) { .card { margin: 0 } }
@media (min-width: 601px) { .lead { letter-spacing: 1px } }
@supports (display: grid) { .card { display: grid } }
@supports (display: gridd) { .card { display: flex } }
@layer theme { .title { color: green; letter-spacing: 3px } }
@layer base { .title { letter-spacing: 9px; word-spacing: 1px } }
.title { word-spacing: 2px }
.card { &:hover { background-color: orange } .title & { color: blue } }
.card .lead { gap: var(--gap) }
""", oAuthor, "site.css")

let csCard = eng.computedStyle(card)
echo "cascade basics:"
eq("#app beats .dark",                 csCard.get("color"), "rgb(1, 2, 3)")
eq("display from @supports",           csCard.get("display"), "grid")
eq("inline beats rule",                csCard.get("padding-left"), "10px")
eq("margin 1em at 20px font",          csCard.get("margin-top"), "20px")
eq("margin 2em",                       csCard.get("margin-left"), "40px")
eq("font-size 1.25em of 16",           csCard.get("font-size"), "20px")
eq("border var() substituted",         csCard.get("border-top-color"), "rgb(51, 102, 153)")
eq("border width",                     csCard.get("border-left-width"), "1px")
eq("custom prop from style attr",      csCard.get("--gap"), "7px")

let csH1 = eng.computedStyle(h1)
echo "h1:"
eq("!important beats specificity",     csH1.get("color"), "rgb(255, 0, 0)")
eq("font-size 2em of 20px",            csH1.get("font-size"), "40px")
eq("margin-bottom .5em of 40",         csH1.get("margin-bottom"), "20px")
eq("unlayered beats layers",           csH1.get("word-spacing"), "2px")
eq("later layer beats earlier",        csH1.get("letter-spacing"), "3px")
eq("inherits font-family",             csH1.get("font-family"), "Georgia, serif")

let csP = eng.computedStyle(p)
echo "p (font shorthand, units):"
eq("font-style",                       csP.get("font-style"), "italic")
eq("font-weight",                      csP.get("font-weight"), "bold")
eq("font-size",                        csP.get("font-size"), "12px")
eq("line-height number stays",         csP.get("line-height"), "1.5")
eq("font-family",                      csP.get("font-family"), "Arial, sans-serif")
eq("50vw of 1280",                     csP.get("width"), "640px")
eq("3pt",                              csP.get("text-indent"), "4px")
eq("@media min-width applies",         csP.get("letter-spacing"), "1px")
eq("var() in a shorthand (gap)",       csP.get("row-gap"), "7px")
eq("shorthand get when equal",         csP.get("gap"), "7px")
eq("invalid var() -> unset (initial)", csP.get("background-color"), "rgba(0, 0, 0, 0)")
eq("inherited color",                  csP.get("color"), "rgb(1, 2, 3)")
eq("UA margin-block 1em of 12px",      csP.get("margin-top"), "12px")

let csA = eng.computedStyle(a)
echo "a (var with fallback):"
eq("color var(--brand)",               csA.get("color"), "rgb(51, 102, 153)")
eq("fallback in shorthand",            csA.get("text-decoration-style"), "dotted")

echo "nesting and states:"
eq("before hover",                     eng.computedStyle(card).get("background-color"), "rgba(0, 0, 0, 0)")
card.setState("hover")
eq("&:hover applies",                  eng.computedStyle(card).get("background-color"), "rgb(255, 165, 0)")
card.setState("hover", false)
let t2 = elem("h2.title", elem("div.card"))
let outer = elem("html", elem("body", t2))
discard outer
eq("`.title &` nesting",               eng.computedStyle(t2.children[0]).get("color"), "rgb(0, 0, 255)")

echo "media env changes take effect:"
eng.env.width = 500.0
eq("narrow: margin 0",                 eng.computedStyle(card).get("margin-top"), "0")
eq("narrow: no letter-spacing rule",   eng.computedStyle(p).get("letter-spacing"), "normal")
eng.env.width = 1280.0

echo "logical properties:"
let lEng = newStyleEngine()
lEng.addStylesheet("""
div { margin-top: 1px; margin-block-start: 2px; padding-left: 5px }
div.late { padding-inline-start: 6px }
div.rtl { direction: rtl; padding-inline-start: 7px }
div.v { writing-mode: vertical-rl; margin-block-start: 3px; inline-size: 10px }
""")
let d1 = elem("div")
let d2 = elem("div.late")
let d3 = elem("div.rtl")
let d4 = elem("div.v")
discard elem("html", d1, d2, d3, d4)
eq("later logical beats physical",     lEng.computedStyle(d1).get("margin-top"), "2px")
eq("logical get maps back",            lEng.computedStyle(d1).get("margin-block-start"), "2px")
eq("inline-start -> left (ltr)",       lEng.computedStyle(d2).get("padding-left"), "6px")
eq("inline-start -> right (rtl)",      lEng.computedStyle(d3).get("padding-right"), "7px")
eq("rtl leaves left alone",            lEng.computedStyle(d3).get("padding-left"), "5px")
eq("vertical-rl block-start = right",  lEng.computedStyle(d4).get("margin-right"), "3px")
eq("vertical inline-size = height",    lEng.computedStyle(d4).get("height"), "10px")

echo "keywords:"
let kEng = newStyleEngine()
kEng.addStylesheet("""
div { color: red; border-color: blue; margin-top: 5px }
span { color: green }
span.i { color: inherit }
span.n { color: initial; margin-top: inherit }
span.u { color: unset; border-color: unset }
span.r { color: revert }
@layer a { em { color: purple } }
@layer b { em { color: revert-layer } }
""")
let si = elem("span.i")
let sn = elem("span.n")
let su = elem("span.u")
let sr = elem("span.r")
let em1 = elem("em")
discard elem("div", si, sn, su, sr, em1)
eq("inherit",                          kEng.computedStyle(si).get("color"), "rgb(255, 0, 0)")
eq("initial",                          kEng.computedStyle(sn).get("color"), "rgb(0, 0, 0)")
eq("inherit non-inherited prop",       kEng.computedStyle(sn).get("margin-top"), "5px")
eq("unset on inherited = inherit",     kEng.computedStyle(su).get("color"), "rgb(255, 0, 0)")
eq("unset on non-inherited = initial", kEng.computedStyle(su).get("border-top-color"), "rgb(255, 0, 0)")
eq("revert (no UA rule) = unset",      kEng.computedStyle(sr).get("color"), "rgb(255, 0, 0)")
eq("revert-layer -> earlier layer",    kEng.computedStyle(em1).get("color"), "rgb(128, 0, 128)")

echo "cycles and @property:"
let cEng = newStyleEngine()
cEng.addStylesheet("""
@property --n { syntax: '<length>'; inherits: false; initial-value: 3px }
div { --a: var(--b); --b: var(--a); --c: 1px; width: var(--a, 9px); --n: 5px }
span { height: var(--n); min-height: var(--c) }
""")
let sp = elem("span")
let dv = elem("div", sp)
eq("cycle -> fallback",                cEng.computedStyle(dv).get("width"), "9px")
eq("cycle members invalid",            cEng.computedStyle(dv).get("--a"), "")
eq("registered non-inherited",         cEng.computedStyle(sp).get("height"), "3px")
eq("unregistered inherits",            cEng.computedStyle(sp).get("min-height"), "1px")

echo "pseudo-elements and scope:"
let pEng = newStyleEngine()
pEng.addStylesheet("""
p { color: blue }
p::before { content: "» "; color: gray }
@scope (.card) to (.content) { img { border: 2px solid } }
""")
let img1 = elem("img")
let img2 = elem("img")
let img3 = elem("img")
discard elem("html", elem("div.card", img1, elem("div.content", img2)), img3)
let pp = elem("p")
discard elem("html", pp)
eq("::before content",                 pEng.computedStyle(pp, "before").get("content"), "\"» \"")
eq("::before color",                   pEng.computedStyle(pp, "before").get("color"), "rgb(128, 128, 128)")
eq("p itself",                         pEng.computedStyle(pp).get("color"), "rgb(0, 0, 255)")
eq("in scope",                         pEng.computedStyle(img1).get("border-top-width"), "2px")
eq("below scope limit",                pEng.computedStyle(img2).get("border-top-width"), "medium")
eq("outside scope",                    pEng.computedStyle(img3).get("border-top-width"), "medium")

echo "why:"
let w = eng.why(h1, "color")
echo w
var head = ""
var hi = 0
while hi < w.len and hi < 18:
  head.add w[hi]
  inc hi
eq("why names the winner",             head, "color: red !import")

echo "currentcolor:"
let ccEng = newStyleEngine()
ccEng.addStylesheet("div { color: rebeccapurple; border: 1px solid } span { color: currentcolor }")
let ccS = elem("span")
let ccD = elem("div", ccS)
discard elem("html", ccD)
eq("border colour = currentcolor",     ccEng.computedStyle(ccD).get("border-top-color"), "rgb(102, 51, 153)")
eq("color: currentcolor inherits",     ccEng.computedStyle(ccS).get("color"), "rgb(102, 51, 153)")

echo (if fails == 0: "computed: all ok" else: "computed: " & $fails & " FAIL")
