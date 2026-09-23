## cascade.aowl — CSS specificity and a minimal cascade resolver.
##
## `specificity(sel)` returns the (a, b, c) triple defined by Selectors-4:
##   a = #id selectors
##   b = .class, [attr] and :pseudo-class selectors
##   c = type selectors and ::pseudo-element selectors
## The universal selector `*` and combinators contribute nothing. For a
## comma-separated list, `specificity` returns the highest triple in the list
## (the convention used when a single rule carries several selectors).
##
## `cascade(decls)` resolves a set of declarations to the winning value per
## property, ordered by (specificity, then source order) — the core of "computed
## styles" without inheritance/initial-value resolution.
##
## Two rules here are easy to get wrong and both change which rule wins:
##
## * `:before`, `:after`, `:first-line` and `:first-letter` are the LEGACY
##   one-colon spellings of pseudo-ELEMENTS. They count in `c`, exactly as
##   `::after` does, not in `b`. Counting them as pseudo-classes makes
##   `.tab:after` beat `.tab.active`, which is the wrong rule painting.
## * `:not()`, `:is()` and `:has()` contribute NOTHING themselves and take the
##   specificity of their most specific argument, so `:not(#id)` is worth an
##   id. `:where()` contributes nothing at all, argument included.
##
## `:nth-child(An+B of S)` is worth a pseudo-class PLUS its most specific `S`;
## `::slotted(X)` and `:host(X)` are worth themselves plus `X`. The nesting
## selector `&` counts as nothing here (it takes its parent rule's specificity,
## which a lone selector string does not know). Namespaces are ignored.
##
## A valid selector is counted from its parsed AST (`css/selectors`), the same
## tree validation and matching use; an invalid one falls back to a tolerant
## character walk so a best-effort answer is still available.

import selectors

type Specificity* = object
  a*: int   ## id selectors
  b*: int   ## class / attribute / pseudo-class selectors
  c*: int   ## type / pseudo-element selectors

