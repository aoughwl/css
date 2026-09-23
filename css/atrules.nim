## atrules.nim — validate at-rule preludes against their own grammars.
##
## A stylesheet parser can only tell you that `@media screen and (min-widht:
## 600px) { … }` is an at-rule with a prelude and a block. This module reads
## the prelude:
##
##   @media       <media-query-list>            Media Queries 4/5, range syntax
##   @supports    <supports-condition>          incl. selector(), font-tech()…
##   @container   [<name>]? <container-query>   size, style() and scroll-state()
##   @import      url [layer[(…)]] [supports(…)] [<media-query-list>]
##   @layer       <layer-name># (statement) | <layer-name>? (block)
##   @keyframes   <custom-ident> | <string>     + keyframe selectors (from/to/%)
##   @page        [ <ident>? <pseudo-page>* ]#
##   @namespace   <prefix>? <url>|<string>
##   @charset     "<charset>"  (exactly; it is a byte signature, not a rule)
##   @counter-style <counter-style-name>        @property <--custom-name>
##   @font-palette-values / @position-try <dashed-ident>
##   @scope       [(<selector-list>)]? [to (<selector-list>)]?
##   @font-feature-values <family-name>#        @font-face / @starting-style /
##   @view-transition: no prelude at all
##
## Media features are checked by NAME (an unknown feature is almost always a
## typo — `min-widht` — and silently never matches) and by VALUE TYPE (length,
## ratio, resolution, integer, or the feature's own keywords). Range features
## accept `min-`/`max-` prefixes and the Level 4 range forms (`width >= 600px`,
## `400px < width <= 700px`); discrete ones accept neither.
##
## Non-raising throughout; every validator returns `(valid, error)`.

import std/tables
import validator
import selectors
import data_load

type
  PState = object
    s: string
    pos: int
    err: string

proc atEnd(st: PState): bool = st.pos >= st.s.len
proc cur(st: PState): char = (if st.pos < st.s.len: st.s[st.pos] else: '\0')
proc peekAt(st: PState, k: int): char =
  (if st.pos + k < st.s.len: st.s[st.pos + k] else: '\0')

