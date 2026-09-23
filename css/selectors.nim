## selectors.nim — parse and validate CSS selectors against Selectors-4.
##
## A hand-written recursive-descent parser over the character stream (no
## raising string slices — nimony-friendly) that builds a selector AST:
##
##   SelectorList = seq[Complex]
##   Complex      = Compound ( Combinator Compound )*
##   Compound     = Simple+      (type/universal first, pseudo-elements last)
##   Simple       = type | * | .class | #id | [attr op value flag] | :pseudo |
##                  ::pseudo-element | &      (with an optional ns| prefix)
##
## The same AST drives validation (`validateSelector`), specificity
## (`css/cascade`) and element matching (`css/match`), so the three can never
## disagree about what a selector says.
##
## What is checked:
##   * structure: compounds, all five combinators (descendant, `>`, `+`, `~`,
##     `||`), selector lists, namespaces (`ns|E`, `*|*`, `|E`, `[ns|a]`),
##     CSS escapes in identifiers (`.a\:b`, `#\31 0`), the nesting selector `&`
##     and relative selectors (`> a`) where nesting allows them;
##   * pseudo NAMES against the MDN data, and whether each one takes an argument
##     (`:hover()` and a bare `:not` are both errors);
##   * functional ARGUMENTS against their own grammars: An+B (`:nth-child(2n+1
##     of .x)`), selector lists (`:not`, `:is`, `:where` forgiving, `:has`
##     relative, no nested `:has`), compounds (`::slotted`, `:host`), idents
##     (`::part`, `::highlight`, `:state`, `:dir(ltr|rtl)`), `:lang()` ranges;
##   * placement: nothing but pseudo-classes and further pseudo-elements may
##     follow a pseudo-element (`::before.x` is an error).
##
## Browser-prefixed pseudos (`::-webkit-…`, `:-moz-…`) are accepted with any
## balanced argument: they are real, and MDN does not list them.

import data_load

type
  SimpleKind* = enum
    skType, skUniversal, skClass, skId, skAttr, skPseudoClass,
    skPseudoElement, skNesting

  AttrOp* = enum
    aoExists       ## [a]
    aoEquals       ## [a=v]
    aoIncludes     ## [a~=v]
    aoDashMatch    ## [a|=v]
    aoPrefix       ## [a^=v]
    aoSuffix       ## [a$=v]
    aoSubstring    ## [a*=v]

  Combinator* = enum
    cmNone, cmDescendant, cmChild, cmNextSibling, cmSubsequentSibling, cmColumn

  Simple* = object
    kind*: SimpleKind
    name*: string        ## type/attr name as written (unescaped); pseudo name
                         ## lower-cased; class/id value (unescaped)
    hasNs*: bool         ## a namespace prefix was written (`ns|`, `*|`, `|`)
    ns*: string          ## the prefix ("*" = any, "" = no namespace)
    op*: AttrOp
    value*: string       ## attribute value (unescaped, unquoted)
    caseFlag*: char      ## 'i' / 's' attribute modifier, or '\0'
    hasArg*: bool        ## functional pseudo: `(…)` was present
    arg*: string         ## the raw argument text
    a*, b*: int          ## An+B for the :nth-* family
    sub*: seq[Complex]   ## selector-list argument (:not/:is/:where/:has/
                         ## :nth-child of S/::slotted/:host/::cue)

  Compound* = object
    simples*: seq[Simple]

  Complex* = object
    lead*: Combinator    ## a relative selector's leading combinator (`> a`
                         ## in :has() or a nested rule), cmNone otherwise
    compounds*: seq[Compound]
    combs*: seq[Combinator]  ## combs[i] joins compounds[i] and compounds[i+1]

  SelectorList* = seq[Complex]

  SelState = object
    s: string
    pos: int
    err: string
    inHas: bool          ## parsing inside :has() — no nested :has, no ::pseudo

proc atEnd(st: SelState): bool = st.pos >= st.s.len
proc cur(st: SelState): char = (if st.pos < st.s.len: st.s[st.pos] else: '\0')
proc peekAt(st: SelState, k: int): char =
  (if st.pos + k < st.s.len: st.s[st.pos + k] else: '\0')

