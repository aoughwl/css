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