proc isWs(c: char): bool = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'
proc isIdStart(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or ord(c) >= 128
proc isIdChar(c: char): bool = isIdStart(c) or (c >= '0' and c <= '9') or c == '-'
proc isDigit(c: char): bool = c >= '0' and c <= '9'

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc fail(st: var PState, msg: string): bool =
  if st.err.len == 0: st.err = msg
  false

proc skipWs(st: var PState): bool =
  result = false
  while not atEnd(st):
    if isWs(cur(st)):
      inc st.pos
      result = true
    elif cur(st) == '/' and peekAt(st, 1) == '*':
      st.pos = st.pos + 2
      while not atEnd(st) and not (cur(st) == '*' and peekAt(st, 1) == '/'): inc st.pos
      if not atEnd(st): st.pos = st.pos + 2
      result = true
    else:
      break

proc startsIdent(st: PState): bool =
  let c = cur(st)
  if isIdStart(c) or c == '\\': return true
  c == '-' and (isIdStart(peekAt(st, 1)) or peekAt(st, 1) == '-' or peekAt(st, 1) == '\\')

proc readIdent(st: var PState): string =
  result = ""
  if not startsIdent(st): return
  while not atEnd(st):
    let c = cur(st)
    if isIdChar(c):
      result.add c
      inc st.pos
    elif c == '\\' and st.pos + 1 < st.s.len:
      result.add c
      result.add st.s[st.pos + 1]
      st.pos = st.pos + 2
    else:
      break

proc closeParen(st: PState, open: int): int =
  ## The `)` matching the `(` at `open` (strings respected), or -1.
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
    elif c == '(' or c == '[' or c == '{': inc depth
    elif c == ')' or c == ']' or c == '}':
      dec depth
      if depth == 0: return i
    inc i
  -1

proc sub(s: string, a, b: int): string =
  result = ""
  var i = a
  while i < b and i < s.len:
    if i >= 0: result.add s[i]
    inc i

proc trimmed(s: string): string =
  var a = 0
  var b = s.len
  while a < b and isWs(s[a]): inc a
  while b > a and isWs(s[b-1]): dec b
  sub(s, a, b)

proc readString(st: var PState): bool =
  let q = cur(st)
  inc st.pos
  while not atEnd(st):
    let c = cur(st)
    if c == '\\':
      st.pos = st.pos + 2
      continue
    if c == q:
      inc st.pos
      return true
    if c == '\n': return fail(st, "newline inside a string")
    inc st.pos
  fail(st, "unterminated string")

proc readValueRun(st: var PState, stopAt: string): string =
  ## A run of value text up to (not including) any char in `stopAt` at paren
  ## depth 0, or the end.
  result = ""
  while not atEnd(st):
    let c = cur(st)
    var stop = false
    var k = 0
    while k < stopAt.len:
      if stopAt[k] == c: stop = true
      inc k
    if stop: break
    if c == '(':
      let e = closeParen(st, st.pos)
      if e < 0:
        result.add sub(st.s, st.pos, st.s.len)
        st.pos = st.s.len
        break
      result.add sub(st.s, st.pos, e + 1)
      st.pos = e + 1
    elif c == '"' or c == '\'':
      let a = st.pos
      discard readString(st)
      result.add sub(st.s, a, st.pos)
    else:
      result.add c
      inc st.pos

proc isCssWide(l: string): bool =
  l == "inherit" or l == "initial" or l == "unset" or l == "revert" or
    l == "revert-layer" or l == "default"

# --- media features ----------------------------------------------------------

type
  FeatType = enum
    ftLength, ftRatio, ftResolution, ftInteger, ftNumber, ftKeywords, ftBoolInt
  Feature = object
    typ: FeatType
    range: bool           ## a range feature: min-/max- and <, <=, >, >=, =
    keywords: string      ## ftKeywords: " a b c " (space-padded)

proc feat(typ: FeatType, range: bool, kws = ""): Feature =
  Feature(typ: typ, range: range, keywords: (if kws.len > 0: " " & kws & " " else: ""))

proc buildMediaFeatures(): Table[string, Feature] =
  result = initTable[string, Feature]()
  result["width"] = feat(ftLength, true)
  result["height"] = feat(ftLength, true)
  result["aspect-ratio"] = feat(ftRatio, true)
  result["orientation"] = feat(ftKeywords, false, "portrait landscape")
  result["resolution"] = feat(ftResolution, true)
  result["scan"] = feat(ftKeywords, false, "interlace progressive")
  result["grid"] = feat(ftBoolInt, false)
  result["update"] = feat(ftKeywords, false, "none slow fast")
  result["overflow-block"] = feat(ftKeywords, false, "none scroll paged")
  result["overflow-inline"] = feat(ftKeywords, false, "none scroll")
  result["color"] = feat(ftInteger, true)
  result["color-index"] = feat(ftInteger, true)
  result["monochrome"] = feat(ftInteger, true)
  result["color-gamut"] = feat(ftKeywords, false, "srgb p3 rec2020")
  result["video-color-gamut"] = feat(ftKeywords, false, "srgb p3 rec2020")
  result["pointer"] = feat(ftKeywords, false, "none coarse fine")
  result["any-pointer"] = feat(ftKeywords, false, "none coarse fine")
  result["hover"] = feat(ftKeywords, false, "none hover")
  result["any-hover"] = feat(ftKeywords, false, "none hover")
  result["prefers-reduced-motion"] = feat(ftKeywords, false, "no-preference reduce")
  result["prefers-reduced-transparency"] = feat(ftKeywords, false, "no-preference reduce")
  result["prefers-reduced-data"] = feat(ftKeywords, false, "no-preference reduce")
  result["prefers-contrast"] = feat(ftKeywords, false, "no-preference more less custom")
  result["prefers-color-scheme"] = feat(ftKeywords, false, "light dark")
  result["forced-colors"] = feat(ftKeywords, false, "none active")
  result["inverted-colors"] = feat(ftKeywords, false, "none inverted")
  result["dynamic-range"] = feat(ftKeywords, false, "standard high")
  result["video-dynamic-range"] = feat(ftKeywords, false, "standard high")
  result["display-mode"] = feat(ftKeywords, false,
    "browser fullscreen minimal-ui standalone picture-in-picture window-controls-overlay")
  result["scripting"] = feat(ftKeywords, false, "none initial-only enabled")
  result["environment-blending"] = feat(ftKeywords, false, "opaque additive subtractive")
  result["nav-controls"] = feat(ftKeywords, false, "none back")
  result["device-posture"] = feat(ftKeywords, false, "continuous folded")
  result["horizontal-viewport-segments"] = feat(ftInteger, true)
  result["vertical-viewport-segments"] = feat(ftInteger, true)
  # deprecated in MQ4 but still valid syntax, and still everywhere
  result["device-width"] = feat(ftLength, true)
  result["device-height"] = feat(ftLength, true)
  result["device-aspect-ratio"] = feat(ftRatio, true)

proc buildContainerFeatures(): Table[string, Feature] =
  result = initTable[string, Feature]()
  result["width"] = feat(ftLength, true)
  result["height"] = feat(ftLength, true)
  result["inline-size"] = feat(ftLength, true)
  result["block-size"] = feat(ftLength, true)
  result["aspect-ratio"] = feat(ftRatio, true)
  result["orientation"] = feat(ftKeywords, false, "portrait landscape")

let mediaFeatures = buildMediaFeatures()
let containerFeatures = buildContainerFeatures()

proc isMediaFeature*(name: string): bool =
  ## Is `name` a known media feature (without a `min-`/`max-` prefix)?
  mediaFeatures.hasKey(lower(name))

proc hasWord(padded, w: string): bool =
  ## Is `w` one of the space-separated words in `padded` (" a b ")?
  let needle = " " & w & " "
  if needle.len > padded.len: return false
  var i = 0
  while i + needle.len <= padded.len:
    var j = 0
    while j < needle.len and padded[i+j] == needle[j]: inc j
    if j == needle.len: return true
    inc i
  false

proc checkFeatureValue(f: Feature, name, value: string): tuple[valid: bool, error: string] =
  let v = trimmed(value)
  if v.len == 0: return (false, "expected a value for '" & name & "'")
  case f.typ
  of ftLength:
    let r = validateAgainst("<length>", v)
    if r.valid: (true, "") else: (false, "'" & name & "' expects a length, got '" & v & "'")
  of ftRatio:
    if matchesSyntax("<ratio>", v) or matchesSyntax("<number [0,∞]>", v): (true, "")
    else: (false, "'" & name & "' expects a ratio like 16/9, got '" & v & "'")
  of ftResolution:
    if lower(v) == "infinite" or matchesSyntax("<resolution>", v): (true, "")
    else: (false, "'" & name & "' expects a resolution (2dppx, 192dpi, 2x), got '" & v & "'")
  of ftInteger:
    if matchesSyntax("<integer [0,∞]>", v): (true, "")
    else: (false, "'" & name & "' expects a non-negative integer, got '" & v & "'")
  of ftBoolInt:
    if v == "0" or v == "1": (true, "")
    else: (false, "'" & name & "' expects 0 or 1, got '" & v & "'")
  of ftNumber:
    if matchesSyntax("<number>", v): (true, "")
    else: (false, "'" & name & "' expects a number, got '" & v & "'")
  of ftKeywords:
    if hasWord(f.keywords, lower(v)): (true, "")
    else: (false, "'" & name & "' expects one of" & f.keywords & "— got '" & v & "'")

proc isVendorFeature(name: string): bool =
  let l = lower(name)
  (l.len > 1 and l[0] == '-') or (l.len > 5 and sub(l, 0, 5) == "min--") or
    (l.len > 5 and sub(l, 0, 5) == "max--")

proc lookupFeature(table: Table[string, Feature], name: string):
    tuple[found: bool, f: Feature, prefixed: bool, base: string] =
  let l = lower(name)
  if table.hasKey(l): return (true, table.getOrDefault(l, feat(ftNumber, false)), false, l)
  if l.len > 4 and (sub(l, 0, 4) == "min-" or sub(l, 0, 4) == "max-"):
    let b = sub(l, 4, l.len)
    if table.hasKey(b): return (true, table.getOrDefault(b, feat(ftNumber, false)), true, b)
  (false, feat(ftNumber, false), false, l)

proc readComparison(st: var PState): string =
  ## `<`, `<=`, `>`, `>=`, `=` at the cursor (consumed), or "".
  let c = cur(st)
  if c == '<' or c == '>':
    inc st.pos
    if cur(st) == '=':
      inc st.pos
      return (if c == '<': "<=" else: ">=")
    return (if c == '<': "<" else: ">")
  if c == '=':
    inc st.pos
    return "="
  ""

proc parseFeature(st: var PState, table: Table[string, Feature], what: string,
                  close: int): bool =
  ## Inside `( … )` (st.pos just past `(`; `close` is the `)`): a boolean,
  ## plain or range feature.
  discard skipWs(st)
  let save = st.pos
  let name = readIdent(st)
  discard skipWs(st)
  if name.len > 0 and (st.pos == close or cur(st) == ':'):
    let fx = lookupFeature(table, name)
    if not fx.found:
      if isVendorFeature(name):
        st.pos = close
        return true
      return fail(st, "unknown " & what & " feature '" & name & "'")
    if st.pos == close:
      if fx.prefixed:
        return fail(st, "'" & name & "' needs a value (min-/max- features are not boolean)")
      return true                          # boolean context: (color), (hover)
    inc st.pos                             # ':'
    discard skipWs(st)
    if fx.prefixed and not fx.f.range:
      return fail(st, "'" & fx.base & "' is a discrete feature; it has no min-/max- form")
    let value = sub(st.s, st.pos, close)
    let r = checkFeatureValue(fx.f, name, value)
    if not r.valid: return fail(st, r.error)
    st.pos = close
    return true
  # a range form: value op name [op value]  or  name op value
  st.pos = save
  var names: seq[string] = @[]
  var ops: seq[string] = @[]
  var values: seq[string] = @[]
  var order: seq[bool] = @[]          # true = a name in that slot
  while st.pos < close:
    discard skipWs(st)
    if st.pos >= close: break
    let op = readComparison(st)
    if op.len > 0:
      ops.add op
      continue
    let s2 = st.pos
    let w = readIdent(st)
    discard skipWs(st)
    let nextIsOp = cur(st) == '<' or cur(st) == '>' or cur(st) == '=' or st.pos >= close
    if w.len > 0 and nextIsOp and lookupFeature(table, w).found:
      names.add w
      order.add true
    else:
      st.pos = s2
      let v = trimmed(readValueRun(st, "<>=)"))
      if v.len == 0: return fail(st, "expected a value or a feature name")
      values.add v
      order.add false
  if names.len != 1:
    if names.len == 0:
      if name.len > 0 and not lookupFeature(table, name).found and not isVendorFeature(name):
        return fail(st, "unknown " & what & " feature '" & name & "'")
      return fail(st, "expected a " & what & " feature")
    return fail(st, "a range may name only one feature")
  let fx = lookupFeature(table, names[0])
  if fx.prefixed: return fail(st, "min-/max- prefixes cannot be used in a range")
  if not fx.f.range:
    return fail(st, "'" & names[0] & "' is a discrete feature and cannot be used in a range")
  if order.len == 2:
    if ops.len != 1: return fail(st, "expected one comparison in '" & names[0] & "' range")
  elif order.len == 3:
    if not (order[0] == false and order[1] == true and order[2] == false):
      return fail(st, "a two-sided range is written value < name < value")
    if ops.len != 2: return fail(st, "expected two comparisons in the range")
    let lt = ops[0][0] == '<' and ops[1][0] == '<'
    let gt = ops[0][0] == '>' and ops[1][0] == '>'
    if not (lt or gt): return fail(st, "a two-sided range must point one way (< … < or > … >)")
  else:
    return fail(st, "malformed range")
  var k = 0
  while k < values.len:
    let r = checkFeatureValue(fx.f, names[0], values[k])
    if not r.valid: return fail(st, r.error)
    inc k
  st.pos = close
  true

# --- generic boolean condition: not / and / or over ( … ) ----------------------

type InParens = proc (st: var PState, close: int): bool {.nimcall.}

proc parseCondition(st: var PState, inner: InParens, allowOr: bool, what: string,
                    fnOk: proc (name: string): bool {.nimcall.}): bool

proc parseInParens(st: var PState, inner: InParens, what: string,
                   fnOk: proc (name: string): bool {.nimcall.}): bool =
  ## `( condition )` | `( feature )` | an allowed function like style()/selector().
  discard skipWs(st)
  if cur(st) == '(':
    let close = closeParen(st, st.pos)
    if close < 0: return fail(st, "unbalanced '(' in " & what)
    inc st.pos
    discard skipWs(st)
    # a nested condition starts with `(` or with `not ` / `not(`
    let save = st.pos
    let startsNot = lower(sub(st.s, save, save + 3)) == "not" and save + 3 < close and
                    (isWs(st.s[save+3]) or st.s[save+3] == '(')
    if cur(st) == '(' or startsNot:
      var sub2 = PState(s: sub(st.s, st.pos, close), pos: 0, err: "")
      if not parseCondition(sub2, inner, true, what, fnOk):
        return fail(st, sub2.err)
      discard skipWs(sub2)
      if not atEnd(sub2): return fail(st, "unexpected '" & sub(sub2.s, sub2.pos, sub2.s.len) & "' in " & what)
      st.pos = close + 1
      return true
    if not inner(st, close): return false
    st.pos = close + 1
    return true
  let save = st.pos
  let fname = lower(readIdent(st))
  if fname.len > 0 and cur(st) == '(':
    if not fnOk(fname):
      return fail(st, "unknown function '" & fname & "()' in " & what)
    let close = closeParen(st, st.pos)
    if close < 0: return fail(st, "unbalanced '(' in " & what)
    st.pos = close + 1
    return true
  st.pos = save
  fail(st, "expected '(' in " & what)

proc parseCondition(st: var PState, inner: InParens, allowOr: bool, what: string,
                    fnOk: proc (name: string): bool {.nimcall.}): bool =
  discard skipWs(st)
  let save = st.pos
  if lower(readIdent(st)) == "not":
    return parseInParens(st, inner, what, fnOk)
  st.pos = save
  if not parseInParens(st, inner, what, fnOk): return false
  var joiner = ""
  while true:
    let hadWs = skipWs(st)
    if atEnd(st) or cur(st) == ',' or cur(st) == '{': break
    let s2 = st.pos
    let w = lower(readIdent(st))
    if w != "and" and w != "or":
      st.pos = s2
      break
    discard hadWs
    if w == "or" and not allowOr:
      return fail(st, "'or' is not allowed here (wrap it in parentheses)")
    if joiner.len > 0 and joiner != w:
      return fail(st, "cannot mix 'and' and 'or' without parentheses")
    joiner = w
    if not isWs(cur(st)) and cur(st) != '(':
      return fail(st, "expected whitespace after '" & w & "'")
    if not parseInParens(st, inner, what, fnOk): return false
  true

# --- @media -----------------------------------------------------------------

proc mediaInner(st: var PState, close: int): bool =
  parseFeature(st, mediaFeatures, "media", close)

proc noFunctions(name: string): bool = false

proc isMediaType(t: string): bool =
  t == "all" or t == "screen" or t == "print" or
    # deprecated media types: valid syntax, match nothing
    t == "tty" or t == "tv" or t == "projection" or t == "handheld" or
    t == "braille" or t == "embossed" or t == "aural" or t == "speech"

proc parseMediaQuery(st: var PState): bool =
  discard skipWs(st)
  if cur(st) == '(':
    return parseCondition(st, mediaInner, true, "media query", noFunctions)
  let save = st.pos
  var w = lower(readIdent(st))
  if w.len == 0: return fail(st, "expected a media type or '('")
  if w == "not":
    discard skipWs(st)
    if cur(st) == '(':
      st.pos = save
      return parseCondition(st, mediaInner, true, "media query", noFunctions)
    w = lower(readIdent(st))
  elif w == "only":
    discard skipWs(st)
    w = lower(readIdent(st))
  if w.len == 0: return fail(st, "expected a media type")
  if w == "and" or w == "or" or w == "not" or w == "only" or w == "layer":
    return fail(st, "'" & w & "' cannot be a media type")
  if not isMediaType(w):
    return fail(st, "unknown media type '" & w & "'")
  discard skipWs(st)
  if atEnd(st) or cur(st) == ',': return true
  let s2 = st.pos
  if lower(readIdent(st)) != "and":
    st.pos = s2
    return fail(st, "expected 'and' after the media type")
  discard skipWs(st)
  parseCondition(st, mediaInner, false, "media query", noFunctions)

proc validateMediaQueryList*(s: string): tuple[valid: bool, error: string] =
  ## Validate a `<media-query-list>` — the prelude of `@media`, the tail of
  ## `@import`, the `media` attribute of `<link>`. An empty list is valid
  ## (it means `all`).
  var st = PState(s: s, pos: 0, err: "")
  discard skipWs(st)
  if atEnd(st): return (true, "")
  while true:
    if not parseMediaQuery(st): return (false, st.err)
    discard skipWs(st)
    if cur(st) == ',':
      inc st.pos
      discard skipWs(st)
      if atEnd(st): return (false, "trailing ',' in media query list")
      continue
    break
  if not atEnd(st): return (false, "unexpected '" & sub(st.s, st.pos, st.s.len) & "' in media query")
  (true, "")

# --- @supports -----------------------------------------------------------------

proc supportsInner(st: var PState, close: int): bool =
  ## `( prop: value )` — a declaration. The value is checked for SYNTAX only:
  ## a feature query exists to ask about things the engine may not know.
  let save = st.pos
  let name = readIdent(st)
  discard skipWs(st)
  if name.len == 0 or cur(st) != ':':
    st.pos = save
    return fail(st, "expected a declaration 'property: value' in @supports")
  inc st.pos
  if trimmed(sub(st.s, st.pos, close)).len == 0:
    return fail(st, "empty value in @supports declaration")
  st.pos = close
  true

proc supportsFn(name: string): bool =
  name == "selector" or name == "font-tech" or name == "font-format" or
    name == "at-rule"

proc checkSupportsFunctions(s: string): tuple[valid: bool, error: string] =
  ## Look inside the functions of a supports condition: selector(X) must hold
  ## a valid complex selector.
  var i = 0
  while i < s.len:
    if (i == 0 or not isIdChar(s[i-1])) and i + 9 <= s.len and lower(sub(s, i, i + 9)) == "selector(":
      var st = PState(s: s, pos: i + 8, err: "")
      let close = closeParen(st, i + 8)
      if close < 0: return (false, "unbalanced selector(")
      let inner = trimmed(sub(s, i + 9, close))
      let r = validateSelector(inner)
      if not r.valid: return (false, "selector(" & inner & "): " & r.error)
      i = close
    inc i
  (true, "")

proc validateSupportsCondition*(s: string): tuple[valid: bool, error: string] =
  ## Validate a `<supports-condition>`: `not`/`and`/`or` over parenthesised
  ## declarations, `selector()`, `font-tech()`, `font-format()`.
  var st = PState(s: s, pos: 0, err: "")
  if trimmed(s).len == 0: return (false, "@supports needs a condition")
  if not parseCondition(st, supportsInner, true, "@supports condition", supportsFn):
    return (false, st.err)
  discard skipWs(st)
  if not atEnd(st): return (false, "unexpected '" & sub(st.s, st.pos, st.s.len) & "' in @supports")
  checkSupportsFunctions(s)

# --- @container -------------------------------------------------------------------

proc containerInner(st: var PState, close: int): bool =
  parseFeature(st, containerFeatures, "container size", close)

proc containerFn(name: string): bool =
  name == "style" or name == "scroll-state"

proc checkStyleQueries(s: string): tuple[valid: bool, error: string] =
  ## style(--x: 1) / style(color: red) / style(--x): each declaration inside
  ## must at least name a property; a standard property's value is validated.
  var i = 0
  while i < s.len:
    if (i == 0 or not isIdChar(s[i-1])) and i + 6 <= s.len and lower(sub(s, i, i + 6)) == "style(":
      var st = PState(s: s, pos: i + 5, err: "")
      let close = closeParen(st, i + 5)
      if close < 0: return (false, "unbalanced style(")
      let inner = trimmed(sub(s, i + 6, close))
      if inner.len == 0: return (false, "style() needs a query")
      # simple form only: one declaration or one custom-property name
      if inner[0] != '(' and lower(sub(inner, 0, 4)) != "not ":
        var c = 0
        while c < inner.len and inner[c] != ':': inc c
        let prop = trimmed(sub(inner, 0, c))
        if c < inner.len:
          let value = trimmed(sub(inner, c + 1, inner.len))
          if not (prop.len > 2 and prop[0] == '-' and prop[1] == '-'):
            let r = validateValue(prop, value)
            if not r.valid: return (false, "style(" & inner & "): " & r.error)
        elif not (prop.len > 2 and prop[0] == '-' and prop[1] == '-'):
          return (false, "style(" & inner & "): a bare name must be a custom property")
      i = close
    inc i
  (true, "")

proc validateContainerCondition*(s: string): tuple[valid: bool, error: string] =
  ## Validate an `@container` prelude: `[<container-name>]? <container-query>`,
  ## comma-separated. Size features, `style()` and `scroll-state()` queries.
  var st = PState(s: s, pos: 0, err: "")
  discard skipWs(st)
  if atEnd(st): return (false, "@container needs a condition")
  while true:
    discard skipWs(st)
    let save = st.pos
    let w = lower(readIdent(st))
    if w.len > 0 and w != "not" and not (containerFn(w) and cur(st) == '('):
      # a container name, then (optionally, in Containment 3) the query
      if w == "none" or w == "and" or w == "or" or isCssWide(w):
        return (false, "'" & w & "' cannot be a container name")
      discard skipWs(st)
      if not (atEnd(st) or cur(st) == ','):
        if not parseCondition(st, containerInner, true, "container query", containerFn):
          return (false, st.err)
    else:
      st.pos = save
      if not parseCondition(st, containerInner, true, "container query", containerFn):
        return (false, st.err)
    discard skipWs(st)
    if cur(st) == ',':
      inc st.pos
      continue
    break
  if not atEnd(st): return (false, "unexpected '" & sub(st.s, st.pos, st.s.len) & "' in @container")
  checkStyleQueries(s)

# --- names and small preludes -------------------------------------------------------

proc validateLayerName*(s: string): tuple[valid: bool, error: string] =
  ## `<ident> [ '.' <ident> ]*` — no whitespace around the dots.
  var st = PState(s: trimmed(s), pos: 0, err: "")
  if atEnd(st): return (false, "expected a layer name")
  while true:
    let w = readIdent(st)
    if w.len == 0: return (false, "expected a layer name segment in '" & s & "'")
    if isCssWide(lower(w)): return (false, "'" & w & "' cannot be a layer name")
    if cur(st) == '.':
      inc st.pos
      continue
    break
  if not atEnd(st): return (false, "unexpected '" & sub(st.s, st.pos, st.s.len) & "' in layer name")
  (true, "")

proc splitTopCommas(s: string): seq[string] =
  result = @[]
  var depth = 0
  var cur = ""
  var i = 0
  var q = '\0'
  while i < s.len:
    let c = s[i]
    if q != '\0':
      cur.add c
      if c == '\\' and i + 1 < s.len:
        cur.add s[i+1]
        inc i
      elif c == q: q = '\0'
    elif c == '"' or c == '\'':
      q = c
      cur.add c
    elif c == '(' or c == '[': inc depth; cur.add c
    elif c == ')' or c == ']':
      if depth > 0: dec depth
      cur.add c
    elif c == ',' and depth == 0:
      result.add trimmed(cur)
      cur = ""
    else:
      cur.add c
    inc i
  result.add trimmed(cur)

proc validateLayerStatement(s: string): tuple[valid: bool, error: string] =
  let parts = splitTopCommas(s)
  var i = 0
  while i < parts.len:
    let r = validateLayerName(parts[i])
    if not r.valid: return r
    inc i
  (true, "")

proc isStringTok(s: string): bool =
  s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len-1] == s[0]