proc isIdentStart(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or ord(c) >= 128
proc isIdentChar(c: char): bool =
  isIdentStart(c) or (c >= '0' and c <= '9') or c == '-'
proc isDigitC(c: char): bool = c >= '0' and c <= '9'
proc isHex(c: char): bool =
  isDigitC(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')
proc isWs(c: char): bool =
  c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'

proc chStr(c: char): string =
  result = ""
  result.add c

proc toLower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32)
    else: result.add c
    inc i

proc fail(st: var SelState, msg: string): bool =
  if st.err.len == 0:
    st.err = msg & " at position " & $st.pos
  false

proc skipWs(st: var SelState): bool =
  ## Advance over whitespace and comments; return whether any was seen
  ## (matters: whitespace between compounds IS the descendant combinator).
  result = false
  while not atEnd(st):
    if isWs(cur(st)):
      inc st.pos
      result = true
    elif cur(st) == '/' and peekAt(st, 1) == '*':
      st.pos = st.pos + 2
      while not atEnd(st) and not (cur(st) == '*' and peekAt(st, 1) == '/'):
        inc st.pos
      if not atEnd(st): st.pos = st.pos + 2
      result = true
    else:
      break

# --- identifiers, with CSS escapes -------------------------------------------

proc addUtf8(s: var string, cp: int) =
  var c = cp
  if c == 0 or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF): c = 0xFFFD
  if c < 0x80:
    s.add char(c)
  elif c < 0x800:
    s.add char(0xC0 or (c shr 6))
    s.add char(0x80 or (c and 0x3F))
  elif c < 0x10000:
    s.add char(0xE0 or (c shr 12))
    s.add char(0x80 or ((c shr 6) and 0x3F))
    s.add char(0x80 or (c and 0x3F))
  else:
    s.add char(0xF0 or (c shr 18))
    s.add char(0x80 or ((c shr 12) and 0x3F))
    s.add char(0x80 or ((c shr 6) and 0x3F))
    s.add char(0x80 or (c and 0x3F))

proc hexVal(c: char): int =
  if isDigitC(c): ord(c) - ord('0')
  elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
  else: ord(c) - ord('A') + 10

proc validEscape(st: SelState, at: int): bool =
  ## `\` at `at` starts a valid escape: not followed by a newline or EOF.
  at < st.s.len and st.s[at] == '\\' and at + 1 < st.s.len and st.s[at+1] != '\n'

proc consumeEscape(st: var SelState, dest: var string) =
  ## `cur` is `\`. Append the escaped code point to `dest`.
  inc st.pos
  if isHex(cur(st)):
    var cp = 0
    var k = 0
    while k < 6 and isHex(cur(st)):
      cp = cp * 16 + hexVal(cur(st))
      inc st.pos
      inc k
    if isWs(cur(st)):
      if cur(st) == '\r' and peekAt(st, 1) == '\n': inc st.pos
      inc st.pos           # one whitespace after a hex escape is part of it
    addUtf8(dest, cp)
  else:
    dest.add cur(st)
    inc st.pos

proc startsIdent(st: SelState): bool =
  ## Would an identifier start here? (CSS Syntax §4.3.9)
  let c = cur(st)
  if isIdentStart(c): return true
  if c == '\\': return validEscape(st, st.pos)
  if c == '-':
    let d = peekAt(st, 1)
    return isIdentStart(d) or d == '-' or validEscape(st, st.pos + 1)
  false

proc readIdent(st: var SelState): string =
  ## An identifier with escapes decoded; "" if none starts here.
  result = ""
  if not startsIdent(st): return
  while not atEnd(st):
    let c = cur(st)
    if isIdentChar(c):
      result.add c
      inc st.pos
    elif c == '\\' and validEscape(st, st.pos):
      consumeEscape(st, result)
    else:
      break

proc readName(st: var SelState): string =
  ## A name (ident chars, may start with a digit) — for `#id` hash tokens.
  result = ""
  while not atEnd(st):
    let c = cur(st)
    if isIdentChar(c):
      result.add c
      inc st.pos
    elif c == '\\' and validEscape(st, st.pos):
      consumeEscape(st, result)
    else:
      break

proc readString(st: var SelState, value: var string): bool =
  ## `cur` is a quote. Read the string, decoding escapes.
  let q = cur(st)
  inc st.pos
  value = ""
  while not atEnd(st):
    let c = cur(st)
    if c == q:
      inc st.pos
      return true
    if c == '\n':
      return fail(st, "newline inside a string")
    if c == '\\':
      if peekAt(st, 1) == '\n':
        st.pos = st.pos + 2       # escaped newline: a line continuation
      elif st.pos + 1 >= st.s.len:
        inc st.pos
      else:
        consumeEscape(st, value)
    else:
      value.add c
      inc st.pos
  fail(st, "unterminated string")

