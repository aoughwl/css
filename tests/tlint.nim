import std/syncio
import css

var fails = 0
proc expectClean(desc, src: string) =
  let ds = lintStylesheet(src)
  if ds.len == 0: echo "  ok   clean: " & desc
  else:
    inc fails
    echo "  FAIL clean: " & desc
    for d in ds: echo "         " & $d

proc expectDiag(desc, src: string, line: int, needle: string) =
  ## Exactly one diagnostic, on `line`, whose message contains `needle`.
  let ds = lintStylesheet(src)
  var ok = ds.len == 1 and ds[0].line == line
  if ok:
    let m = ds[0].message
    var found = false
    var i = 0
    while i + needle.len <= m.len:
      var j = 0
      while j < needle.len and m[i+j] == needle[j]: inc j
      if j == needle.len: found = true
      inc i
    ok = found
  if ok: echo "  ok   diag: " & desc & "  -> " & $ds[0]
  else:
    inc fails
    echo "  FAIL diag: " & desc & " (want 1 on line " & $line & " with '" & needle & "'), got:"
    for d in ds: echo "         " & $d

echo "clean sheets:"
expectClean("basic", "a { color: red; margin: 0 auto }\n.b:hover { color: #fff !important }")
expectClean("media + supports + container", """
@charset "UTF-8";
@import url(base.css) layer(base) screen;
@layer base, components;
@media (min-width: 600px) { .a { display: grid } }
@supports (display: grid) { .b { display: grid } }
@container card (width > 30em) { .c { padding: 1rem } }
""")
expectClean("nesting", """
.card {
  color: red;
  &:hover { color: blue }
  > .title { font-weight: bold }
  @media (width > 600px) { padding: 2rem; }
  .x & { color: green }
}
""")
expectClean("keyframes", "@keyframes spin { from { transform: rotate(0) } 50% { opacity: .5 } to { transform: rotate(360deg) } }")
expectClean("font-face", "@font-face { font-family: \"X\"; src: url(x.woff2) format(\"woff2\"); font-display: swap; unicode-range: U+0-7F }")
expectClean("page", "@page :first { margin: 1in; size: A4 portrait; @top-center { content: \"T\" } }")
expectClean("property", "@property --angle { syntax: '<angle>'; inherits: false; initial-value: 0deg }")
expectClean("property *", "@property --any { syntax: '*'; inherits: true }")
expectClean("counter-style", "@counter-style thumbs { system: cyclic; symbols: \"👍\"; suffix: \" \" }")
expectClean("font-feature-values", "@font-feature-values Font One { @styleset { nice-style: 12 } }")
expectClean("layer block + scope", "@layer base { a { color: red } } @scope (.card) to (.body) { img { border: 0 } }")
expectClean("comments + custom props", "/* hi */ :root { --x: { a b }; --empty:; } a { color: var(--x) }")

echo "diagnostics:"
expectDiag("unknown property", "a {\n  colr: red;\n}", 2, "not a known CSS property")
expectDiag("bad value", "a { color: 10px }", 1, "expected")
expectDiag("bad selector", "a:hovr { color: red }", 1, "unknown pseudo-class")
expectDiag("media typo", "@media (min-widht: 600px) { a { color: red } }", 1, "unknown media feature")
expectDiag("unknown at-rule", "@medai screen { a { color: red } }", 1, "unknown at-rule")
expectDiag("import order", "a { color: red }\n@import url(x.css);", 2, "@import must come before")
expectDiag("charset not first", "a{color:red}\n@charset \"UTF-8\";", 2, "@charset must be")
expectDiag("import in media", "@media screen {\n@import url(x.css);\n}", 2, "only allowed at the top level")
expectDiag("decl at top level of @media", "@media screen { color: red }", 1, "not allowed here")
expectDiag("keyframe !important", "@keyframes k { from { color: red !important } }", 1, "!important")
expectDiag("keyframe selector", "@keyframes k { middle { color: red } }", 1, "keyframe selector")
expectDiag("font-face missing src", "@font-face { font-family: X }", 1, "requires a 'src'")
expectDiag("font-face bad descriptor", "@font-face { font-family: X; src: url(a); color: red }", 1, "not a descriptor")
expectDiag("property initial mismatch", "@property --a { syntax: '<length>'; inherits: false; initial-value: red }", 1, "does not match syntax")
expectDiag("property relative initial", "@property --a { syntax: '<length>'; inherits: false; initial-value: 1em }", 1, "computationally independent")
expectDiag("property missing inherits", "@property --a { syntax: '*' }", 1, "requires an 'inherits'")
expectDiag("property bad syntax", "@property --a { syntax: '<colour>'; inherits: false; initial-value: red }", 1, "not a registrable")
expectDiag("counter-style needs symbols", "@counter-style x { system: cyclic }", 1, "requires 'symbols'")
expectDiag("unclosed block", "a { color: red;\nb { color: blue }", 1, "never closed")
expectDiag("stray brace", "a { color: red } }", 1, "stray '}'")
expectDiag("missing colon", "a { color red; }", 1, "expected 'property: value'")
expectDiag("nested relative at top", "> a { color: red }", 1, "")
expectDiag("negative padding", "a {\n\n  padding: -1px }", 3, "range")
expectDiag("page margin outside page", "@top-left { content: 'x' }", 1, "only allowed inside @page")

echo (if fails == 0: "lint: all ok" else: "lint: " & $fails & " FAIL")
