## data_load.nim — parse the generated blobs into lookup tables.
##
## Deliberately dependency-light: no std/json (keeps nimony compiles cheap), and
## no raising string slices (`s[a..b]` is `.raises` in nimony) — we walk the blob
## one char at a time. Tables are built once at module init.

import std/tables
import data

proc parseBlob(blob: string): Table[string, string] =
  ## Split a "key\tval\n…" blob into a Table. Pure char-walk, non-raising.
  result = initTable[string, string]()
  var key = ""
  var val = ""
  var inKey = true
  var i = 0
  while i < blob.len:
    let c = blob[i]
    if c == '\n':
      if key.len > 0: result[key] = val
      key = ""
      val = ""
      inKey = true
    elif c == '\t':
      inKey = false
    else:
      if inKey: key.add c
      else: val.add c
    inc i
  if key.len > 0: result[key] = val

# Built once, at import time.
let cssProperties* = parseBlob(cssPropertyBlob)  ## property name -> value-definition syntax
let cssSyntaxes*   = parseBlob(cssSyntaxBlob)    ## <syntax-name> -> value-definition syntax
let cssTypes*      = parseBlob(cssTypeBlob)      ## basic data type name -> "" (membership set)
let cssUnits*      = parseBlob(cssUnitBlob)      ## unit -> dimension bucket (length/angle/…)
let cssAtRules*    = parseBlob(cssAtRuleBlob)    ## @rule -> syntax
let cssPseudoClasses*  = parseBlob(cssPseudoClassBlob)    ## pseudo-class name (no `:`) -> "1" if functional
let cssPseudoElements* = parseBlob(cssPseudoElementBlob)  ## pseudo-element name (no `::`) -> "1" if functional

# --- accessors -------------------------------------------------------------

proc isProperty*(name: string): bool = cssProperties.hasKey(name)
proc propertySyntax*(name: string): string = cssProperties.getOrDefault(name, "")

proc isSyntax*(name: string): bool = cssSyntaxes.hasKey(name)
proc syntaxOf*(name: string): string = cssSyntaxes.getOrDefault(name, "")

proc isType*(name: string): bool = cssTypes.hasKey(name)

proc isUnit*(name: string): bool = cssUnits.hasKey(name)
proc unitDimension*(name: string): string = cssUnits.getOrDefault(name, "")

proc isAtRule*(name: string): bool = cssAtRules.hasKey(name)

proc isPseudoClass*(name: string): bool = cssPseudoClasses.hasKey(name)
proc isPseudoElement*(name: string): bool = cssPseudoElements.hasKey(name)
proc isFunctionalPseudoClass*(name: string): bool = cssPseudoClasses.getOrDefault(name, "") == "1"
proc isFunctionalPseudoElement*(name: string): bool = cssPseudoElements.getOrDefault(name, "") == "1"
