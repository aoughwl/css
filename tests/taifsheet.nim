## taifsheet.nim — the composed pipeline, end to end on real CSS.
##
##   bootstrap.css -> aowlparser -> .css.aif -> cssDeclarations -> validateValue
##
## Asserts two things a single-parser test cannot:
##   1. the AIF path finds the declarations that are really there, and
##   2. their values validate against the MDN grammars this library owns.

import ../css/aifsheet
import ../css/validator
import std/syncio

var checked = 0
var failures = 0

proc expectFindings(name, src: string; want: int) =
  checked = checked + 1
  let got = validateSheet(src).len
  if got != want:
    failures = failures + 1
    echo "FAIL ", name, ": expected ", want, " finding(s), got ", got
    for f in validateSheet(src):
      echo "       ", f.selector, " { ", f.prop, ": ", f.value, " }  ", f.error

proc expectDecls(name, src: string; want: int) =
  checked = checked + 1
  let s = sheetStats(src)
  if s.decls != want:
    failures = failures + 1
    echo "FAIL ", name, ": expected ", want, " declaration(s), got ", s.decls

# --- the pipeline finds what is there --------------------------------------
expectDecls "one declaration", "a { color: red }", 1
expectDecls "three declarations", "a { color: red; width: 10px; top: 0 }", 3
expectDecls "declarations inside a media query",
  "@media (min-width: 10px) { a { color: red; width: 1px } }", 2
expectDecls "nested rules", "a { color: red; &:hover { color: blue } }", 2
expectDecls "custom properties are skipped", "a { --x: whatever; color: red }", 1

# --- and validates them ----------------------------------------------------
expectFindings "valid stylesheet", "a { color: red; width: 10px }", 0
expectFindings "valid with important", "a { color: red !important }", 0
expectFindings "one bad value", "a { color: notacolor }", 1
expectFindings "bad unit", "a { width: 10 }", 1
expectFindings "valid inside media",
  "@media screen { a { color: #fff } }", 0
expectFindings "valid multi-value", "a { margin: 0 auto 10px 2em }", 0
expectFindings "valid function", "a { width: calc(100% - 10px) }", 0

# --- comments are TRIVIA, not value content --------------------------------
# The dialect stores comments inside `val` because byte-exactness requires it.
# Folding them into the value string makes a correct validator reject correct
# CSS. Bootstrap ships exactly this, and it produced 3 spurious findings before
# cssDeclarations learned to drop comment leaves.
expectFindings "trailing comment in a value",
  "a { transform: rotate(360deg) /* rtl:ignore */ }", 0
expectFindings "comment between value tokens",
  "a { margin: 0 /* mid */ auto }", 0
expectFindings "comment in a selector",
  "a /* c */ { color: red }", 0

# --- malformed CSS must not crash the pipeline -----------------------------
# This is the property that distinguishes the AIF path from a heuristic parser:
# the parser recovers, so validation still reports on whatever WAS parseable.
expectDecls "unclosed block still yields its decls", "a { color: red", 1
expectDecls "garbage between rules", "a { color: red } @#$% b { top: 0 }", 2

# --- the real corpus -------------------------------------------------------
var src = ""
var ok = true
try:
  src = readFile("tests/bootstrap.css")
except:
  ok = false
if ok:
  let s = sheetStats(src)
  echo "bootstrap.css: ", s.decls, " declarations, ", s.invalid,
       " failed validation (", (s.decls - s.invalid) * 100 div s.decls, "% valid)"
  checked = checked + 1
  # The gate is that the pipeline EXTRACTS a realistic number of declarations.
  # Bootstrap 5.3 has a few thousand; anything near zero means the walk broke.
  if s.decls < 1000:
    failures = failures + 1
    echo "FAIL bootstrap: only ", s.decls, " declarations extracted"
else:
  echo "note: tests/bootstrap.css not found (run from the repo root)"

echo "aifsheet: ", checked - failures, "/", checked, " ok"
if failures > 0: quit 1
