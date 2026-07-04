## selectors.nim — validate CSS selectors against the Selectors-4 grammar.
##
## A hand-written recursive-descent validator over the character stream (no
## raising string slices — nimony-friendly). It checks structure (type /
## universal / class / id / attribute / pseudo simple selectors, joined by the
## descendant / child / next-sibling / subsequent-sibling / column combinators,
## in a comma-separated selector list) and validates pseudo-class / pseudo-element
## NAMES against the MDN data in `data_load`.
##
## Scope: covers the common selector surface. Not yet handled: namespaces
## (`ns|type`), and the internal grammar of functional pseudo arguments
## (`:nth-child(An+B)` — the parenthesised part is only balance-checked).

import std/tables
import data_load

type SelState = object
  s: string
  pos: int
  err: string

proc atEnd(st: var SelState): bool = st.pos >= st.s.len
proc cur(st: var SelState): char = (if st.pos < st.s.len: st.s[st.pos] else: '\0')

proc isIdentStart(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-' or ord(c) >= 128
proc isIdentChar(c: char): bool =
  isIdentStart(c) or (c >= '0' and c <= '9')
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
  ## Advance over whitespace; return whether any was seen (matters: whitespace
  ## between compounds IS the descendant combinator).
  result = false
  while not atEnd(st) and isWs(cur(st)):
    inc st.pos
    result = true

proc readIdent(st: var SelState): string =
  result = ""
  if atEnd(st) or not isIdentStart(cur(st)): return
  while not atEnd(st) and isIdentChar(cur(st)):
    result.add cur(st)
    inc st.pos

proc parseAttribute(st: var SelState): bool =
  ## `[` attr ( op value flag? )? `]`   (cur is `[`)
  inc st.pos
  discard skipWs(st)
  let attr = readIdent(st)
  if attr.len == 0: return fail(st, "expected attribute name")
  discard skipWs(st)
  if cur(st) == ']':
    inc st.pos
    return true
  let c = cur(st)
  if c == '~' or c == '|' or c == '^' or c == '$' or c == '*':
    inc st.pos
    if cur(st) != '=': return fail(st, "expected '=' after attribute operator")
    inc st.pos
  elif c == '=':
    inc st.pos
  else:
    return fail(st, "expected attribute operator or ']'")
  discard skipWs(st)
  if cur(st) == '"' or cur(st) == '\'':
    let q = cur(st)
    inc st.pos
    while not atEnd(st) and cur(st) != q: inc st.pos
    if atEnd(st): return fail(st, "unterminated attribute string")
    inc st.pos
  else:
    var v = ""
    while not atEnd(st) and isIdentChar(cur(st)):
      v.add cur(st); inc st.pos
    if v.len == 0: return fail(st, "expected attribute value")
  discard skipWs(st)
  let f = cur(st)
  if f == 'i' or f == 'I' or f == 's' or f == 'S':
    inc st.pos
    discard skipWs(st)
  if cur(st) != ']': return fail(st, "expected ']'")
  inc st.pos
  true

proc parsePseudo(st: var SelState): bool =
  ## `:`name  or  `::`name  or  `:`name`(`…`)`   (cur is `:`)
  inc st.pos
  var element = false
  if cur(st) == ':':
    element = true
    inc st.pos
  let name = readIdent(st)
  if name.len == 0: return fail(st, "expected name after ':'")
  if cur(st) == '(':
    var depth = 0
    while not atEnd(st):
      let c = cur(st)
      if c == '(': inc depth
      elif c == ')':
        dec depth
        if depth == 0:
          inc st.pos
          break
      inc st.pos
    if depth != 0: return fail(st, "unbalanced '(' in pseudo argument")
  let l = toLower(name)
  # Browser-prefixed pseudos (::-webkit-…, ::-moz-…, :-moz-…) are valid vendor
  # extensions with no MDN entry — accept them rather than falsely reject.
  if l.len > 0 and l[0] == '-':
    return true
  if element:
    if not isPseudoElement(l): return fail(st, "unknown pseudo-element '::" & name & "'")
  else:
    # single-colon legacy pseudo-elements (:before/:after) are accepted too
    if not isPseudoClass(l) and not isPseudoElement(l):
      return fail(st, "unknown pseudo-class ':" & name & "'")
  true

proc parseCompound(st: var SelState): bool =
  ## One compound selector: optional type/universal + any number of subclasses.
  var count = 0
  if cur(st) == '*':
    inc st.pos; inc count
  elif isIdentStart(cur(st)):
    discard readIdent(st); inc count
  while not atEnd(st):
    let c = cur(st)
    if c == '.':
      inc st.pos
      if readIdent(st).len == 0: return fail(st, "expected class name after '.'")
      inc count
    elif c == '#':
      inc st.pos
      if readIdent(st).len == 0: return fail(st, "expected id name after '#'")
      inc count
    elif c == '[':
      if not parseAttribute(st): return false
      inc count
    elif c == ':':
      if not parsePseudo(st): return false
      inc count
    else:
      break
  if count == 0: return fail(st, "expected a selector")
  true

proc parseComplex(st: var SelState): bool =
  ## compound ( combinator compound )*
  if not parseCompound(st): return false
  while true:
    let hadWs = skipWs(st)
    if atEnd(st): break
    let c = cur(st)
    if c == ',' or c == ')': break
    var explicitComb = false
    if c == '>' or c == '+' or c == '~':
      inc st.pos; explicitComb = true
      discard skipWs(st)
    elif c == '|' and st.pos + 1 < st.s.len and st.s[st.pos + 1] == '|':
      st.pos = st.pos + 2; explicitComb = true
      discard skipWs(st)
    if not explicitComb and not hadWs:
      break
    if not parseCompound(st): return false
  true

proc parseSelectorList(st: var SelState): bool =
  discard skipWs(st)
  if not parseComplex(st): return false
  discard skipWs(st)
  while cur(st) == ',':
    inc st.pos
    discard skipWs(st)
    if not parseComplex(st): return false
    discard skipWs(st)
  if not atEnd(st): return fail(st, "unexpected '" & chStr(cur(st)) & "'")
  true

proc validateSelector*(sel: string): tuple[valid: bool, error: string] =
  ## Validate a CSS selector (or selector list). Returns (valid, human error).
  if sel.len == 0: return (false, "empty selector")
  var st = SelState(s: sel, pos: 0, err: "")
  if parseSelectorList(st): (true, "") else: (false, st.err)

proc selectorValid*(sel: string): bool = validateSelector(sel).valid