# --- forward declarations ----------------------------------------------------

proc parseComplex(st: var SelState, relative: bool, c: var Complex): bool
proc parseCompound(st: var SelState, comp: var Compound): bool

proc parseListInto(st: var SelState, stop: char, relative, forgiving: bool,
                   list: var seq[Complex]): bool =
  ## A comma-separated list of (relative) complex selectors, up to `stop`
  ## (`)` inside a pseudo, '\0' for the top level). `forgiving` drops an
  ## invalid item instead of failing, as :is()/:where() do.
  discard skipWs(st)
  if forgiving and (cur(st) == stop or atEnd(st)): return true   # :is() is fine
  while true:
    discard skipWs(st)
    let itemStart = st.pos
    var c = Complex(lead: cmNone, compounds: @[], combs: @[])
    let savedErr = st.err
    var ok = parseComplex(st, relative, c)
    if ok:
      discard skipWs(st)
      if not (atEnd(st) or cur(st) == ',' or cur(st) == stop):
        ok = fail(st, "unexpected '" & chStr(cur(st)) & "'")
    if ok:
      list.add c
    elif forgiving:
      # skip the bad item up to the next top-level comma / the stop char
      st.err = savedErr
      st.pos = itemStart
      var depth = 0
      while not atEnd(st):
        let ch = cur(st)
        if ch == '(' or ch == '[': inc depth
        elif ch == ')' or ch == ']':
          if depth == 0: break
          dec depth
        elif ch == ',' and depth == 0: break
        elif ch == '"' or ch == '\'':
          var tmp = ""
          discard readString(st, tmp)
          continue
        inc st.pos
    else:
      return false
    discard skipWs(st)
    if cur(st) == ',':
      inc st.pos
      continue
    break
  true

# --- functional pseudo arguments ---------------------------------------------

proc argEnd(st: SelState, open: int): int =
  ## Index of the `)` closing the `(` at `open` (strings respected); -1 if none.
  var depth = 0
  var i = open
  while i < st.s.len:
    let c = st.s[i]
    if c == '\\':
      i += 2
      continue
    if c == '"' or c == '\'':
      inc i
      while i < st.s.len and st.s[i] != c:
        if st.s[i] == '\\': inc i
        inc i
    elif c == '(':
      inc depth
    elif c == ')':
      dec depth
      if depth == 0: return i
    inc i
  -1

proc parseAnB(st: var SelState, a, b: var int): bool =
  ## An+B microsyntax: `odd`, `even`, `3`, `-n+2`, `2n`, `+n - 1`, `-2n+ 3`.
  discard skipWs(st)
  let l = toLower(readIdent(st))
  if l == "odd":
    a = 2; b = 1
    return true
  if l == "even":
    a = 2; b = 0
    return true
  # Not a keyword: re-scan by hand (an ident read above may be "n", "-n",
  # "n-1", "-n-2" — all ident-shaped in CSS Syntax).
  var sign = 1
  var p = 0
  var buf = ""
  if l.len > 0:
    buf = l
  else:
    if cur(st) == '+' or cur(st) == '-':
      if cur(st) == '-': sign = -1
      inc st.pos
      if isWs(cur(st)): return fail(st, "no whitespace allowed after the sign in An+B")
    while isDigitC(cur(st)):
      buf.add cur(st)
      inc st.pos
    if cur(st) == 'n' or cur(st) == 'N':
      buf.add 'n'
      inc st.pos
      # an ident run may continue ("n-1" is one token)
      while cur(st) == '-' or isDigitC(cur(st)):
        buf.add cur(st)
        inc st.pos
  if buf.len == 0: return fail(st, "expected An+B")
  # buf is now like "2n", "-n", "n-1", "-2n-3", "3"
  var i = 0
  if buf[0] == '-':
    sign = -sign
    i = 1
  var digits = ""
  while i < buf.len and isDigitC(buf[i]):
    digits.add buf[i]
    inc i
  if i >= buf.len:
    # just a number: B only
    a = 0
    var v = 0
    var k = 0
    while k < digits.len:
      v = v * 10 + (ord(digits[k]) - ord('0'))
      inc k
    b = sign * v
    discard skipWs(st)
    return true
  if buf[i] != 'n': return fail(st, "expected An+B")
  inc i
  var av = 1
  if digits.len > 0:
    av = 0
    var k = 0
    while k < digits.len:
      av = av * 10 + (ord(digits[k]) - ord('0'))
      inc k
  a = sign * av
  b = 0
  # an inline "-B" glued to the n: "n-1"
  if i < buf.len:
    if buf[i] != '-': return fail(st, "expected An+B")
    inc i
    if i >= buf.len:
      # "n-" then whitespace then digits: "n- 1"
      discard skipWs(st)
      var v = 0
      var seen = false
      while isDigitC(cur(st)):
        v = v * 10 + (ord(cur(st)) - ord('0'))
        inc st.pos
        seen = true
      if not seen: return fail(st, "expected a number after '-' in An+B")
      b = -v
      discard skipWs(st)
      return true
    var v = 0
    while i < buf.len:
      if not isDigitC(buf[i]): return fail(st, "expected An+B")
      v = v * 10 + (ord(buf[i]) - ord('0'))
      inc i
    b = -v
    discard skipWs(st)
    return true
  discard skipWs(st)
  if cur(st) == '+' or cur(st) == '-':
    let neg = cur(st) == '-'
    inc st.pos
    discard skipWs(st)
    var v = 0
    var seen = false
    while isDigitC(cur(st)):
      v = v * 10 + (ord(cur(st)) - ord('0'))
      inc st.pos
      seen = true
    if not seen: return fail(st, "expected a number after the sign in An+B")
    b = (if neg: -v else: v)
    discard skipWs(st)
  true