proc isUrlTok(s: string): bool =
  let l = lower(s)
  l.len >= 5 and sub(l, 0, 4) == "url(" and l[l.len-1] == ')'

proc validateKeyframesName*(s: string): tuple[valid: bool, error: string] =
  let t = trimmed(s)
  if t.len == 0: return (false, "@keyframes needs a name")
  if isStringTok(t): return (true, "")
  var st = PState(s: t, pos: 0, err: "")
  let w = readIdent(st)
  if w.len == 0 or not atEnd(st): return (false, "a keyframes name is one identifier or a string, got '" & t & "'")
  let l = lower(w)
  if isCssWide(l) or l == "none": return (false, "'" & w & "' cannot be a keyframes name")
  (true, "")

proc validateKeyframeSelector*(s: string): tuple[valid: bool, error: string] =
  ## `from`, `to`, `<percentage [0,100]>`, or a timeline range
  ## (`entry 10%`), comma-separated.
  let parts = splitTopCommas(s)
  var i = 0
  while i < parts.len:
    let p = lower(parts[i])
    if p.len == 0: return (false, "empty keyframe selector")
    if p != "from" and p != "to":
      var st = PState(s: p, pos: 0, err: "")
      let w = readIdent(st)
      discard skipWs(st)
      let pct = sub(st.s, st.pos, st.s.len)
      if w.len > 0 and not (w == "cover" or w == "contain" or w == "entry" or
                            w == "exit" or w == "entry-crossing" or w == "exit-crossing"):
        return (false, "unknown keyframe selector '" & parts[i] & "'")
      if not matchesSyntax("<percentage>", pct):
        return (false, "a keyframe selector is from, to or a percentage, got '" & parts[i] & "'")
      var n = 0.0
      var k = 0
      var neg = false
      if k < pct.len and pct[k] == '-':
        neg = true
        inc k
      while k < pct.len and isDigit(pct[k]):
        n = n * 10.0 + float(ord(pct[k]) - ord('0'))
        inc k
      if neg or n > 100.0:
        return (false, "keyframe percentage out of range [0%, 100%]: '" & parts[i] & "'")
    inc i
  (true, "")

