## parse.aowl — a real CSS stylesheet parser.
##
## Turns a whole stylesheet into a tree of rules and declarations. It is written
## to survive real-world CSS: `/* comments */`, `"…"`/`'…'` strings, semicolons
## and braces hiding inside `url(data:…;base64,…)` and `[attr="{"]`, `!important`,
## custom properties (`--x: anything`), and nested at-rules (`@media`, `@supports`,
## `@keyframes`, `@font-face`, …).
##
## The parse is one uniform recursion: inside any block, scan to the next
## top-level `;`, `{` or `}` (respecting comments / strings / brackets). A `{`
## means the run so far was a *prelude* (selector or at-rule head) introducing a
## nested block; a `;` or `}` means it was a *declaration*. That one rule handles
## style rules, `@media` bodies and `@keyframes` percentage-blocks alike.
##
## Non-raising throughout (nimony): we char-walk and build substrings by hand
## rather than slice.

type
  Declaration* = object
    prop*: string
    value*: string
    important*: bool
  Rule* = object
    prelude*: string          ## selector list, or at-rule head ("@media (…)")
    isAtRule*: bool
    atKeyword*: string        ## "media", "font-face", … ("" for a style rule)
    decls*: seq[Declaration]
    children*: seq[Rule]
  Stylesheet* = object
    rules*: seq[Rule]

# --- small non-raising string helpers --------------------------------------

proc slice(s: string, a, b: int): string =
  ## s[a ..< b], clamped, allocating a fresh string (no raising slice op).
  result = ""
  var i = a
  while i < b and i < s.len:
    if i >= 0: result.add s[i]
    inc i