proc isNthFamily(name: string): bool =
  name == "nth-child" or name == "nth-last-child" or name == "nth-of-type" or
    name == "nth-last-of-type" or name == "nth-col" or name == "nth-last-col"

proc takesSelectorList(name: string): bool =
  name == "not" or name == "is" or name == "where" or name == "matches" or
    name == "any" or name == "-webkit-any" or name == "-moz-any" or name == "has"

proc requiresArg(name: string, element: bool): bool =
  ## Functional-only pseudos: the bare form is an error.
  if element:
    name == "part" or name == "slotted" or name == "highlight" or
      name == "view-transition-group" or name == "view-transition-image-pair" or
      name == "view-transition-old" or name == "view-transition-new" or
      name == "picker" or name == "scroll-button"
  else:
    isNthFamily(name) or takesSelectorList(name) or name == "lang" or
      name == "dir" or name == "state" or name == "host-context" or
      name == "active-view-transition-type" or name == "heading"

proc optionalArg(name: string): bool =
  ## Pseudos that are valid both bare and with an argument.
  name == "host" or name == "cue" or name == "cue-region" or
    name == "active-view-transition"

proc parseIdentList(st: var SelState, stop: int, commas: bool, what: string): bool =
  ## One or more idents up to `stop`, space- or comma-separated.
  var n = 0
  while true:
    discard skipWs(st)
    if st.pos >= stop: break
    if readIdent(st).len == 0: return fail(st, "expected " & what)
    inc n
    discard skipWs(st)
    if commas and cur(st) == ',':
      inc st.pos
      discard skipWs(st)
      if st.pos >= stop: return fail(st, "expected " & what & " after ','")
  if n == 0: return fail(st, "expected " & what)
  true

