## serialize.nim — print a parsed stylesheet back out: pretty, or minified.
##
##   renderSheet(parseStylesheet(src))            # normalised, indented
##   minifyStylesheet(src)                        # smallest equivalent CSS
##
## The minifier only makes changes that cannot alter what the sheet means:
##   * comments go (except `/*! … */` licence comments), whitespace collapses,
##     the last `;` of a block goes, empty rules go;
##   * a value's whitespace collapses to single spaces — except that spaces
##     inside functions are kept where they are significant (`calc(1px + 2px)`);
##   * `0.5` → `.5`, `#ffffff` → `#fff`, `#ff0000` → `red` when shorter;
##   * `0px` → `0` — only where the property takes a bare zero AND the result
##     still validates (never in `flex`, times, or custom properties);
##   * selectors are re-spelled canonically (`normalizeSelector`) when that is
##     shorter, and never when the selector does not parse.
## Custom properties are copied byte for byte: their value is a token stream
## the author may read back with var(), so nothing about it is insignificant.

import parse
import selectors
import validator
import color

proc isWs(c: char): bool = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc trimS(s: string): string =
  var a = 0
  var b = s.len
  while a < b and isWs(s[a]): inc a
  while b > a and isWs(s[b-1]): dec b
  result = ""
  var i = a
  while i < b:
    result.add s[i]
    inc i

proc hasPrefix(s, p: string): bool =
  if s.len < p.len: return false
  var i = 0
  while i < p.len:
    if s[i] != p[i]: return false
    inc i
  true

proc isCustom(p: string): bool = p.len > 2 and p[0] == '-' and p[1] == '-'

proc collapseWs(s: string): string =
  ## Runs of whitespace → one space, outside strings; trimmed.
  result = ""
  var q = '\0'
  var sp = false
  var i = 0
  while i < s.len:
    let c = s[i]
    if q != '\0':
      result.add c
      if c == '\\' and i + 1 < s.len:
        result.add s[i+1]
        inc i
      elif c == q:
        q = '\0'
    elif c == '"' or c == '\'':
      if sp and result.len > 0: result.add ' '
      sp = false
      q = c
      result.add c
    elif isWs(c):
      sp = true
    else:
      if sp and result.len > 0: result.add ' '
      sp = false
      result.add c
    inc i

# --- values -----------------------------------------------------------------------

proc isDigit(c: char): bool = c >= '0' and c <= '9'

proc tokenize(v: string): seq[string] =
  ## Top-level tokens; separators (space , /) are their own tokens; strings and
  ## functions whole.
  result = @[]
  var cur = ""
  var depth = 0
  var q = '\0'
  var i = 0
  while i < v.len:
    let c = v[i]
    if q != '\0':
      cur.add c
      if c == '\\' and i + 1 < v.len:
        cur.add v[i+1]
        inc i
      elif c == q:
        q = '\0'
    elif c == '"' or c == '\'':
      q = c
      cur.add c
    elif c == '(':
      inc depth
      cur.add c
    elif c == ')':
      if depth > 0: dec depth
      cur.add c
    elif depth == 0 and (c == ' ' or c == ',' or c == '/'):
      if cur.len > 0: result.add cur
      cur = ""
      var one = ""
      one.add c
      result.add one
    else:
      cur.add c
    inc i
  if cur.len > 0: result.add cur