proc validatePageSelectorList*(s: string): tuple[valid: bool, error: string] =
  ## `[ <ident>? [ :left | :right | :first | :blank ]* ]#` (empty = all pages).
  if trimmed(s).len == 0: return (true, "")
  let parts = splitTopCommas(s)
  var i = 0
  while i < parts.len:
    var st = PState(s: parts[i], pos: 0, err: "")
    let w = readIdent(st)
    var n = (if w.len > 0: 1 else: 0)
    while cur(st) == ':':
      inc st.pos
      let p = lower(readIdent(st))
      if p != "left" and p != "right" and p != "first" and p != "blank":
        return (false, "unknown page pseudo-class ':" & p & "'")
      inc n
    if n == 0 or not atEnd(st): return (false, "invalid page selector '" & parts[i] & "'")
    inc i
  (true, "")

proc validateImportPrelude*(s: string): tuple[valid: bool, error: string] =
  ## `[ <string> | <url> ] [ layer | layer(<layer-name>) ]?
  ##  [ supports( <supports-condition> | <declaration> ) ]? <media-query-list>?`
  var st = PState(s: s, pos: 0, err: "")
  discard skipWs(st)
  if cur(st) == '"' or cur(st) == '\'':
    if not readString(st): return (false, st.err)
  else:
    let w = lower(readIdent(st))
    if (w != "url" and w != "src") or cur(st) != '(':
      return (false, "@import needs a url() or a string first")
    let close = closeParen(st, st.pos)
    if close < 0: return (false, "unbalanced url(")
    st.pos = close + 1
  discard skipWs(st)
  var save = st.pos
  var w = lower(readIdent(st))
  if w == "layer":
    if cur(st) == '(':
      let close = closeParen(st, st.pos)
      if close < 0: return (false, "unbalanced layer(")
      let r = validateLayerName(sub(st.s, st.pos + 1, close))
      if not r.valid: return r
      st.pos = close + 1
    discard skipWs(st)
    save = st.pos
    w = lower(readIdent(st))
  if w == "supports" and cur(st) == '(':
    let close = closeParen(st, st.pos)
    if close < 0: return (false, "unbalanced supports(")
    let inner = trimmed(sub(st.s, st.pos + 1, close))
    var r = validateSupportsCondition(inner)
    if not r.valid:
      # the bare-declaration form: supports(display: grid)
      r = validateSupportsCondition("(" & inner & ")")
    if not r.valid: return (false, "@import supports(): " & r.error)
    st.pos = close + 1
  else:
    st.pos = save
  validateMediaQueryList(sub(st.s, st.pos, st.s.len))