proc parsePseudoArg(st: var SelState, sp: var Simple, element: bool, stop: int): bool =
  ## Parse `sp`'s argument (st.pos just past `(`, `stop` is the `)`).
  let name = sp.name
  if not element and isNthFamily(name):
    var a = 0
    var b = 0
    if not parseAnB(st, a, b): return false
    sp.a = a
    sp.b = b
    discard skipWs(st)
    if st.pos < stop:
      let save = st.pos
      let w = toLower(readIdent(st))
      if w == "of" and (name == "nth-child" or name == "nth-last-child"):
        if not parseListInto(st, ')', false, false, sp.sub): return false
        if sp.sub.len == 0: return fail(st, "expected a selector after 'of'")
      else:
        st.pos = save
        return fail(st, "unexpected text after An+B")
    return true
  if not element and takesSelectorList(name):
    let forgiving = name == "is" or name == "where" or name == "matches" or
                    name == "any" or name == "-webkit-any" or name == "-moz-any"
    let relative = name == "has"
    if relative and st.inHas: return fail(st, ":has() cannot be nested inside :has()")
    let savedHas = st.inHas
    if relative: st.inHas = true
    let ok = parseListInto(st, ')', relative, forgiving, sp.sub)
    st.inHas = savedHas
    if not ok: return false
    if not forgiving and sp.sub.len == 0:
      return fail(st, ":" & name & "() needs a selector")
    return true
  if (element and name == "slotted") or (not element and (name == "host" or name == "host-context")):
    discard skipWs(st)
    var comp = Compound(simples: @[])
    if not parseCompound(st, comp): return false
    sp.sub.add Complex(lead: cmNone, compounds: @[comp], combs: @[])
    discard skipWs(st)
    return true
  if element and (name == "cue" or name == "cue-region") or
     (not element and (name == "cue" or name == "cue-region")):
    return parseListInto(st, ')', false, false, sp.sub)
  if element and name == "part":
    return parseIdentList(st, stop, false, "a part name")
  if (element and (name == "highlight" or name == "picker")) or
     (not element and name == "state"):
    discard skipWs(st)
    if readIdent(st).len == 0: return fail(st, "expected an identifier")
    discard skipWs(st)
    return true
  if not element and name == "dir":
    discard skipWs(st)
    let d = toLower(readIdent(st))
    if d != "ltr" and d != "rtl": return fail(st, ":dir() takes ltr or rtl")
    discard skipWs(st)
    return true
  if not element and name == "active-view-transition-type":
    return parseIdentList(st, stop, true, "a transition type")
  if not element and name == "lang":
    var n = 0
    while true:
      discard skipWs(st)
      if cur(st) == '"' or cur(st) == '\'':
        var v = ""
        if not readString(st, v): return false
      elif readIdent(st).len == 0:
        return fail(st, "expected a language tag")
      inc n
      discard skipWs(st)
      if cur(st) == ',':
        inc st.pos
        continue
      break
    return true
  if element and (name == "view-transition-group" or name == "view-transition-image-pair" or
                  name == "view-transition-old" or name == "view-transition-new"):
    discard skipWs(st)
    if cur(st) == '*':
      inc st.pos
    elif readIdent(st).len == 0:
      if cur(st) != '.': return fail(st, "expected '*' or a view-transition name")
    while cur(st) == '.':
      inc st.pos
      if readIdent(st).len == 0: return fail(st, "expected a class after '.'")
    discard skipWs(st)
    return true
  if element and name == "scroll-button":
    discard skipWs(st)
    if cur(st) == '*': inc st.pos
    elif readIdent(st).len == 0: return fail(st, "expected '*' or a direction")
    discard skipWs(st)
    return true
  # A pseudo we know takes an argument but has no grammar here (or a vendor
  # one): accept any balanced argument.
  st.pos = stop
  true

# --- simple selectors ----------------------------------------------------------

proc parseAttribute(st: var SelState, sp: var Simple): bool =
  ## `[` [ns|]attr ( op value flag? )? `]`   (cur is `[`)
  inc st.pos
  discard skipWs(st)
  sp = Simple(kind: skAttr, op: aoExists, caseFlag: '\0')
  # optional namespace prefix: ns|a, *|a, |a  (but not the |= operator)
  if cur(st) == '*' and peekAt(st, 1) == '|' and peekAt(st, 2) != '=':
    sp.hasNs = true
    sp.ns = "*"
    st.pos = st.pos + 2
  elif cur(st) == '|' and peekAt(st, 1) != '=':
    sp.hasNs = true
    sp.ns = ""
    inc st.pos
  var attr = readIdent(st)
  if attr.len > 0 and cur(st) == '|' and peekAt(st, 1) != '=' and not sp.hasNs:
    sp.hasNs = true
    sp.ns = attr
    inc st.pos
    attr = readIdent(st)
  if attr.len == 0: return fail(st, "expected attribute name")
  sp.name = attr
  discard skipWs(st)
  if cur(st) == ']':
    inc st.pos
    return true
  let c = cur(st)
  if c == '~' or c == '|' or c == '^' or c == '$' or c == '*':
    inc st.pos
    if cur(st) != '=': return fail(st, "expected '=' after attribute operator")
    inc st.pos
    case c
    of '~': sp.op = aoIncludes
    of '|': sp.op = aoDashMatch
    of '^': sp.op = aoPrefix
    of '$': sp.op = aoSuffix
    else: sp.op = aoSubstring
  elif c == '=':
    inc st.pos
    sp.op = aoEquals
  else:
    return fail(st, "expected attribute operator or ']'")
  discard skipWs(st)
  if cur(st) == '"' or cur(st) == '\'':
    var v = ""
    if not readString(st, v): return false
    sp.value = v
  else:
    let v = readIdent(st)
    if v.len == 0:
      return fail(st, "expected an identifier or a string as the attribute value")
    sp.value = v
  let hadWs = skipWs(st)
  let f = cur(st)
  if (f == 'i' or f == 'I' or f == 's' or f == 'S') and not isIdentChar(peekAt(st, 1)):
    discard hadWs
    sp.caseFlag = (if f == 'I' or f == 'i': 'i' else: 's')
    inc st.pos
    discard skipWs(st)
  if cur(st) != ']': return fail(st, "expected ']'")
  inc st.pos
  true

