## aifsheet.nim — validate a WHOLE stylesheet, by composing two parsers.
##
##     source.css
##        │  aowlparser (aoughwl/aowlparser, the `css-parsed` AIF dialect)
##        ▼
##     .css.aif          full CSS syntax, error-recovering, byte-exact
##        │  cssDeclarations()  — a decoded view: (selector, prop, value)
##        ▼
##     validateValue(prop, value)     this library, MDN grammar matching
##
## WHY COMPOSE RATHER THAN REPLACE. aowlparser and this library are complements,
## not duplicates. aowlparser owns SYNTAX: it follows the CSS Syntax spec, keeps
## raw lexemes, recovers from anything, and never dies. This library owns
## SEMANTICS: `vds.nim` parses MDN value-definition grammars and `validator.nim`
## matches values against them — a different language and a different job.
##
## What that buys over `css/parse.nim` (which stays, and is still what
## tests/tbootstrap.nim uses): parse.nim is a ~250-line top-level-delimiter
## heuristic. This path handles escapes, nested at-rules, CSS Nesting, unusual
## quoting, and malformed input without giving up — because it is the same
## parser that round-trips 543KB of real CSS byte-exactly.
##
## Build (nimony, explicit paths — neither repo has a nim.cfg):
##   nimony c -p:/home/savant/aifparser/src -p:/home/savant/nimony/src/lib \
##            css/aifsheet.nim

import ../../aifparser/src/cssparser
import ../../aifparser/src/css_view
import validator

type
  SheetFinding* = object
    selector*: string
    prop*: string
    value*: string
    error*: string     ## "" when the declaration validated

proc validateSheet*(src: string): seq[SheetFinding] =
  ## Every declaration in `src` that FAILS validation. An empty result means the
  ## stylesheet's values all match their MDN grammars.
  ##
  ## Custom properties (`--x`) are skipped: their value grammar is
  ## `<declaration-value>`, i.e. anything, so validating them is noise.
  result = @[]
  let aif = cssToAif(src)
  for d in cssDeclarations(aif):
    if d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-':
      continue
    let v = validateValue(d.prop, d.value)
    if not v.valid:
      result.add SheetFinding(selector: d.selector, prop: d.prop,
                              value: d.value, error: v.error)

proc sheetStats*(src: string): tuple[decls, invalid: int] =
  ## Counts without materialising every finding — for a quick corpus pass.
  let aif = cssToAif(src)
  var n = 0
  var bad = 0
  for d in cssDeclarations(aif):
    if d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-':
      continue
    n = n + 1
    if not validateValue(d.prop, d.value).valid:
      bad = bad + 1
  result = (n, bad)
