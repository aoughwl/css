import std/syncio
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

proc norm(desc, sel, want: string) =
  let got = normalizeSelector(sel)
  if got == want: echo "  ok   " & desc & " = " & got
  else: echo "  FAIL " & desc & " got [" & got & "] want [" & want & "]"

echo "An+B (:nth-*):"
for s in ["li:nth-child(odd)", "li:nth-child(even)", "li:nth-child(3)",
          "li:nth-child(-n+3)", "li:nth-child(n)", "li:nth-child(2n)",
          "li:nth-child(2n + 1)", "li:nth-child(+5)", "li:nth-child(-2n-1)",
          "li:nth-child(n-1)", "li:nth-child( 3n - 2 )", "li:nth-last-of-type(2n+1)",
          "li:nth-child(2n+1 of .important)", "li:nth-child(odd of li.x, li.y)"]:
  check("valid " & s, selectorValid(s), true)
for s in ["li:nth-child()", "li:nth-child(2x)", "li:nth-child(2n+)",
          "li:nth-child(+ 2n)", "li:nth-child(2n 1)", "li:nth-of-type(2n of .x)",
          "li:nth-child(odd of)", "li:nth-child"]:
  check("invalid " & s, selectorValid(s), false)

echo "selector-list pseudos:"
for s in [":not(.a, #b)", "a:not([href])", ":is(h1, h2) + p", ":where(.x) .y",
          "a:has(> img)", "section:has(h1, + p)", ":is()", ":is(:bogus, .ok)",
          "div:not(:has(p))", ":-webkit-any(a, b)"]:
  check("valid " & s, selectorValid(s), true)
for s in [":not()", ":not(:bogus)", "a:has()", "a:has(:has(b))", "a:has(::before)",
          ":not(.a,)", ":not"]:
  check("invalid " & s, selectorValid(s), false)

echo "other functional pseudos:"
for s in ["p:lang(en)", "p:lang(\"*-CH\", fr)", "p:dir(rtl)", "::part(label)",
          "x-el::part(a b)", "::slotted(span.x)", ":host", ":host(.dark)",
          ":host-context(body.dark)", "::highlight(search)", ":state(checked)",
          "::view-transition-old(*)", "::view-transition-group(hero)",
          "::cue", "::cue(b)", "input::-webkit-input-placeholder",
          ":-moz-focusring", "::-moz-selection"]:
  check("valid " & s, selectorValid(s), true)
for s in ["p:dir(up)", "::part()", "::slotted(a b)", "a:hover()", "p::before()",
          ":lang()", "::highlight(1x)", "p:dir"]:
  check("invalid " & s, selectorValid(s), false)

echo "escapes, namespaces, nesting:"
for s in [".a\\:b", "#\\31 23", ".\\31 0", ".foo\\.bar", "svg|circle", "*|*",
          "|p", "ns|*", "[xlink|href]", "[*|lang]", "[|x]", "&", "&.active",
          ".a &", "& + &", ".\\@sm\\:flex", "a[title=\"x\\\"y\"]", "td || td",
          "a /* comment */ b", "[data-x='1' i]", "[a=b s]", "::before:hover",
          "::part(x)::before"]:
  check("valid " & s, selectorValid(s), true)
for s in ["#1a", ".1a", "[data-x=1]", "p::before.x", "p::before#id", "::after[x]",
          "a|", "[a=\"b]", "div*", ".a > > .b", "a,,b", "[a~b]"]:
  check("invalid " & s, selectorValid(s), false)
check("nested relative > .x",  validateNestedSelector("> .x").valid, true)
check("nested relative + &",   validateNestedSelector("+ .x, ~ &").valid, true)
check("top-level > .x",        validateSelector("> .x").valid, false)

echo "normalisation:"
norm("whitespace",         "ul>li  +  a",           "ul > li + a")
norm("attr quoted",        "[type=text]",           "[type=\"text\"]")
norm("attr flag",          "[a='b'I]",              "[a=\"b\" i]")
norm("escape resolved",    ".\\61 bc",              ".abc")
norm("digit re-escaped",   ".\\31 0",               ".\\31 0")
norm("An+B canonical",     "li:nth-child(odd)",     "li:nth-child(2n+1)")
norm("list",               "h1,h2 ,  h3",           "h1, h2, h3")
norm("not list",           ":not( .a ,#b )",        ":not(.a, #b)")
norm("invalid is empty",   "a:bogus",               "")
