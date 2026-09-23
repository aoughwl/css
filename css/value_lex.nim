## value_lex.nim — tokenize a concrete CSS value string.
##
## "10px 2rem" → [dim 10 px] [dim 2 rem];  "rgb(1,2,3)" → [func rgb];
## "50%" → [percent 50];  "#ff0000" → [hash ff0000];  "flex" → [ident flex].
## Functions are captured as one opaque token (their args are validated leniently
## by the grammar matcher for now).

type
  VTokKind* = enum
    vtIdent, vtNumber, vtDimension, vtPercent, vtString, vtHash, vtFunc,
    vtComma, vtSlash, vtDelim,
    vtURange             ## unicode-range token: U+0-7F, u+4??, U+0025-00FF
  VTok* = object
    kind*: VTokKind
    text*: string        ## ident/func name, unit (dimension), hash body, or delim
    num*: string         ## numeric text for number/dimension/percent
    args*: string        ## for vtFunc: the raw argument string inside the parens

func isDigit(c: char): bool = c >= '0' and c <= '9'
func isAlpha(c: char): bool = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
func isIdentStart(c: char): bool = isAlpha(c) or c == '_' or c == '-'
func isIdentCont(c: char): bool = isAlpha(c) or isDigit(c) or c == '_' or c == '-' or ord(c) >= 128
func isHexCh(c: char): bool =
  isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

proc lexURange(s: string, start: int): tuple[ok: bool, stop: int, text: string] =
  ## `start` points just past `U+`. A unicode-range is 1-6 hex digits with
  ## trailing `?` wildcards (6 total), optionally `-` and 1-6 more hex digits.
  var i = start
  var t = ""
  var hex = 0
  while i < s.len and isHexCh(s[i]) and hex < 6:
    t.add s[i]; inc i; inc hex
  var q = 0
  while i < s.len and s[i] == '?' and hex + q < 6:
    t.add s[i]; inc i; inc q
  if hex + q == 0: return (false, start, "")
  if q == 0 and i + 1 < s.len and s[i] == '-' and isHexCh(s[i+1]):
    t.add '-'; inc i
    var h2 = 0
    while i < s.len and isHexCh(s[i]) and h2 < 6:
      t.add s[i]; inc i; inc h2
  if i < s.len and (isIdentCont(s[i]) or s[i] == '?'): return (false, start, "")
  (true, i, t)

proc lexValue*(s: string): seq[VTok] =
  result = @[]
  var i = 0
  let n = s.len
  while i < n:
    let c = s[i]
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f':
      inc i
    elif c == ',':
      result.add VTok(kind: vtComma); inc i
    elif c == '/':
      result.add VTok(kind: vtSlash); inc i
    elif c == '#':
      inc i
      var h = ""
      while i < n and isIdentCont(s[i]): h.add s[i]; inc i
      result.add VTok(kind: vtHash, text: h)
    elif c == '"' or c == '\'':
      let q = c
      inc i
      var str = ""
      while i < n and s[i] != q:
        if s[i] == '\\' and i + 1 < n:
          str.add s[i]; inc i
        str.add s[i]; inc i
      if i < n: inc i
      result.add VTok(kind: vtString, text: str)
    elif isDigit(c) or (c == '.' and i+1 < n and isDigit(s[i+1])) or
         ((c == '-' or c == '+') and i+1 < n and
          (isDigit(s[i+1]) or (s[i+1] == '.' and i+2 < n and isDigit(s[i+2])))):
      var num = ""
      if c == '-' or c == '+': num.add c; inc i
      while i < n and isDigit(s[i]): num.add s[i]; inc i
      if i < n and s[i] == '.':
        num.add '.'; inc i
        while i < n and isDigit(s[i]): num.add s[i]; inc i
      if i < n and (s[i] == 'e' or s[i] == 'E'):
        var j = i+1
        if j < n and (s[j] == '+' or s[j] == '-'): inc j
        if j < n and isDigit(s[j]):
          num.add s[i]; inc i
          if s[i] == '+' or s[i] == '-': num.add s[i]; inc i
          while i < n and isDigit(s[i]): num.add s[i]; inc i
      if i < n and s[i] == '%':
        inc i
        result.add VTok(kind: vtPercent, num: num)
      elif i < n and isAlpha(s[i]):
        var u = ""
        while i < n and isIdentCont(s[i]): u.add s[i]; inc i
        result.add VTok(kind: vtDimension, text: u, num: num)
      else:
        result.add VTok(kind: vtNumber, num: num)
    elif (c == 'u' or c == 'U') and i + 2 < n and s[i+1] == '+' and
         (isHexCh(s[i+2]) or s[i+2] == '?') and lexURange(s, i + 2).ok:
      let r = lexURange(s, i + 2)
      result.add VTok(kind: vtURange, text: r.text)
      i = r.stop
    elif isIdentStart(c) or c == '\\' or ord(c) >= 128:
      var w = ""
      while i < n and (isIdentCont(s[i]) or s[i] == '\\'):
        if s[i] == '\\':
          # an escape is part of the identifier: `\:` or a hex escape `\31 `
          w.add s[i]; inc i
          if i < n and isHexCh(s[i]):
            var h = 0
            while i < n and isHexCh(s[i]) and h < 6: w.add s[i]; inc i; inc h
            if i < n and s[i] == ' ': inc i
          elif i < n:
            w.add s[i]; inc i
        else:
          w.add s[i]; inc i
      if i < n and s[i] == '(':
        var depth = 0
        var argStr = ""
        inc i               # consume '('
        inc depth
        while i < n and depth > 0:
          let cc = s[i]
          if cc == '(': inc depth
          elif cc == ')': dec depth
          if depth > 0: argStr.add cc
          inc i
        result.add VTok(kind: vtFunc, text: w, args: argStr)
      else:
        result.add VTok(kind: vtIdent, text: w)
    else:
      var d = ""
      d.add c
      result.add VTok(kind: vtDelim, text: d)
      inc i