proc shortNumber(t: string): string =
  ## `0.50px` → `.5px`, `-0.5` → `-.5`, `1.0` → `1`, `00` → `0`.
  var i = 0
  var sign = ""
  if i < t.len and (t[i] == '-' or t[i] == '+'):
    if t[i] == '-': sign = "-"
    inc i
  var ip = ""
  while i < t.len and isDigit(t[i]):
    ip.add t[i]
    inc i
  var fp = ""
  var hasDot = false
  if i < t.len and t[i] == '.':
    hasDot = true
    inc i
    while i < t.len and isDigit(t[i]):
      fp.add t[i]
      inc i
  if ip.len == 0 and fp.len == 0: return t
  # an exponent (`1e3`, `2E-1`) — but not the `e` of a unit like `em`/`ex`
  if i + 1 < t.len and (t[i] == 'e' or t[i] == 'E') and
     (isDigit(t[i+1]) or ((t[i+1] == '-' or t[i+1] == '+') and i + 2 < t.len and isDigit(t[i+2]))):
    return t
  var unit = ""
  while i < t.len:
    unit.add t[i]
    inc i
  # strip leading zeros of the integer part, trailing zeros of the fraction
  var k = 0
  while k < ip.len - 1 and ip[k] == '0': inc k
  var ip2 = ""
  while k < ip.len:
    ip2.add ip[k]
    inc k
  var fp2 = fp
  while fp2.len > 0 and fp2[fp2.len-1] == '0':
    var tmp = ""
    var m = 0
    while m < fp2.len - 1:
      tmp.add fp2[m]
      inc m
    fp2 = tmp
  discard hasDot
  var num = ""
  if fp2.len == 0:
    num = (if ip2.len == 0: "0" else: ip2)
  elif ip2 == "0" or ip2.len == 0:
    num = "." & fp2
  else:
    num = ip2 & "." & fp2
  if num == "0" and sign == "-": sign = ""
  sign & num & unit

proc isZeroLength(t: string): bool =
  ## `0px`, `0.0em`, `-0rem` … (a zero with a length unit).
  var i = 0
  if i < t.len and (t[i] == '-' or t[i] == '+'): inc i
  var sawDigit = false
  while i < t.len and (t[i] == '0' or t[i] == '.'):
    if t[i] == '0': sawDigit = true
    inc i
  if not sawDigit or i >= t.len: return false
  var unit = ""
  while i < t.len:
    let c = t[i]
    if not ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')): return false
    unit.add c
    inc i
  let u = lower(unit)
  u == "px" or u == "em" or u == "rem" or u == "ex" or u == "ch" or u == "vw" or
    u == "vh" or u == "vmin" or u == "vmax" or u == "cm" or u == "mm" or u == "in" or
    u == "pt" or u == "pc" or u == "q"

proc shortColor(t: string): string =
  ## The shortest spelling of an opaque/translucent sRGB colour token.
  let p = parseColor(t)
  if not p.ok: return t
  let l = lower(t)
  if not (l[0] == '#' or (l.len > 3 and l[0] == 'r' and l[1] == 'g' and l[2] == 'b')):
    return t              # names stay names; hsl/lab/… stay as written
  var hex = toHex(p.color)                  # #rrggbb or #rrggbbaa
  # #aabbcc → #abc when each pair doubles
  var short = true
  var k = 1
  while k + 1 < hex.len:
    if hex[k] != hex[k+1]: short = false
    k = k + 2
  if short:
    var h = "#"
    k = 1
    while k < hex.len:
      h.add hex[k]
      k = k + 2
    hex = h
  var best = (if hex.len < t.len: hex else: t)
  # an exact named colour, when shorter
  for name in ["red", "tan", "navy", "gold", "gray", "blue", "teal", "lime",
               "pink", "plum", "peru", "snow", "linen", "wheat", "azure", "beige",
               "coral", "khaki", "olive", "orange", "orchid", "purple", "salmon",
               "sienna", "silver", "tomato", "violet", "maroon", "indigo"]:
    if name.len < best.len:
      let c = parseColor(name).color
      if parseColor(best).color.a >= 0.9995 and
         serializeColor(c) == serializeColor(p.color):
        best = name
  best

proc minifyValue(prop, value: string): string =
  if isCustom(prop): return value
  let l = lower(prop)
  let toks = tokenize(collapseWs(value))
  let zeroOk = not (l == "flex" or l == "flex-basis" or hasPrefix(l, "transition") or
                    hasPrefix(l, "animation"))
  result = ""
  var i = 0
  while i < toks.len:
    var t = toks[i]
    if t == " ":
      # drop spaces next to , and /
      let prev = (if result.len > 0: result[result.len-1] else: ',')
      let next = (if i + 1 < toks.len: toks[i+1] else: ",")
      if prev == ',' or prev == '/' or next == "," or next == "/":
        inc i
        continue
      result.add ' '
      inc i
      continue
    if t.len > 0 and (isDigit(t[0]) or t[0] == '.' or
                      ((t[0] == '-' or t[0] == '+') and t.len > 1 and (isDigit(t[1]) or t[1] == '.'))):
      t = shortNumber(t)
      if zeroOk and isZeroLength(t): t = "0"
    elif t.len > 0 and (t[0] == '#' or (t.len > 4 and hasPrefix(lower(t), "rgb"))):
      t = shortColor(t)
    result.add t
    inc i
  result = trimS(result)
  # never trade validity for bytes
  if result != value and not validateValue(prop, result).valid:
    if validateValue(prop, value).valid: result = collapseWs(value)