proc validateNamespacePrelude*(s: string): tuple[valid: bool, error: string] =
  let t = trimmed(s)
  var st = PState(s: t, pos: 0, err: "")
  if isStringTok(t) or isUrlTok(t): return (true, "")
  let prefix = readIdent(st)
  if prefix.len == 0: return (false, "@namespace needs a url() or a string")
  discard skipWs(st)
  let rest = sub(st.s, st.pos, st.s.len)
  if isStringTok(rest) or isUrlTok(rest): return (true, "")
  (false, "@namespace " & prefix & " needs a url() or a string")

proc validateScopePrelude*(s: string): tuple[valid: bool, error: string] =
  ## `[(<scope-start>)]? [to (<scope-end>)]?`
  var st = PState(s: s, pos: 0, err: "")
  discard skipWs(st)
  if atEnd(st): return (true, "")
  if cur(st) == '(':
    let close = closeParen(st, st.pos)
    if close < 0: return (false, "unbalanced '(' in @scope")
    let r = validateSelector(sub(st.s, st.pos + 1, close))
    if not r.valid: return (false, "@scope start: " & r.error)
    st.pos = close + 1
    discard skipWs(st)
  if atEnd(st): return (true, "")
  if lower(readIdent(st)) != "to": return (false, "expected 'to' in @scope")
  discard skipWs(st)
  if cur(st) != '(': return (false, "expected '(' after 'to' in @scope")
  let close = closeParen(st, st.pos)
  if close < 0: return (false, "unbalanced '(' in @scope")
  let r = validateSelector(sub(st.s, st.pos + 1, close))
  if not r.valid: return (false, "@scope end: " & r.error)
  st.pos = close + 1
  discard skipWs(st)
  if not atEnd(st): return (false, "unexpected '" & sub(st.s, st.pos, st.s.len) & "' in @scope")
  (true, "")

