## math.aowl — validate the CSS math functions (calc / min / max / clamp / …).
##
## These are the values that "build up on each other": a `<calc-sum>` is made of
## `<calc-product>`s, which are made of `<calc-value>`s, and a `<calc-value>` can
## itself be a nested math function or a parenthesised sub-expression. This is a
## recursive-descent validator over the value tokens, mirroring the CSS Values-4
## grammar exactly, so it accepts every well-formed nesting and pinpoints the
## first thing wrong in a malformed one.
##
##   <calc-sum>     = <calc-product> [ [ '+' | '-' ] <calc-product> ]*
##   <calc-product> = <calc-value>   [ [ '*' | '/' ] <calc-value>   ]*
##   <calc-value>   = <number> | <dimension> | <percentage>
##                  | <calc-constant> | '(' <calc-sum> ')' | <math-function>

import value_lex

type MState = object
  toks: seq[VTok]
  pos: int
  err: string

proc lower(s: string): string =
  result = ""
  for c in s:
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32)
    else: result.add c

# --- the math-function catalogue -------------------------------------------

type Arity = object
  lo, hi: int        ## min / max argument count (hi = -1 → unbounded)
  strategy: bool     ## round(): an optional leading rounding-strategy keyword

proc mathArity(name: string): Arity =
  ## Argument arity per CSS Values 4 / Values 5. hi = -1 means "or more".
  case lower(name)
  of "calc", "abs", "sign", "sqrt", "exp",
     "sin", "cos", "tan", "asin", "acos", "atan":
    Arity(lo: 1, hi: 1, strategy: false)
  of "min", "max", "hypot":
    Arity(lo: 1, hi: -1, strategy: false)
  of "clamp":
    Arity(lo: 3, hi: 3, strategy: false)
  of "mod", "rem", "atan2", "pow":
    Arity(lo: 2, hi: 2, strategy: false)
  of "log":
    Arity(lo: 1, hi: 2, strategy: false)
  of "round":
    Arity(lo: 2, hi: 2, strategy: true)
  else:
    Arity(lo: -1, hi: -1, strategy: false)   # not a math function

proc isMathFunc*(name: string): bool = mathArity(name).lo != -1

proc argWord(n: int): string = $n & " argument" & (if n == 1: "" else: "s")

proc isCalcConstant(name: string): bool =
  case lower(name)
  of "e", "pi", "infinity", "nan": true
  else: false

proc isRoundingStrategy(name: string): bool =
  case lower(name)
  of "nearest", "up", "down", "to-zero": true
  else: false

# --- recursive-descent over the calc grammar -------------------------------

proc validateMathFunc*(name, args: string): tuple[valid: bool, error: string]

proc atEnd(m: MState): bool = m.pos >= m.toks.len
proc cur(m: MState): VTok = m.toks[m.pos]
proc fail(m: var MState, msg: string): bool =
  if m.err.len == 0: m.err = msg
  false

proc isOp(t: VTok, op: string): bool =
  ## `/` lexes as vtSlash; `(`/`)`/`*`/`+` as vtDelim; but a lone `-` lexes as a
  ## vtIdent (since `-` is a valid ident-start char, for custom properties) — so
  ## match `+`/`-` by text regardless of whether it is a delim or ident token.
  if op == "/": t.kind == vtSlash
  else: (t.kind == vtDelim or t.kind == vtIdent) and t.text == op

proc calcSum(m: var MState): bool    # forward

proc calcValue(m: var MState): bool =
  if atEnd(m): return fail(m, "unexpected end of expression")
  let t = cur(m)
  case t.kind
  of vtNumber, vtDimension, vtPercent:
    inc m.pos
    true
  of vtIdent:
    if isCalcConstant(t.text):
      inc m.pos
      true
    else:
      fail(m, "unexpected '" & t.text & "' in a math expression")
  of vtFunc:
    if isMathFunc(t.text):
      let r = validateMathFunc(t.text, t.args)
      if not r.valid: return fail(m, r.error)
      inc m.pos
      true
    else:
      # a non-math function (e.g. var()) used as a numeric term — accept it as a
      # term here; the outer grammar has already vetted its use in context.
      inc m.pos
      true
  of vtDelim:
    if t.text == "(":
      inc m.pos
      if not calcSum(m): return false
      if atEnd(m) or not isOp(cur(m), ")"):
        return fail(m, "missing ')' in a parenthesised sub-expression")
      inc m.pos
      true
    else:
      fail(m, "expected a number, dimension or '(', got '" & t.text & "'")
  else:
    fail(m, "expected a value in the math expression")