proc parsePseudo(st: var SelState, sp: var Simple): bool =
  ## `:`name  or  `::`name  or  `:`name`(`…`)`   (cur is `:`)
  inc st.pos
  var element = false
  if cur(st) == ':':
    element = true
    inc st.pos
  let raw = readIdent(st)
  if raw.len == 0: return fail(st, "expected name after ':'")
  let l = toLower(raw)
  sp = Simple(kind: (if element: skPseudoElement else: skPseudoClass), name: l,
              caseFlag: '\0')
  let vendor = l.len > 0 and l[0] == '-'
  # the legacy one-colon spellings of four pseudo-elements
  if not element and (l == "before" or l == "after" or l == "first-line" or
                      l == "first-letter"):
    sp.kind = skPseudoElement
  if not vendor:
    if element:
      if not isPseudoElement(l): return fail(st, "unknown pseudo-element '::" & raw & "'")
    elif not isPseudoClass(l) and not isPseudoElement(l):
      return fail(st, "unknown pseudo-class ':" & raw & "'")
    if sp.kind == skPseudoElement and st.inHas:
      return fail(st, "pseudo-elements are not allowed inside :has()")
  if cur(st) == '(':
    let stop = argEnd(st, st.pos)
    if stop < 0: return fail(st, "unbalanced '(' in pseudo argument")
    let fnKnown = requiresArg(l, element) or optionalArg(l) or
                  (element and isFunctionalPseudoElement(l)) or
                  (not element and isFunctionalPseudoClass(l))
    if not vendor and not fnKnown:
      return fail(st, "'" & (if element: "::" else: ":") & raw & "' does not take an argument")
    sp.hasArg = true
    var arg = ""
    var k = st.pos + 1
    while k < stop:
      arg.add st.s[k]
      inc k
    sp.arg = arg
    inc st.pos
    if vendor:
      st.pos = stop
    elif not parsePseudoArg(st, sp, element, stop):
      return false
    discard skipWs(st)
    if st.pos != stop:
      return fail(st, "unexpected '" & chStr(cur(st)) & "' in :" & l & "()")
    st.pos = stop + 1
  elif not vendor and requiresArg(l, element):
    return fail(st, "'" & (if element: "::" else: ":") & raw & "' requires an argument")
  true

