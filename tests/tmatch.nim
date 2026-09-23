import std/syncio
import css

var fails = 0
proc check(desc: string, got, want: bool) =
  if got == want: echo "  ok   " & desc
  else:
    inc fails
    echo "  FAIL " & desc & " (got " & $got & ", want " & $want & ")"

# <html lang="en-US">
#   <body class="page dark">
#     <nav id="top"><ul>
#        <li class="item first">  <a href="/" class="x">  </li>
#        <li class="item active"> <a href="https://e.com" data-kind="ext pdf"> </li>
#        <li class="item hidden"></li>
#        <li class="item">  <span>  </li>
#     </ul></nav>
#     <main dir="rtl"><h2/><p/><p class="lead"/><form><input type=checkbox checked><input disabled required></form></main>
let a1 = elem("a.x[href=\"/\"]")
let a2 = elem("a[href=\"https://e.com\"][data-kind=\"ext pdf\"]")
let li1 = elem("li.item.first", a1)
let li2 = elem("li.item.active", a2)
let li3 = elem("li.item.hidden")
let span = elem("span")
let li4 = elem("li.item", span)
let ul = elem("ul", li1, li2, li3, li4)
let nav = elem("nav#top", ul)
let h2 = elem("h2")
let p1 = elem("p").withText("x")
let p2 = elem("p.lead")
let cb = elem("input[type=\"checkbox\"][checked]")
let dis = elem("input[disabled][required]")
let form = elem("form", cb, dis)
let main = elem("main[dir=\"rtl\"]", h2, p1, p2, form)
let body = elem("body.page.dark", nav, main)
let html = elem("html[lang=\"en-US\"]", body)

echo "simple + compound:"
check("type",                   matches(li1, "li"), true)
check("type case-insensitive",  matches(li1, "LI"), true)
check("class",                  matches(li2, ".active"), true)
check("two classes",            matches(li2, ".item.active"), true)
check("class miss",             matches(li1, ".item.active"), false)
check("id",                     matches(nav, "#top"), true)
check("universal",              matches(span, "*"), true)
check("list",                   matches(h2, "h1, h2"), true)
check("invalid never matches",  matches(h2, "h2:bogus"), false)

echo "attributes:"
check("[href]",                 matches(a1, "[href]"), true)
check("[href=\"/\"]",           matches(a1, "[href=\"/\"]"), true)
check("^=",                     matches(a2, "a[href^=\"https\"]"), true)
check("$=",                     matches(a2, "[href$=\".com\"]"), true)
check("*=",                     matches(a2, "[href*=\"e.c\"]"), true)
check("~= word",                matches(a2, "[data-kind~=\"pdf\"]"), true)
check("~= not substring",       matches(a2, "[data-kind~=\"pd\"]"), false)
check("|= lang",                matches(html, "[lang|=\"en\"]"), true)
check("i flag",                 matches(a2, "[href^=\"HTTPS\" i]"), true)
check("no i flag",              matches(a2, "[href^=\"HTTPS\"]"), false)

echo "combinators:"
check("descendant",             matches(a1, "nav a"), true)
check("child",                  matches(a1, "li > a"), true)
check("child miss",             matches(a1, "ul > a"), false)
check("next sibling",           matches(li2, ".first + li"), true)
check("next sibling miss",      matches(li3, ".first + li"), false)
check("subsequent sibling",     matches(li4, ".first ~ .item"), true)
check("long chain",             matches(span, "html body > nav ul li:last-child span"), true)
check("backtracking desc",      matches(a2, ".page .active a"), true)