proc isIdentStartC(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-' or ord(c) >= 128
proc isIdentCharC(c: char): bool =
  isIdentStartC(c) or (c >= '0' and c <= '9')
proc isWsC(c: char): bool =
  c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'

proc `<`*(x, y: Specificity): bool =
  ## Cascade ordering: compare a, then b, then c.
  if x.a != y.a: return x.a < y.a
  if x.b != y.b: return x.b < y.b
  x.c < y.c

proc `==`*(x, y: Specificity): bool =
  x.a == y.a and x.b == y.b and x.c == y.c

proc `$`*(s: Specificity): string =
  "(" & $s.a & "," & $s.b & "," & $s.c & ")"

proc toLowerC(s: string, start, stop: int): string =
  result = ""
  var i = start
  while i < stop:
    var c = s[i]
    if c >= 'A' and c <= 'Z': c = chr(ord(c) + 32)
    result.add c
    inc i

proc isLegacyPseudoElement(name: string): bool =
  ## The four that predate `::` and are still written with one colon more
  ## often than not. Everything else spelled with one colon is a class.
  name == "before" or name == "after" or name == "first-line" or
    name == "first-letter"

proc takesArgumentSpecificity(name: string): bool =
  ## The selector-list pseudos, whose specificity IS their argument's.
  ## `:where` is handled separately because it takes nothing at all.
  name == "not" or name == "is" or name == "has" or name == "matches" or
    name == "any" or name == "-moz-any" or name == "-webkit-any"

proc roughRange(sel: string, start, stop: int): Specificity

proc specificityOne(sel: string, start, stop: int): Specificity =
  ## Count one complex selector occupying sel[start ..< stop].
  result = Specificity(a: 0, b: 0, c: 0)
  var i = start
  while i < stop:
    let c = sel[i]
    if c == '#':
      inc result.a
      inc i
      while i < stop and isIdentCharC(sel[i]): inc i
    elif c == '.':
      inc result.b
      inc i
      while i < stop and isIdentCharC(sel[i]): inc i
    elif c == '[':
      inc result.b
      # skip to matching ] (attribute selectors don't nest)
      inc i
      while i < stop and sel[i] != ']': inc i
      if i < stop: inc i
    elif c == ':':
      var doubled = false
      inc i
      if i < stop and sel[i] == ':':
        doubled = true
        inc i
      let nameAt = i
      while i < stop and isIdentCharC(sel[i]): inc i
      let name = toLowerC(sel, nameAt, i)
      # Find the functional argument, if any, before deciding anything: the
      # name alone does not say whether this one takes its argument.
      var argStart = -1
      var argStop = -1
      if i < stop and sel[i] == '(':
        var depth = 0
        argStart = i + 1
        while i < stop:
          if sel[i] == '(': inc depth
          elif sel[i] == ')':
            dec depth
            if depth == 0:
              argStop = i
              inc i
              break
          inc i
        if argStop < 0: argStop = stop
      if doubled or isLegacyPseudoElement(name):
        inc result.c
      elif name == "where":
        discard                 # contributes nothing, argument included
      elif argStart >= 0 and takesArgumentSpecificity(name):
        # The pseudo itself is worth nothing; its argument is worth whatever
        # the most specific thing inside it is worth.
        let inner = roughRange(sel, argStart, argStop)
        result.a = result.a + inner.a
        result.b = result.b + inner.b
        result.c = result.c + inner.c
      else:
        inc result.b            # an ordinary pseudo-class
    elif c == '*':
      inc i                     # universal — contributes nothing
    elif isIdentStartC(c):
      inc result.c              # type selector
      inc i
      while i < stop and isIdentCharC(sel[i]): inc i
    else:
      inc i                     # combinators, whitespace, commas

proc roughRange(sel: string, start, stop: int): Specificity =
  ## Highest specificity across a comma-separated list inside sel[start..<stop].
  result = Specificity(a: 0, b: 0, c: 0)
  var i = start
  var segStart = start
  var depth = 0
  var seen = false
  while i <= stop:
    let atEnd = i == stop
    let c = (if atEnd: ',' else: sel[i])
    if not atEnd and c == '(':
      inc depth
    elif not atEnd and c == ')':
      if depth > 0: dec depth
    if (atEnd or c == ',') and depth == 0:
      let one = specificityOne(sel, segStart, i)
      if not seen or result < one:
        result = one
        seen = true
      segStart = i + 1
    inc i

proc add(x: var Specificity, y: Specificity) =
  x.a = x.a + y.a
  x.b = x.b + y.b
  x.c = x.c + y.c

proc ofList*(list: SelectorList): Specificity
proc ofComplex*(c: Complex): Specificity

proc ofSimple(sp: Simple): Specificity =
  result = Specificity(a: 0, b: 0, c: 0)
  case sp.kind
  of skId: result.a = 1
  of skClass, skAttr: result.b = 1
  of skType: result.c = 1
  of skUniversal, skNesting: discard
  of skPseudoElement:
    result.c = 1
    if sp.name == "slotted" and sp.sub.len > 0: result.add ofList(sp.sub)
  of skPseudoClass:
    if sp.name == "where":
      discard
    elif takesArgumentSpecificity(sp.name):
      result = ofList(sp.sub)
    else:
      result.b = 1
      if sp.sub.len > 0:        # :nth-child(… of S), :host(X), :host-context(X)
        result.add ofList(sp.sub)

proc ofComplex*(c: Complex): Specificity =
  ## Specificity of one parsed complex selector.
  result = Specificity(a: 0, b: 0, c: 0)
  var i = 0
  while i < c.compounds.len:
    var j = 0
    while j < c.compounds[i].simples.len:
      result.add ofSimple(c.compounds[i].simples[j])
      inc j
    inc i

proc ofList*(list: SelectorList): Specificity =
  ## The most specific item of a parsed selector list.
  result = Specificity(a: 0, b: 0, c: 0)
  var i = 0
  while i < list.len:
    let one = ofComplex(list[i])
    if i == 0 or result < one: result = one
    inc i

proc specificity*(sel: string): Specificity =
  ## Highest specificity across a comma-separated selector list.
  let r = parseSelector(sel, true)
  if r.ok: ofList(r.list)
  else: roughRange(sel, 0, sel.len)

type Decl* = object
  selector*: string
  property*: string
  value*: string

type Winner* = object
  property*: string
  value*: string
  spec*: Specificity
  order*: int

proc cascade*(decls: openArray[Decl]): seq[Winner] =
  ## Resolve declarations to the winning value per property. A later declaration
  ## wins over an earlier one of equal specificity (source order); higher
  ## specificity always wins.
  result = @[]
  var order = 0
  for d in decls:
    let sp = specificity(d.selector)
    var found = -1
    var j = 0
    while j < result.len:
      if result[j].property == d.property:
        found = j
      inc j
    if found < 0:
      result.add Winner(property: d.property, value: d.value, spec: sp, order: order)
    else:
      let cur = result[found]
      if cur.spec < sp or (cur.spec == sp and cur.order <= order):
        result[found] = Winner(property: d.property, value: d.value, spec: sp, order: order)
    inc order