proc minifySelector(sel: string): string =
  let c = collapseWs(sel)
  # tighten around combinators and commas
  let n = normalizeSelector(c)
  if n.len == 0: return c
  var tight = ""
  var i = 0
  while i < n.len:
    let ch = n[i]
    if ch == ' ' and i > 0 and i + 1 < n.len and
       (n[i-1] == ',' or n[i-1] == '>' or n[i-1] == '+' or n[i-1] == '~' or
        n[i+1] == '>' or n[i+1] == '+' or n[i+1] == '~' or n[i+1] == ','):
      inc i
      continue
    tight.add ch
    inc i
  # the tightened form must still mean the same selector
  if normalizeSelector(tight) == n and tight.len <= c.len: tight else: c

# --- whole sheets ----------------------------------------------------------------------

proc renderDecl(d: Declaration, minify: bool): string =
  if minify:
    d.prop & ":" & minifyValue(d.prop, d.value) & (if d.important: "!important" else: "")
  else:
    d.prop & ": " & d.value & (if d.important: " !important" else: "")

proc indentOf(depth: int): string =
  result = ""
  var i = 0
  while i < depth:
    result.add "  "
    inc i

proc renderRules(rules: seq[ParsedRule], depth: int, minify: bool, dest: var string)

proc renderBlock(r: ParsedRule, depth: int, minify: bool, dest: var string) =
  let ind = indentOf(depth + 1)
  var i = 0
  var parts = 0
  while i < r.decls.len:
    if minify:
      if parts > 0: dest.add ';'
      dest.add renderDecl(r.decls[i], true)
    else:
      dest.add ind & renderDecl(r.decls[i], false) & ";\n"
    inc parts
    inc i
  if r.children.len > 0:
    if minify and parts > 0: dest.add ';'
    renderRules(r.children, depth + 1, minify, dest)

proc isEmpty(r: ParsedRule): bool =
  if r.decls.len > 0: return false
  var i = 0
  while i < r.children.len:
    if not isEmpty(r.children[i]): return false
    inc i
  r.hasBlock

proc renderRules(rules: seq[ParsedRule], depth: int, minify: bool, dest: var string) =
  let ind = indentOf(depth)
  var i = 0
  while i < rules.len:
    let r = rules[i]
    if minify and isEmpty(r) and not (r.isAtRule and r.atKeyword == "layer"):
      inc i
      continue
    var head = ""
    if r.isAtRule:
      head = "@" & r.atKeyword
      if r.atPrelude.len > 0:
        head.add " " & (if minify: collapseWs(r.atPrelude) else: r.atPrelude)
    else:
      head = (if minify: minifySelector(r.prelude) else: collapseWs(r.prelude))
    if not r.hasBlock:
      dest.add (if minify: head & ";" else: ind & head & ";\n")
    elif minify:
      dest.add head & "{"
      renderBlock(r, depth, true, dest)
      dest.add "}"
    else:
      dest.add ind & head & " {\n"
      renderBlock(r, depth, false, dest)
      dest.add ind & "}\n"
    inc i

proc renderSheet*(sheet: ParsedSheet): string =
  ## The sheet, normalised and indented: one declaration per line.
  result = ""
  renderRules(sheet.rules, 0, false, result)

proc licenceComments(src: string): string =
  result = ""
  var i = 0
  var q = '\0'
  while i + 2 < src.len:
    let c = src[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c == '"' or c == '\'':
      q = c
    elif c == '/' and src[i+1] == '*' and src[i+2] == '!':
      var j = i + 3
      while j + 1 < src.len and not (src[j] == '*' and src[j+1] == '/'): inc j
      var k = i
      while k < j + 2 and k < src.len:
        result.add src[k]
        inc k
      i = j + 2
      continue
    inc i

proc minifyStylesheet*(src: string): string =
  ## The smallest equivalent stylesheet (see the module doc for what changes).
  result = licenceComments(src)
  renderRules(parseStylesheet(src).rules, 0, true, result)
