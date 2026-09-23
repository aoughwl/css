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
##
## Every rule and declaration carries the 1-based `line` it starts on, so a
## validator built on top can point at the source.
##
## The types are named `Parsed…` because `css/stylesheet` already owns
## `Stylesheet`/`Rule` for an AUTHORED sheet (selector → `Style` value); the two
## are exported together from `css`, and sharing names made both unusable.

type
  Declaration* = object
    prop*: string
    value*: string
    important*: bool
    line*: int                ## 1-based source line of the property name
  ParsedRule* = object
    prelude*: string          ## selector list, or at-rule head ("@media (…)"),
                              ## comments stripped
    isAtRule*: bool
    atKeyword*: string        ## "media", "font-face", … ("" for a style rule)
    atPrelude*: string        ## an at-rule's head after the keyword: "(min-width: 0)"
    hasBlock*: bool           ## `{ … }` present (false for `@import …;`)
    decls*: seq[Declaration]
    children*: seq[ParsedRule]
    line*: int                ## 1-based source line of the prelude
  ParsedSheet* = object
    rules*: seq[ParsedRule]

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
  lineAt: seq[int]            ## byte offset of the start of each line

proc newScanner(s: string): Scanner =
  result = Scanner(s: s, n: s.len, lineAt: @[0])
  var i = 0
  while i < s.len:
    if s[i] == '\n': result.lineAt.add i + 1
    inc i

proc lineOf(sc: Scanner, pos: int): int =
  ## 1-based line containing byte `pos` (binary search over line starts).
  var lo = 0
  var hi = sc.lineAt.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if sc.lineAt[mid] <= pos: lo = mid
    else: hi = mid - 1
  lo + 1

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
    elif c == '\\':
      i += 2                        # an escaped char is never a delimiter
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
  var sc = Scanner(s: s, n: s.len, lineAt: @[])
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
  var sc = Scanner(s: text, n: text.len, lineAt: @[])
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
    return (false, Declaration(prop: "", value: "", important: false, line: 0))
  let prop = trimmed(slice(text, 0, colon))
  let raw = trimmed(stripComments(slice(text, colon + 1, text.len)))
  let si = stripImportant(raw)
  let ok = prop.len > 0
  (ok, Declaration(prop: prop, value: si.value, important: si.important, line: 0))

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

proc atPreludeOf(prelude: string): string =
  ## "@media (min-width: 0)" → "(min-width: 0)".
  var i = 1
  while i < prelude.len:
    let c = prelude[i]
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '-' or
       (c >= '0' and c <= '9'):
      inc i
    else:
      break
  trimmed(slice(prelude, i, prelude.len))

# --- the recursive body parser ---------------------------------------------

proc parseBody(sc: Scanner, start: int, topLevel: bool):
    tuple[rules: seq[ParsedRule], decls: seq[Declaration], nextPos: int] =
  var rules: seq[ParsedRule] = @[]
  var decls: seq[Declaration] = @[]
  var i = start
  while i < sc.n:
    # skip leading whitespace / comments
    let c = sc.s[i]
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f':
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
    if topLevel and (c == '<' or c == '-') and
       (slice(sc.s, i, i + 4) == "<!--" or slice(sc.s, i, i + 3) == "-->"):
      i = i + (if c == '<': 4 else: 3)   # CDO / CDC: ignored at top level
      continue
    let hit = findTop(sc, i)
    if hit.ch == '{':
      let prelude = trimmed(stripComments(slice(sc.s, i, hit.pos)))
      let inner = parseBody(sc, hit.pos + 1, false)
      let ak = atKeywordOf(prelude)
      let isAt = ak.len > 0
      rules.add ParsedRule(prelude: prelude, isAtRule: isAt, atKeyword: ak,
                           atPrelude: (if isAt: atPreludeOf(prelude) else: ""),
                           hasBlock: true, decls: inner.decls,
                           children: inner.rules, line: lineOf(sc, i))
      i = inner.nextPos
    elif hit.ch == ';':
      let text = trimmed(slice(sc.s, i, hit.pos))
      if text.len > 0:
        if text[0] == '@':
          # a statement at-rule with no block, e.g. @import / @charset
          let st = trimmed(stripComments(text))
          rules.add ParsedRule(prelude: st, isAtRule: true,
                               atKeyword: atKeywordOf(st), atPrelude: atPreludeOf(st),
                               hasBlock: false, decls: @[], children: @[],
                               line: lineOf(sc, i))
        else:
          var d = parseDeclaration(text)
          if d.ok:
            d.decl.line = lineOf(sc, i)
            decls.add d.decl
      i = hit.pos + 1
    elif hit.ch == '}':
      let text = trimmed(slice(sc.s, i, hit.pos))
      if text.len > 0 and text[0] != '@':
        var d = parseDeclaration(text)
        if d.ok:
          d.decl.line = lineOf(sc, i)
          decls.add d.decl
      i = hit.pos                    # let the loop see the '}' and close
    else:
      # EOF inside a run: an unterminated final declaration / statement is
      # still honoured, as the CSS Syntax spec does at end of input.
      let text = trimmed(slice(sc.s, i, sc.n))
      if text.len > 0:
        if text[0] == '@':
          let st = trimmed(stripComments(text))
          rules.add ParsedRule(prelude: st, isAtRule: true,
                               atKeyword: atKeywordOf(st), atPrelude: atPreludeOf(st),
                               hasBlock: false, decls: @[], children: @[],
                               line: lineOf(sc, i))
        elif not topLevel:
          var d = parseDeclaration(text)
          if d.ok:
            d.decl.line = lineOf(sc, i)
            decls.add d.decl
      i = sc.n
  (rules, decls, i)

proc parseStylesheet*(src: string): ParsedSheet =
  ## Parse a whole stylesheet. Top-level declarations (which CSS does not
  ## allow) are dropped, exactly as a browser drops them.
  let sc = newScanner(src)
  let body = parseBody(sc, 0, true)
  ParsedSheet(rules: body.rules)

proc parseDeclarations*(src: string): seq[Declaration] =
  ## Parse the inside of a declaration block — a `style="…"` attribute, or the
  ## text between `{` and `}` — into its declarations (nested rules dropped).
  let sc = newScanner(src)
  let body = parseBody(sc, 0, false)
  body.decls