proc parseCompound(st: var SelState, comp: var Compound): bool =
  ## One compound selector: optional type/universal + any number of subclasses.
  var afterPseudoElement = false
  # type / universal, with an optional namespace prefix
  var nsPrefix = ""
  var hasNs = false
  let start = st.pos
  if cur(st) == '|' and peekAt(st, 1) != '|':
    hasNs = true
    inc st.pos
  elif cur(st) == '*' and peekAt(st, 1) == '|' and peekAt(st, 2) != '|' and peekAt(st, 2) != '=':
    hasNs = true
    nsPrefix = "*"
    st.pos = st.pos + 2
  elif startsIdent(st):
    let save = st.pos
    let w = readIdent(st)
    if cur(st) == '|' and peekAt(st, 1) != '|' and peekAt(st, 1) != '=':
      hasNs = true
      nsPrefix = w
      inc st.pos
    else:
      st.pos = save
  if cur(st) == '*':
    inc st.pos
    comp.simples.add Simple(kind: skUniversal, name: "*", hasNs: hasNs, ns: nsPrefix, caseFlag: '\0')
  elif startsIdent(st):
    let w = readIdent(st)
    comp.simples.add Simple(kind: skType, name: w, hasNs: hasNs, ns: nsPrefix, caseFlag: '\0')
  elif hasNs:
    st.pos = start
    return fail(st, "expected a type or '*' after the namespace prefix")
  while not atEnd(st):
    let c = cur(st)
    if c == '.':
      if afterPseudoElement: return fail(st, "a class cannot follow a pseudo-element")
      inc st.pos
      let n = readIdent(st)
      if n.len == 0: return fail(st, "expected class name after '.'")
      comp.simples.add Simple(kind: skClass, name: n, caseFlag: '\0')
    elif c == '#':
      if afterPseudoElement: return fail(st, "an id cannot follow a pseudo-element")
      inc st.pos
      # an ID selector needs an "id"-type hash: `#1a` is a hash token, but not
      # one a selector accepts (the name must be a valid identifier)
      if not startsIdent(st):
        return fail(st, "an id must be a valid identifier (escape a leading digit: #\\31 …)")
      let n = readName(st)
      if n.len == 0: return fail(st, "expected id name after '#'")
      comp.simples.add Simple(kind: skId, name: n, caseFlag: '\0')
    elif c == '[':
      if afterPseudoElement: return fail(st, "an attribute selector cannot follow a pseudo-element")
      var sp = Simple()
      if not parseAttribute(st, sp): return false
      comp.simples.add sp
    elif c == ':':
      var sp = Simple()
      if not parsePseudo(st, sp): return false
      if sp.kind == skPseudoElement: afterPseudoElement = true
      comp.simples.add sp
    elif c == '&':
      if afterPseudoElement: return fail(st, "'&' cannot follow a pseudo-element")
      inc st.pos
      comp.simples.add Simple(kind: skNesting, name: "&", caseFlag: '\0')
    elif c == '*' or startsIdent(st):
      if comp.simples.len > 0:
        return fail(st, "a type selector must come first in a compound selector")
      break
    else:
      break
  if comp.simples.len == 0: return fail(st, "expected a selector")
  true

proc readCombinator(st: var SelState): Combinator =
  ## An explicit combinator at the cursor (consumed), or cmNone.
  let c = cur(st)
  if c == '>':
    inc st.pos
    return cmChild
  if c == '+':
    inc st.pos
    return cmNextSibling
  if c == '~' and peekAt(st, 1) != '=':
    inc st.pos
    return cmSubsequentSibling
  if c == '|' and peekAt(st, 1) == '|':
    st.pos = st.pos + 2
    return cmColumn
  cmNone

proc parseComplex(st: var SelState, relative: bool, c: var Complex): bool =
  ## [combinator]? compound ( combinator compound )*
  discard skipWs(st)
  if relative:
    c.lead = readCombinator(st)
    discard skipWs(st)
  var first = Compound(simples: @[])
  if not parseCompound(st, first): return false
  c.compounds.add first
  while true:
    let hadWs = skipWs(st)
    if atEnd(st): break
    let ch = cur(st)
    if ch == ',' or ch == ')': break
    var comb = readCombinator(st)
    if comb != cmNone:
      discard skipWs(st)
    elif hadWs:
      comb = cmDescendant
    else:
      break
    if atEnd(st) or cur(st) == ',' or cur(st) == ')':
      return fail(st, "expected a selector after the combinator")
    var next = Compound(simples: @[])
    if not parseCompound(st, next): return false
    c.combs.add comb
    c.compounds.add next
  true

# --- public API ----------------------------------------------------------------

proc parseSelector*(sel: string, relative = false):
    tuple[ok: bool, list: SelectorList, error: string] =
  ## Parse a selector list into its AST. `relative` allows each item to begin
  ## with a combinator — the form nested style rules take (`> .child`).
  var st = SelState(s: sel, pos: 0, err: "", inHas: false)
  var list: seq[Complex] = @[]
  discard skipWs(st)
  if atEnd(st): return (false, list, "empty selector")
  if not parseListInto(st, '\0', relative, false, list):
    return (false, list, st.err)
  discard skipWs(st)
  if not atEnd(st):
    discard fail(st, "unexpected '" & chStr(cur(st)) & "'")
    return (false, list, st.err)
  (true, list, "")

proc validateSelector*(sel: string): tuple[valid: bool, error: string] =
  ## Validate a CSS selector (or selector list). Returns (valid, human error).
  let r = parseSelector(sel, false)
  (r.ok, r.error)

