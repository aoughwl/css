import std/syncio
import css

proc check(desc: string, got, want: string) =
  if got == want:
    echo "  ok   " & desc & " = " & got
  else:
    echo "  FAIL " & desc & " got " & got & " want " & want

echo "specificity:"
check("div",                $specificity("div"), "(0,0,1)")
check("ul li",              $specificity("ul li"), "(0,0,2)")
check(".card",              $specificity(".card"), "(0,1,0)")
check("#main",              $specificity("#main"), "(1,0,0)")
check("a.btn#go",           $specificity("a.btn#go"), "(1,1,1)")
check("universal",          $specificity("*"), "(0,0,0)")
check("a:hover",            $specificity("a:hover"), "(0,1,1)")
check("p::before",          $specificity("p::before"), "(0,0,2)")
check("attribute",          $specificity("[type=\"text\"]"), "(0,1,0)")
check("functional pseudo",  $specificity("li:nth-child(2n+1)"), "(0,1,1)")

# A legacy one-colon pseudo-ELEMENT counts as an element, not as a class.
# Found by cross-checking against a renderer over 1174 real selectors: 13 of
# the 14 disagreements were this, and on a page that writes both `.tab:after`
# and `.tab.active` it is the wrong rule painting.
check("legacy :after",      $specificity("a:after"), "(0,0,2)")
check(":after == ::after",  $specificity("a:after"), $specificity("a::after"))
check("legacy :before",     $specificity(".block td.icon .note:before"), "(0,3,2)")
check("legacy :first-line", $specificity("p:first-line"), "(0,0,2)")
check("child + :after",     $specificity(".has-children>.link:after"), "(0,2,1)")

# :not()/:is()/:has() are worth their ARGUMENT and nothing themselves; :where()
# is worth nothing at all. The 14th disagreement was an id inside :not() being
# thrown away.
check(":not(#id)",          $specificity("code.sample:not(#sample0)"), "(1,1,1)")
check(":not(.class)",       $specificity(":not(.a)"), "(0,1,0)")
check(":not(type)",         $specificity(":not(div)"), "(0,0,1)")
check(":is takes the most", $specificity(":is(.a, #b)"), "(1,0,0)")
check(":where is free",     $specificity(":where(#a, .b)"), "(0,0,0)")
check(":where on a type",   $specificity("div:where(.x)"), "(0,0,1)")
check("complex",            $specificity("ul.nav > li:first-child a"), "(0,2,3)")
check("list max",           $specificity("h1, .x#y"), "(1,1,0)")

echo "cascade:"
var decls: seq[Decl] = @[
  Decl(selector: "div",   property: "color", value: "black"),
  Decl(selector: ".card", property: "color", value: "red"),
  Decl(selector: "#id",   property: "color", value: "blue"),
  Decl(selector: "p",     property: "margin", value: "0"),
  Decl(selector: "p",     property: "margin", value: "10px"),
]
let winners = cascade(decls)
var colorVal = ""
var marginVal = ""
for w in winners:
  if w.property == "color": colorVal = w.value
  if w.property == "margin": marginVal = w.value
check("color (#id wins)",            colorVal, "blue")
check("margin (later of equal spec)", marginVal, "10px")

echo "specificity (Selectors-4, from the AST):"
check(":nth-child of S",    $specificity("li:nth-child(2n of .x#y)"), "(1,2,1)")
check(":nth-child plain",   $specificity(":nth-child(odd)"), "(0,1,0)")
check("::slotted(X)",       $specificity("::slotted(span.x)"), "(0,1,2)")
check(":host(X)",           $specificity(":host(.dark)"), "(0,2,0)")
check(":has(> img)",        $specificity("a:has(> img.big)"), "(0,1,2)")
check("nesting & is 0",     $specificity("&.x"), "(0,1,0)")
check("escaped class",      $specificity(".a\\.b"), "(0,1,0)")
check("namespaced type",    $specificity("svg|circle"), "(0,0,1)")
check("attr w/ ns",         $specificity("[xlink|href]"), "(0,1,0)")
check("vendor ::-webkit",   $specificity("input::-webkit-input-placeholder"), "(0,0,2)")

echo "cascade with !important:"
let w2 = cascade(@[
  Decl(selector: "#id", property: "color", value: "blue"),
  Decl(selector: "p", property: "color", value: "red", important: true),
  Decl(selector: "#x #y", property: "color", value: "green")])
check("!important beats specificity", w2[0].value, "red")