echo "structural:"
check(":root",                  matches(html, ":root"), true)
check(":first-child",           matches(li1, "li:first-child"), true)
check(":last-child",            matches(li4, ":last-child"), true)
check(":only-child",            matches(span, ":only-child"), true)
check(":nth-child(2)",          matches(li2, ":nth-child(2)"), true)
check(":nth-child(odd) li3",    matches(li3, ":nth-child(odd)"), true)
check(":nth-child(odd) li2",    matches(li2, ":nth-child(odd)"), false)
check(":nth-child(-n+2)",       matches(li2, ":nth-child(-n+2)"), true)
check(":nth-child(-n+2) li3",   matches(li3, ":nth-child(-n+2)"), false)
check(":nth-last-child(1)",     matches(li4, ":nth-last-child(1)"), true)
check("nth-child of S",         matches(li4, ":nth-child(3 of .item)"), false)
check("nth-child of S (hid)",   matches(li4, ":nth-child(3 of .item:not(.hidden))"), true)
check(":nth-of-type(2)",        matches(p2, "p:nth-of-type(2)"), true)
check(":first-of-type",         matches(p1, "p:first-of-type"), true)
check(":empty",                 matches(h2, ":empty"), true)
check(":empty text",            matches(p1, ":empty"), false)

echo "logical:"
check(":not",                   matches(li1, "li:not(.active)"), true)
check(":not miss",              matches(li2, "li:not(.active)"), false)
check(":is",                    matches(p2, ":is(h2, .lead)"), true)
check(":where",                 matches(h2, "main :where(h1, h2)"), true)
check(":has(> a)",              matches(li1, "li:has(> a)"), true)
check(":has(> a) miss",         matches(li3, "li:has(> a)"), false)
check(":has descendant",        matches(nav, "nav:has(span)"), true)
check(":has(+ .active)",        matches(li1, "li:has(+ .active)"), true)
check(":has(~ .hidden)",        matches(li1, ":has(~ .hidden)"), true)
check(":has chain",             matches(ul, "ul:has(> li > a[href^=\"https\"])"), true)
check(":not(:has())",           matches(li3, "li:not(:has(*))"), true)

echo "lang / dir / forms / states:"
check(":lang(en)",              matches(span, ":lang(en)"), true)
check(":lang(fr)",              matches(span, ":lang(fr)"), false)
check(":dir(rtl) inherited",    matches(p1, ":dir(rtl)"), true)
check(":dir(ltr)",              matches(span, ":dir(ltr)"), true)
check(":checked",               matches(cb, ":checked"), true)
check(":disabled",              matches(dis, ":disabled"), true)
check(":enabled",               matches(cb, ":enabled"), true)
check(":required",              matches(dis, ":required"), true)
check(":optional",              matches(cb, ":optional"), true)
check(":link",                  matches(a1, "a:link"), true)
check(":hover off",             matches(a1, "a:hover"), false)
a1.setState("hover")
check(":hover on",              matches(a1, "a:hover"), true)
check("li:has(a:hover)",        matches(li1, "li:has(a:hover)"), true)
a1.setState("hover", false)
check(":hover off again",       matches(a1, "a:hover"), false)
cb.setState("focus")
check(":focus-within",          matches(form, "form:focus-within"), true)
check("pseudo-element never",   matches(p1, "p::before"), false)

echo "nesting &:"
check("& with parent",          matches(a1, "& > a", "li.first"), true)
check("& with parent miss",     matches(a2, "& > a", "li.first"), false)
check("relative nested",        matches(a1, "> a", "li.first"), true)

echo "query:"
check("querySelectorAll li",    querySelectorAll(html, "li").len == 4, true)
check("qsa :not(.hidden)",      querySelectorAll(html, "li:not(.hidden)").len == 3, true)
check("qsa scope",              querySelectorAll(ul, ":scope > li").len == 4, true)
check("querySelector",          querySelector(html, "a[href^=\"https\"]") == a2, true)
check("querySelector none",     querySelector(html, "table") == nil, true)
check("closest",                closest(a2, "li") == li2, true)
check("closest self",           closest(li2, "li") == li2, true)
check("closest none",           closest(a2, "table") == nil, true)
check("elem builder id/class",  $li2 == "li.item.active", true)

echo (if fails == 0: "match: all ok" else: "match: " & $fails & " FAIL")