proc calcProduct(m: var MState): bool =
  if not calcValue(m): return false
  while not atEnd(m) and (isOp(cur(m), "*") or isOp(cur(m), "/")):
    let op = (if cur(m).kind == vtSlash: "/" else: cur(m).text)
    inc m.pos
    if not calcValue(m):
      if m.err.len == 0: discard fail(m, "expected a value after '" & op & "'")
      return false
  true

proc calcSum(m: var MState): bool =
  if not calcProduct(m): return false
  while not atEnd(m) and (isOp(cur(m), "+") or isOp(cur(m), "-")):
    let op = cur(m).text
    inc m.pos
    if not calcProduct(m):
      if m.err.len == 0: discard fail(m, "expected a value after '" & op & "'")
      return false
  true

proc describeTail(toks: seq[VTok], pos: int): string =
  if pos >= toks.len: return "end"
  let t = toks[pos]
  case t.kind
  of vtDelim, vtIdent: t.text
  of vtNumber: t.num
  of vtDimension: t.num & t.text
  of vtPercent: t.num & "%"
  of vtFunc: t.text & "()"
  of vtComma: ","
  of vtSlash: "/"
  else: "?"

proc splitTopArgs(toks: seq[VTok]): seq[seq[VTok]] =
  ## Split a token list on top-level commas (nested functions are already single
  ## opaque tokens, so any comma we see here is a top-level argument separator).
  result = @[]
  var cur: seq[VTok] = @[]
  for t in toks:
    if t.kind == vtComma:
      result.add cur
      cur = @[]
    else:
      cur.add t
  result.add cur

proc validateMathFunc*(name, args: string): tuple[valid: bool, error: string] =
  let ar = mathArity(name)
  if ar.lo == -1:
    return (false, name & "() is not a math function")
  var argToks = splitTopArgs(lexValue(args))
  # An empty arg list lexes to one empty group — normalise it.
  if argToks.len == 1 and argToks[0].len == 0:
    argToks = @[]

  # round(): an optional leading rounding-strategy keyword, then 2 sums.
  var startArg = 0
  if ar.strategy and argToks.len == 3 and argToks[0].len == 1 and
     argToks[0][0].kind == vtIdent and isRoundingStrategy(argToks[0][0].text):
    startArg = 1

  let nArgs = argToks.len - startArg
  if nArgs < ar.lo:
    return (false, name & "() expects " & (
      if ar.hi == ar.lo: argWord(ar.lo)
      else: "at least " & argWord(ar.lo)) & ", got " & $nArgs)
  if ar.hi != -1 and nArgs > ar.hi:
    return (false, name & "() expects " & (
      if ar.hi == ar.lo: argWord(ar.lo)
      else: "at most " & argWord(ar.hi)) & ", got " & $nArgs)

  var i = startArg
  while i < argToks.len:
    if argToks[i].len == 0:
      return (false, name & "(): argument " & $(i - startArg + 1) & " is empty")
    var m = MState(toks: argToks[i], pos: 0, err: "")
    if not calcSum(m):
      return (false, name & "(): " & (if m.err.len > 0: m.err else: "invalid argument " & $(i - startArg + 1)))
    if not atEnd(m):
      return (false, name & "(): unexpected '" & describeTail(m.toks, m.pos) &
        "' in argument " & $(i - startArg + 1))
    inc i
  (true, "")


proc parensBalanced(s: string): bool =
  ## Parentheses balance across the whole value, skipping quoted strings. Catches
  ## an unterminated `calc((1px + 2px)` that the tokenizer would otherwise absorb.
  var depth = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '"' or c == '\'':
      let q = c
      inc i
      while i < s.len and s[i] != q: inc i
      if i < s.len: inc i
    else:
      if c == '(': inc depth
      elif c == ')':
        dec depth
        if depth < 0: return false
      inc i
  depth == 0

proc validateFunctionsIn*(value: string): tuple[valid: bool, error: string]

proc validateFunctionsIn*(value: string): tuple[valid: bool, error: string] =
  ## Recursively validate every math function appearing anywhere in `value`
  ## (including nested inside non-math functions like `rgb(calc(…))`).
  if not parensBalanced(value):
    return (false, "unbalanced parentheses")
  for tok in lexValue(value):
    if tok.kind == vtFunc:
      if isMathFunc(tok.text):
        let r = validateMathFunc(tok.text, tok.args)
        if not r.valid: return (false, r.error)
      else:
        let r = validateFunctionsIn(tok.args)
        if not r.valid: return r
  (true, "")
