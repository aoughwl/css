## imports.nim — resolve `@import` into one self-contained stylesheet.
##
##   proc load(url: string): tuple[ok: bool, css: string] =
##     try: (true, readFile("styles/" & url)) except: (false, "")
##   let flat = resolveImports(readFile("styles/main.css"), "main.css", load)
##   flat.css        # the whole sheet, every @import inlined
##   flat.problems   # imports that could not be loaded, cycles, misplaced ones
##
## Each `@import url [layer|layer(name)] [supports(cond)] [media]` is replaced
## by the imported sheet wrapped exactly as the import scoped it:
##
##   @import url(a.css) layer(base) supports(display: grid) screen;
##   →  @media screen { @supports (display: grid) { @layer base { …a.css… } } }
##
## Relative URLs resolve against the importing sheet's URL. Cycles are broken
## (and reported); the same file imported twice is inlined twice, as a browser
## would apply it twice. An `@import` after other rules is ignored — and
## reported — exactly as CSS ignores it. `@charset` of imported sheets is
## dropped.

import parse

type
  Loader* = proc (url: string): tuple[ok: bool, css: string] {.nimcall.}

  ImportResult* = object
    css*: string
    problems*: seq[string]
    files*: seq[string]          ## every URL inlined, in order

proc trimW(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r'): inc a
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\n' or s[b-1] == '\r'): dec b
  result = ""
  var i = a
  while i < b:
    result.add s[i]
    inc i

proc lowerS(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc sub(s: string, a, b: int): string =
  result = ""
  var i = a
  while i < b and i < s.len:
    if i >= 0: result.add s[i]
    inc i

proc closeParen(s: string, open: int): int =
  var depth = 0
  var i = open
  var q = '\0'
  while i < s.len:
    let c = s[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c == '"' or c == '\'': q = c
    elif c == '(': inc depth
    elif c == ')':
      dec depth
      if depth == 0: return i
    inc i
  -1

type ImportSpec* = object
  url*: string
  layer*: bool
  layerName*: string
  supports*: string
  media*: string

proc parseImport*(prelude: string): tuple[ok: bool, spec: ImportSpec] =
  ## Take an `@import` prelude apart (without the `@import`).
  var spec = ImportSpec()
  let p = trimW(prelude)
  var i = 0
  if i < p.len and (p[i] == '"' or p[i] == '\''):
    let q = p[i]
    inc i
    while i < p.len and p[i] != q:
      if p[i] == '\\' and i + 1 < p.len:
        inc i
      spec.url.add p[i]
      inc i
    if i >= p.len: return (false, spec)
    inc i
  elif lowerS(sub(p, 0, 4)) == "url(":
    let c = closeParen(p, 3)
    if c < 0: return (false, spec)
    spec.url = trimW(sub(p, 4, c))
    if spec.url.len >= 2 and (spec.url[0] == '"' or spec.url[0] == '\''):
      spec.url = sub(spec.url, 1, spec.url.len - 1)
    i = c + 1
  else:
    return (false, spec)
  var rest = trimW(sub(p, i, p.len))
  if lowerS(sub(rest, 0, 6)) == "layer(":
    let c = closeParen(rest, 5)
    if c < 0: return (false, spec)
    spec.layer = true
    spec.layerName = trimW(sub(rest, 6, c))
    rest = trimW(sub(rest, c + 1, rest.len))
  elif lowerS(sub(rest, 0, 5)) == "layer" and
       (rest.len == 5 or rest[5] == ' ' or rest[5] == '\t' or rest[5] == '\n'):
    spec.layer = true
    rest = trimW(sub(rest, 5, rest.len))
  if lowerS(sub(rest, 0, 9)) == "supports(":
    let c = closeParen(rest, 8)
    if c < 0: return (false, spec)
    var cond = trimW(sub(rest, 9, c))
    # the bare declaration form: supports(display: grid)
    if cond.len > 0 and cond[0] != '(' and lowerS(sub(cond, 0, 4)) != "not " and
       lowerS(sub(cond, 0, 9)) != "selector(":
      cond = "(" & cond & ")"
    spec.supports = cond
    rest = trimW(sub(rest, c + 1, rest.len))
  spec.media = rest
  (true, spec)

proc resolveUrl*(base, url: string): string =
  ## Resolve `url` against the URL of the sheet that imports it. Absolute URLs
  ## (with a scheme or starting with `/`) are returned as they are.
  var i = 0
  while i < url.len and url[i] != '/' and url[i] != ':': inc i
  if i < url.len and url[i] == ':': return url            # has a scheme
  if url.len > 0 and url[0] == '/': return url
  # directory of base
  var cut = -1
  i = 0
  while i < base.len:
    if base[i] == '/': cut = i
    inc i
  var dir = (if cut >= 0: sub(base, 0, cut + 1) else: "")
  var u = url
  # fold ./ and ../
  while true:
    if sub(u, 0, 2) == "./":
      u = sub(u, 2, u.len)
    elif sub(u, 0, 3) == "../":
      u = sub(u, 3, u.len)
      # drop the last directory of dir
      var d = dir
      if d.len > 0 and d[d.len-1] == '/': d = sub(d, 0, d.len - 1)
      var c2 = -1
      var k = 0
      while k < d.len:
        if d[k] == '/': c2 = k
        inc k
      dir = (if c2 >= 0: sub(d, 0, c2 + 1) else: "")
    else:
      break
  dir & u

proc wrap(css: string, spec: ImportSpec): string =
  result = css
  if spec.layer:
    result = "@layer" & (if spec.layerName.len > 0: " " & spec.layerName else: "") &
             " {\n" & result & "\n}"
  if spec.supports.len > 0:
    result = "@supports " & spec.supports & " {\n" & result & "\n}"
  if spec.media.len > 0:
    result = "@media " & spec.media & " {\n" & result & "\n}"

proc findStatementEnd(src: string, start: int): int =
  ## From an `@import` at `start`, the index just past its `;`.
  var i = start
  var q = '\0'
  var depth = 0
  while i < src.len:
    let c = src[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c == '"' or c == '\'': q = c
    elif c == '(': inc depth
    elif c == ')':
      if depth > 0: dec depth
    elif c == ';' and depth == 0: return i + 1
    elif c == '{' and depth == 0: return i
    inc i
  src.len

proc skipTrivia(src: string, i: int): int =
  ## Whitespace and comments.
  result = i
  while result < src.len:
    let c = src[result]
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f':
      inc result
    elif c == '/' and result + 1 < src.len and src[result+1] == '*':
      result = result + 2
      while result + 1 < src.len and not (src[result] == '*' and src[result+1] == '/'):
        inc result
      result = result + 2
    else:
      break

proc inline(src, url: string, load: Loader, stack: var seq[string],
            res: var ImportResult, depth: int): string =
  ## Rewrite the leading @import statements of `src`; leave the rest verbatim.
  result = ""
  var i = skipTrivia(src, 0)
  result.add sub(src, 0, i)
  var pastImports = false
  while i < src.len:
    let atImport = lowerS(sub(src, i, i + 7)) == "@import" and
                   (i + 7 >= src.len or src[i+7] == ' ' or src[i+7] == '\t' or
                    src[i+7] == '\n' or src[i+7] == '"' or src[i+7] == '\'' or
                    src[i+7] == 'u' or src[i+7] == 'U')
    let atCharset = lowerS(sub(src, i, i + 8)) == "@charset"
    let atLayerStmt = lowerS(sub(src, i, i + 6)) == "@layer"
    if atCharset:
      let e = findStatementEnd(src, i)
      if depth == 0: result.add sub(src, i, e) & "\n"
      i = skipTrivia(src, e)
      continue
    if atLayerStmt and not pastImports:
      let e = findStatementEnd(src, i)
      if e > 0 and src[e-1] == ';':
        result.add sub(src, i, e) & "\n"
        i = skipTrivia(src, e)
        continue
    if not atImport:
      pastImports = true
      # anything else: copy up to the next @import that could be misplaced
      break
    let e = findStatementEnd(src, i)
    var prelude = sub(src, i + 7, e)
    if prelude.len > 0 and prelude[prelude.len-1] == ';': prelude = sub(prelude, 0, prelude.len - 1)
    let p = parseImport(prelude)
    if not p.ok:
      res.problems.add url & ": malformed @import " & trimW(prelude)
    else:
      let target = resolveUrl(url, p.spec.url)
      var cyclic = false
      var k = 0
      while k < stack.len:
        if stack[k] == target: cyclic = true
        inc k
      if cyclic:
        res.problems.add url & ": @import cycle through " & target & " (skipped)"
      elif depth > 32:
        res.problems.add url & ": @import nesting too deep at " & target
      else:
        let got = load(target)
        if not got.ok:
          res.problems.add url & ": cannot load " & target
        else:
          stack.add target
          res.files.add target
          let body = inline(got.css, target, load, stack, res, depth + 1)
          var kept: seq[string] = @[]
          k = 0
          while k < stack.len - 1:
            kept.add stack[k]
            inc k
          stack = kept
          result.add wrap(body, p.spec) & "\n"
    i = skipTrivia(src, e)
  # the rest of the sheet, verbatim — but a later @import is ignored by CSS
  var rest = sub(src, i, src.len)
  let sheet = parseStylesheet(rest)
  var lineBase = 0
  var k = 0
  while k < i and k < src.len:
    if src[k] == '\n': inc lineBase
    inc k
  var r = 0
  while r < sheet.rules.len:
    if sheet.rules[r].isAtRule and sheet.rules[r].atKeyword == "import":
      res.problems.add url & ":" & $(lineBase + sheet.rules[r].line) &
        ": @import after other rules is ignored"
    inc r
  result.add rest

proc resolveImports*(src, url: string, load: Loader): ImportResult =
  ## Inline every `@import` of `src` (whose own URL is `url`) through `load`.
  var res = ImportResult(css: "", problems: @[], files: @[])
  var stack = @[url]
  res.css = inline(src, url, load, stack, res, 0)
  res