proc trimmed(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r'):
    inc a
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\n' or s[b-1] == '\r'):
    dec b
  slice(s, a, b)

proc lowerCh(c: char): char =
  if c >= 'A' and c <= 'Z': char(ord(c) + 32) else: c

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    result.add lowerCh(s[i])
    inc i

# --- scanner ---------------------------------------------------------------

type Scanner = object
  s: string
  n: int

proc skipString(sc: Scanner, i: int): int =
  ## `i` points at a quote; return the index just past the closing quote.
  let q = sc.s[i]
  var j = i + 1
  while j < sc.n:
    let c = sc.s[j]
    if c == '\\':
      j += 2
      continue
    if c == q:
      return j + 1
    inc j
  j

proc skipComment(sc: Scanner, i: int): int =
  ## `i` points at `/` of a `/* … */`; return index just past `*/`.
  var j = i + 2
  while j < sc.n:
    if sc.s[j] == '*' and j + 1 < sc.n and sc.s[j+1] == '/':
      return j + 2
    inc j
  j

proc atComment(sc: Scanner, i: int): bool =
  i + 1 < sc.n and sc.s[i] == '/' and sc.s[i+1] == '*'

proc findTop(sc: Scanner, start: int): tuple[pos: int, ch: char] =
  ## From `start`, find the next top-level `;`, `{` or `}` — skipping comments,
  ## strings and anything nested inside () or []. Returns (n, '\0') at EOF.
  var i = start
  var depth = 0
  while i < sc.n:
    let c = sc.s[i]
    if atComment(sc, i):
      i = skipComment(sc, i)
    elif c == '"' or c == '\'':
      i = skipString(sc, i)
    elif c == '(' or c == '[':
      inc depth
      inc i
    elif c == ')' or c == ']':
      if depth > 0: dec depth
      inc i
    elif depth == 0 and (c == ';' or c == '{' or c == '}'):
      return (i, c)
    else:
      inc i
  (sc.n, '\x00')

# --- declaration & prelude parsing -----------------------------------------

proc stripComments(s: string): string =
  ## Drop `/* … */` comments (respecting quoted strings, so a `/*` inside a
  ## url("…") or content string is preserved). CSS allows comments mid-value.
  result = ""
  var sc = Scanner(s: s, n: s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '"' or c == '\'':
      let e = skipString(sc, i)
      var k = i
      while k < e:
        result.add s[k]
        inc k
      i = e
    elif atComment(sc, i):
      i = skipComment(sc, i)
    else:
      result.add c
      inc i

proc stripImportant(value: string): tuple[value: string, important: bool] =
  ## Remove a trailing `!important` (case-insensitive, `! important` allowed).
  let want = "important"
  var wk = want.len - 1
  var vk = value.len - 1
  while vk >= 0 and (value[vk] == ' ' or value[vk] == '\t'): dec vk
  while wk >= 0:
    if vk < 0 or lowerCh(value[vk]) != want[wk]:
      return (value, false)
    dec vk
    dec wk
  while vk >= 0 and (value[vk] == ' ' or value[vk] == '\t'): dec vk
  if vk >= 0 and value[vk] == '!':
    return (trimmed(slice(value, 0, vk)), true)
  (value, false)

proc parseDeclaration(text: string): tuple[ok: bool, decl: Declaration] =
  ## Split `prop : value [!important]` on the first top-level colon.
  var sc = Scanner(s: text, n: text.len)
  var i = 0
  var depth = 0
  var colon = -1
  while i < text.len:
    let c = text[i]
    if atComment(sc, i):
      i = skipComment(sc, i)
      continue
    if c == '"' or c == '\'':
      i = skipString(sc, i)
      continue
    if c == '(' or c == '[': inc depth
    elif c == ')' or c == ']':
      if depth > 0: dec depth
    elif c == ':' and depth == 0:
      colon = i
      break
    inc i
  if colon < 0:
    return (false, Declaration(prop: "", value: "", important: false))
  let prop = trimmed(slice(text, 0, colon))
  let raw = trimmed(stripComments(slice(text, colon + 1, text.len)))
  let si = stripImportant(raw)
  let ok = prop.len > 0
  (ok, Declaration(prop: prop, value: si.value, important: si.important))

proc atKeywordOf(prelude: string): string =
  ## For "@media (min-width: 0)" → "media"; "" if not an at-rule.
  if prelude.len == 0 or prelude[0] != '@': return ""
  var i = 1
  result = ""
  while i < prelude.len:
    let c = prelude[i]
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '-':
      result.add lowerCh(c)
      inc i
    else:
      break

# --- the recursive body parser ---------------------------------------------

proc parseBody(sc: Scanner, start: int, topLevel: bool):
    tuple[rules: seq[Rule], decls: seq[Declaration], nextPos: int] =
  var rules: seq[Rule] = @[]
  var decls: seq[Declaration] = @[]
  var i = start
  while i < sc.n:
    # skip leading whitespace / comments
    let c = sc.s[i]
    if c == ' ' or c == '\t' or c == '\n' or c == '\r':
      inc i
      continue
    if atComment(sc, i):
      i = skipComment(sc, i)
      continue
    if c == '}':
      if topLevel:
        inc i                       # stray '}' at top level: skip defensively
        continue
      return (rules, decls, i + 1)   # consume the closing brace
    let hit = findTop(sc, i)
    if hit.ch == '{':
      let prelude = trimmed(slice(sc.s, i, hit.pos))
      let inner = parseBody(sc, hit.pos + 1, false)
      let ak = atKeywordOf(prelude)
      let isAt = ak.len > 0
      rules.add Rule(prelude: prelude, isAtRule: isAt, atKeyword: ak,
                     decls: inner.decls, children: inner.rules)
      i = inner.nextPos
    elif hit.ch == ';':
      let text = trimmed(slice(sc.s, i, hit.pos))
      if text.len > 0:
        if text[0] == '@':
          # a statement at-rule with no block, e.g. @import / @charset
          rules.add Rule(prelude: text, isAtRule: true,
                         atKeyword: atKeywordOf(text), decls: @[], children: @[])
        else:
          let d = parseDeclaration(text)
          if d.ok: decls.add d.decl
      i = hit.pos + 1
    elif hit.ch == '}':
      let text = trimmed(slice(sc.s, i, hit.pos))
      if text.len > 0 and text[0] != '@':
        let d = parseDeclaration(text)
        if d.ok: decls.add d.decl
      i = hit.pos                    # let the loop see the '}' and close
    else:
      break                          # EOF
  (rules, decls, i)

proc parseStylesheet*(src: string): Stylesheet =
  var sc = Scanner(s: src, n: src.len)
  let body = parseBody(sc, 0, true)
  Stylesheet(rules: body.rules)