proc validateNestedSelector*(sel: string): tuple[valid: bool, error: string] =
  ## Validate the selector of a NESTED style rule (CSS Nesting): each item may
  ## start with a combinator (`> .x`, `+ li`) and may use `&` anywhere.
  let r = parseSelector(sel, true)
  (r.ok, r.error)

proc selectorValid*(sel: string): bool = validateSelector(sel).valid

# --- rendering (canonical form) ------------------------------------------------

proc escIdent(s: string): string =
  ## Serialise an identifier, escaping what would not re-parse as one.
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if isIdentChar(c) and not (i == 0 and isDigitC(c)) and
       not (i == 1 and isDigitC(c) and s[0] == '-'):
      result.add c
    elif i == 0 and c == '-' and s.len > 1:
      result.add c
    elif isDigitC(c):
      const hexd = "0123456789abcdef"
      result.add '\\'
      result.add hexd[ord(c) shr 4]
      result.add hexd[ord(c) and 15]
      result.add ' '
    else:
      result.add '\\'
      result.add c
    inc i

proc escString(s: string): string =
  result = "\""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '"' or c == '\\': result.add '\\'
    if c == '\n': result.add "\\a "
    else: result.add c
    inc i
  result.add '"'

proc renderList*(list: SelectorList): string

proc renderAnB(a, b: int): string =
  if a == 0: return $b
  result = ""
  if a == 1: result = "n"
  elif a == -1: result = "-n"
  else: result = $a & "n"
  if b > 0: result.add "+" & $b
  elif b < 0: result.add $b

proc renderSimple(sp: Simple): string =
  var nsp = ""
  if sp.hasNs: nsp = (if sp.ns == "*": "*" else: escIdent(sp.ns)) & "|"
  case sp.kind
  of skType: nsp & escIdent(sp.name)
  of skUniversal: nsp & "*"
  of skClass: "." & escIdent(sp.name)
  of skId: "#" & escIdent(sp.name)
  of skNesting: "&"
  of skAttr:
    var r = "[" & nsp & escIdent(sp.name)
    if sp.op != aoExists:
      case sp.op
      of aoEquals: r.add "="
      of aoIncludes: r.add "~="
      of aoDashMatch: r.add "|="
      of aoPrefix: r.add "^="
      of aoSuffix: r.add "$="
      of aoSubstring: r.add "*="
      of aoExists: discard
      r.add escString(sp.value)
      if sp.caseFlag != '\0':
        r.add ' '
        r.add sp.caseFlag
    r & "]"
  of skPseudoClass, skPseudoElement:
    var r = (if sp.kind == skPseudoElement: "::" else: ":") & sp.name
    if sp.hasArg:
      r.add "("
      if isNthFamily(sp.name):
        r.add renderAnB(sp.a, sp.b)
        if sp.sub.len > 0: r.add " of " & renderList(sp.sub)
      elif sp.sub.len > 0:
        r.add renderList(sp.sub)
      else:
        r.add sp.arg
      r.add ")"
    r

proc combStr(c: Combinator): string =
  case c
  of cmNone: ""
  of cmDescendant: " "
  of cmChild: " > "
  of cmNextSibling: " + "
  of cmSubsequentSibling: " ~ "
  of cmColumn: " || "

proc renderComplex*(c: Complex): string =
  result = ""
  if c.lead != cmNone:
    var l = combStr(c.lead)
    # drop the leading space: "> a", not " > a"
    var k = 1
    while k < l.len:
      result.add l[k]
      inc k
  var i = 0
  while i < c.compounds.len:
    if i > 0: result.add combStr(c.combs[i-1])
    var j = 0
    while j < c.compounds[i].simples.len:
      result.add renderSimple(c.compounds[i].simples[j])
      inc j
    inc i

proc renderList*(list: SelectorList): string =
  result = ""
  var i = 0
  while i < list.len:
    if i > 0: result.add ", "
    result.add renderComplex(list[i])
    inc i

proc normalizeSelector*(sel: string): string =
  ## The canonical spelling of a valid selector (whitespace normalised,
  ## escapes resolved and re-escaped minimally, attribute values quoted);
  ## `""` if the selector is invalid.
  let r = parseSelector(sel, true)
  if not r.ok: return ""
  renderList(r.list)
