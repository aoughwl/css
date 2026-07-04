import css

proc check(desc: string, got, want: bool) =
  if got == want:
    echo "  ok   " & desc
  else:
    echo "  FAIL " & desc & " (got " & $got & ", want " & $want & ")"

echo "selector validation (valid):"
check("type",                selectorValid("div"), true)
check("class",               selectorValid(".card"), true)
check("id",                  selectorValid("#main"), true)
check("universal",           selectorValid("*"), true)
check("descendant",          selectorValid("ul li"), true)
check("child",               selectorValid("ul > li"), true)
check("sibling +",           selectorValid("h1 + p"), true)
check("sibling ~",           selectorValid("h1 ~ p"), true)
check("compound",            selectorValid("a.btn#go"), true)
check("attribute present",   selectorValid("[disabled]"), true)
check("attribute =",         selectorValid("[type=\"text\"]"), true)
check("attribute ^=",        selectorValid("[href^=\"https\"]"), true)
check("pseudo-class",        selectorValid("a:hover"), true)
check("pseudo-element",      selectorValid("p::before"), true)
check("functional pseudo",   selectorValid("li:nth-child(2n+1)"), true)
check("selector list",       selectorValid("h1, h2, h3"), true)
check("complex",             selectorValid("ul.nav > li:first-child a"), true)

echo "selector validation (invalid):"
check("empty",               selectorValid(""), false)
check("bad pseudo-class",    selectorValid("a:notapseudo"), false)
check("bad pseudo-element",  selectorValid("p::notreal"), false)
check("dangling combinator", selectorValid("ul >"), false)
check("bare combinator",     selectorValid("> li"), false)
check("unclosed attribute",  selectorValid("[type"), false)
check("trailing comma",      selectorValid("h1,"), false)
