## value_lex.nim — tokenize a concrete CSS value string.
##
## "10px 2rem" → [dim 10 px] [dim 2 rem];  "rgb(1,2,3)" → [func rgb];
## "50%" → [percent 50];  "#ff0000" → [hash ff0000];  "flex" → [ident flex].
## Functions are captured as one opaque token (their args are validated leniently
## by the grammar matcher for now).

type
  VTokKind* = enum
    vtIdent, vtNumber, vtDimension, vtPercent, vtString, vtHash, vtFunc,
    vtComma, vtSlash, vtDelim
  VTok* = object
    kind*: VTokKind
    text*: string        ## ident/func name, unit (dimension), hash body, or delim
    num*: string         ## numeric text for number/dimension/percent

func isDigit(c: char): bool = c >= '0' and c <= '9'
func isAlpha(c: char): bool = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
func isIdentStart(c: char): bool = isAlpha(c) or c == '_' or c == '-'
func isIdentCont(c: char): bool = isAlpha(c) or isDigit(c) or c == '_' or c == '-'

proc lexValue*(s: string): seq[VTok] =
  result = @[]
  var i = 0
  let n = s.len
  while i < n:
    let c = s[i]
    if c == ' ' or c == '\t' or c == '\n':
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
      while i < n and s[i] != q: str.add s[i]; inc i
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
    elif isIdentStart(c):
      var w = ""
      while i < n and isIdentCont(s[i]): w.add s[i]; inc i
      if i < n and s[i] == '(':
        var depth = 0
        while i < n:
          let cc = s[i]
          if cc == '(': inc depth
          elif cc == ')': dec depth
          inc i
          if depth == 0: break
        result.add VTok(kind: vtFunc, text: w)
      else:
        result.add VTok(kind: vtIdent, text: w)
    else:
      var d = ""
      d.add c
      result.add VTok(kind: vtDelim, text: d)
      inc i