proc validateFamilyNameList(s: string): tuple[valid: bool, error: string] =
  let parts = splitTopCommas(s)
  var i = 0
  while i < parts.len:
    if parts[i].len == 0: return (false, "empty font family name")
    if not isStringTok(parts[i]):
      var st = PState(s: parts[i], pos: 0, err: "")
      while not atEnd(st):
        if readIdent(st).len == 0: return (false, "invalid font family name '" & parts[i] & "'")
        discard skipWs(st)
    inc i
  (true, "")

proc isPredefinedCounterStyle(l: string): bool =
  l == "decimal" or l == "disc" or l == "square" or l == "circle" or
    l == "disclosure-open" or l == "disclosure-closed"

proc validateAtRulePrelude*(keyword, prelude: string, hasBlock = true):
    tuple[valid: bool, error: string] =
  ## Validate the prelude of `@keyword` (keyword without the `@`,
  ## lower-case). `hasBlock` says whether the rule had a `{ … }` — `@layer`
  ## means different things with and without one, and a statement at-rule
  ## (`@import`) given a block is an error.
  var kw = lower(keyword)
  # vendor-prefixed spellings of standard rules
  if kw == "-webkit-keyframes" or kw == "-moz-keyframes" or kw == "-o-keyframes" or
     kw == "-ms-keyframes":
    kw = "keyframes"
  let p = trimmed(prelude)
  case kw
  of "media":
    if not hasBlock: return (false, "@media needs a block")
    validateMediaQueryList(p)
  of "supports":
    if not hasBlock: return (false, "@supports needs a block")
    validateSupportsCondition(p)
  of "container":
    if not hasBlock: return (false, "@container needs a block")
    validateContainerCondition(p)
  of "import":
    if hasBlock: return (false, "@import is a statement, not a block")
    validateImportPrelude(p)
  of "layer":
    if hasBlock:
      if p.len == 0: (true, "") else: validateLayerName(p)
    else:
      if p.len == 0: (false, "@layer statement needs at least one name")
      else: validateLayerStatement(p)
  of "keyframes":
    if not hasBlock: return (false, "@keyframes needs a block")
    validateKeyframesName(p)
  of "font-face", "starting-style", "view-transition":
    if p.len > 0: (false, "@" & kw & " takes no prelude") else: (true, "")
  of "page":
    validatePageSelectorList(p)
  of "namespace":
    if hasBlock: return (false, "@namespace is a statement, not a block")
    validateNamespacePrelude(p)
  of "charset":
    if hasBlock: return (false, "@charset is a statement, not a block")
    if p.len >= 2 and p[0] == '"' and p[p.len-1] == '"': (true, "")
    else: (false, "@charset must be written exactly @charset \"name\";")
  of "counter-style":
    var st = PState(s: p, pos: 0, err: "")
    let w = readIdent(st)
    if w.len == 0 or not atEnd(st): return (false, "@counter-style needs one name")
    let l = lower(w)
    if l == "none" or isCssWide(l): return (false, "'" & w & "' cannot be a counter style name")
    if isPredefinedCounterStyle(l): return (false, "the predefined counter style '" & w & "' cannot be redefined")
    (true, "")
  of "property":
    if p.len > 2 and p[0] == '-' and p[1] == '-':
      var st = PState(s: p, pos: 0, err: "")
      discard readIdent(st)
      if atEnd(st): return (true, "")
    (false, "@property needs a custom property name (--name)")
  of "font-palette-values", "position-try":
    if p.len > 2 and p[0] == '-' and p[1] == '-':
      var st = PState(s: p, pos: 0, err: "")
      discard readIdent(st)
      if atEnd(st): return (true, "")
    (false, "@" & kw & " needs a dashed name (--name)")
  of "scope":
    validateScopePrelude(p)
  of "font-feature-values":
    if p.len == 0: return (false, "@font-feature-values needs a font family")
    validateFamilyNameList(p)
  of "swash", "annotation", "ornaments", "stylistic", "styleset",
     "character-variant", "historical-forms":
    if p.len > 0: (false, "@" & kw & " takes no prelude") else: (true, "")
  of "top-left-corner", "top-left", "top-center", "top-right", "top-right-corner",
     "bottom-left-corner", "bottom-left", "bottom-center", "bottom-right",
     "bottom-right-corner", "left-top", "left-middle", "left-bottom",
     "right-top", "right-middle", "right-bottom":
    if p.len > 0: (false, "@" & kw & " takes no prelude") else: (true, "")
  of "document", "-moz-document":
    (true, "")                          # deprecated; accepted as written
  of "viewport", "-ms-viewport":
    (true, "")                          # obsolete; accepted as written
  else:
    if kw.len > 0 and kw[0] == '-': (true, "")     # vendor at-rule
    elif isAtRule("@" & kw): (true, "")
    else: (false, "unknown at-rule '@" & keyword & "'")
