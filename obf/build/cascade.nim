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
## Scope: the argument of a functional pseudo (`:not(...)`, `:nth-child(...)`)
## is skipped for counting rather than recursed into — so `:not(.a.b)` counts as
## one pseudo-class, not its most-specific argument. Namespaces are ignored.

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
      if i + 1 < stop and sel[i+1] == ':':
        inc result.c            # ::pseudo-element
        inc i
        inc i
      else:
        inc result.b            # :pseudo-class
        inc i
      while i < stop and isIdentCharC(sel[i]): inc i
      # skip a functional argument (...) without recursing
      if i < stop and sel[i] == '(':
        var depth = 0
        while i < stop:
          if sel[i] == '(': inc depth
          elif sel[i] == ')':
            dec depth
            if depth == 0:
              inc i
              break
          inc i
    elif c == '*':
      inc i                     # universal — contributes nothing
    elif isIdentStartC(c):
      inc result.c              # type selector
      inc i
      while i < stop and isIdentCharC(sel[i]): inc i
    else:
      inc i                     # combinators, whitespace, commas

proc specificity*(sel: string): Specificity =
  ## Highest specificity across a comma-separated selector list.
  result = Specificity(a: 0, b: 0, c: 0)
  var i = 0
  var segStart = 0
  var depth = 0
  var seen = false
  while i <= sel.len:
    let atEnd = i == sel.len
    let c = (if atEnd: ',' else: sel[i])
    if not atEnd and c == '(':
      inc depth
    elif not atEnd and c == ')':
      if depth > 0: dec depth
    if (atEnd or c == ',') and depth == 0:
      let s = specificityOne(sel, segStart, i)
      if not seen or result < s:
        result = s
        seen = true
      segStart = i + 1
    inc i

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
