## validator.nim — single-pass, compiled-grammar CSS value validator.
##
## A ground-up overhaul of the old backtracking matcher. Two phases:
##
##   1. COMPILE (once, cached): every property/syntax grammar is parsed and
##      lowered into a flat node **arena** (`seq[CNode]`), with `<syntax>` and
##      `<'prop'>` references resolved to node ids. Grammars are compiled lazily
##      on first use and cached forever, so nothing is ever re-parsed.
##
##   2. MATCH (single pass, memoized): a value's tokens are matched against a
##      compiled grammar with packrat memoization keyed by (nodeId, position).
##      Each (node, position) pair is computed at most once → no exponential
##      backtracking. A left-recursion guard makes cyclic grammars (calc) safe.
##
## On failure it reports a **farthest-failure** error: the furthest token a
## terminal reached and what was expected there ("expected a length, got '20'").

import std/[tables, sets]
import vds
import value_lex
import data_load

# ---------------------------------------------------------------------------
# Compiled grammar arena
# ---------------------------------------------------------------------------

type
  Op = enum
    opKw          ## literal keyword (an ident value)
    opLit         ## literal token: / or ,
    opPrim        ## a leaf data type matched by a token predicate
    opFuncTok     ## function-notation type → matches a function token
    opRef         ## reference to another compiled grammar (target id)
    opSeq, opOr, opAny, opAll
  CNode = object
    op: Op
    mult: Mult
    lo, hi: int
    text: string      ## kw/lit text, or primitive name
    kids: seq[int]
    target: int       ## opRef → root id of the referenced grammar

var arena: seq[CNode] = @[]
var roots = initTable[string, int]()

const primNames = ["length", "percentage", "number", "integer", "angle", "time",
  "frequency", "resolution", "flex", "string", "hex-color", "custom-ident",
  "dashed-ident", "ident", "custom-property-name", "keyframes-name", "url",
  "dimension", "declaration-value", "any-value", "declaration-list"]

func isPrimName(name: string): bool =
  var i = 0
  while i < primNames.len:
    if primNames[i] == name: return true
    inc i
  false

func endsParens(name: string): bool =
  name.len >= 2 and name[name.len-2] == '(' and name[name.len-1] == ')'

proc allocNode(n: CNode): int =
  arena.add n
  arena.len - 1

proc compileVNode(v: VNode): int
proc getGrammar(key, src: string): int

proc compileVNode(v: VNode): int =
  case v.kind
  of nkKeyword:
    result = allocNode CNode(op: opKw, text: v.text, mult: v.mult, lo: v.lo, hi: v.hi)
  of nkLiteral:
    result = allocNode CNode(op: opLit, text: v.text, mult: v.mult, lo: v.lo, hi: v.hi)
  of nkType:
    if endsParens(v.name):
      result = allocNode CNode(op: opFuncTok, text: v.name, mult: v.mult, lo: v.lo, hi: v.hi)
    elif isPrimName(v.name):
      result = allocNode CNode(op: opPrim, text: v.name, mult: v.mult, lo: v.lo, hi: v.hi)
    elif isSyntax(v.name):
      let t = getGrammar("s:" & v.name, syntaxOf(v.name))
      result = allocNode CNode(op: opRef, target: t, text: v.name, mult: v.mult, lo: v.lo, hi: v.hi)
    else:
      result = allocNode CNode(op: opPrim, text: "*any*", mult: v.mult, lo: v.lo, hi: v.hi)
  of nkProp:
    if isProperty(v.name):
      let t = getGrammar("p:" & v.name, propertySyntax(v.name))
      result = allocNode CNode(op: opRef, target: t, text: v.name, mult: v.mult, lo: v.lo, hi: v.hi)
    else:
      result = allocNode CNode(op: opPrim, text: "*any*", mult: v.mult, lo: v.lo, hi: v.hi)
  of nkFunc:
    result = allocNode CNode(op: opFuncTok, text: v.fname, mult: v.mult, lo: v.lo, hi: v.hi)
  of nkList:
    var kidIds: seq[int] = @[]
    var i = 0
    while i < v.kids.len:
      kidIds.add compileVNode(v.kids[i])
      inc i
    var op = opSeq
    case v.comb
    of cbSeq: op = opSeq
    of cbOr: op = opOr
    of cbAny: op = opAny
    of cbAll: op = opAll
    result = allocNode CNode(op: op, kids: kidIds, mult: v.mult, lo: v.lo, hi: v.hi)

proc getGrammar(key, src: string): int =
  ## Compile a named grammar into the arena, cached. Reserves the root id BEFORE
  ## compiling the body so recursive references resolve (cycle-safe).
  if roots.hasKey(key): return roots.getOrDefault(key, 0)
  let rid = allocNode CNode(op: opSeq, kids: @[])   # placeholder
  roots[key] = rid
  let bodyId = compileVNode(parseSyntax(src))
  arena[rid] = CNode(op: opRef, target: bodyId, mult: mkOne, text: key)
  rid

# ---------------------------------------------------------------------------
# Match state (reset per value) + tiny helpers
# ---------------------------------------------------------------------------

var gToks: seq[VTok] = @[]
var gMemo = initTable[int, seq[int]]()
var gInprog = initHashSet[int]()
var gErrPos = 0
var gExpected: seq[string] = @[]

func lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    var c = s[i]
    if c >= 'A' and c <= 'Z': c = char(ord(c) + 32)
    result.add c
    inc i

func contains(s: seq[int], v: int): bool =
  var i = 0
  while i < s.len:
    if s[i] == v: return true
    inc i
  false

func containsStr(s: seq[string], v: string): bool =
  var i = 0
  while i < s.len:
    if s[i] == v: return true
    inc i
  false

proc addUniq(s: var seq[int], v: int) =
  if not contains(s, v): s.add v

proc expect(pos: int, desc: string) =
  if pos > gErrPos:
    gErrPos = pos
    gExpected = @[desc]
  elif pos == gErrPos:
    if not containsStr(gExpected, desc): gExpected.add desc

func isZeroNum(num: string): bool =
  var seen = false
  var i = 0
  while i < num.len:
    let c = num[i]
    if c == '0': seen = true
    elif c == '.' or c == '+' or c == '-': discard
    else: return false
    inc i
  seen

func isIntNum(num: string): bool =
  var i = 0
  while i < num.len:
    if num[i] == '.': return false
    inc i
  true

func newUsed(n: int): seq[bool] =
  result = @[]
  var i = 0
  while i < n:
    result.add false
    inc i

# ---------------------------------------------------------------------------
# The matcher (single pass, memoized)
# ---------------------------------------------------------------------------

proc matchNode(id, pos: int): seq[int]
proc matchOne(id, pos: int): seq[int]

proc matchPrim(name: string, pos: int): seq[int] =
  if pos >= gToks.len:
    expect(pos, "a " & name)
    return @[]
  let t = gToks[pos]
  if name == "*any*":
    return @[pos+1]
  if name == "declaration-value" or name == "any-value" or name == "declaration-list":
    return @[gToks.len]
  var ok = false
  case name
  of "length":
    ok = (t.kind == vtDimension and unitDimension(t.text) == "length") or
         (t.kind == vtNumber and isZeroNum(t.num)) or t.kind == vtFunc
  of "percentage":
    ok = t.kind == vtPercent or t.kind == vtFunc
  of "number":
    ok = t.kind == vtNumber or t.kind == vtFunc
  of "integer":
    ok = (t.kind == vtNumber and isIntNum(t.num)) or t.kind == vtFunc
  of "angle":
    ok = (t.kind == vtDimension and unitDimension(t.text) == "angle") or
         (t.kind == vtNumber and isZeroNum(t.num)) or t.kind == vtFunc
  of "time":
    ok = (t.kind == vtDimension and unitDimension(t.text) == "time") or t.kind == vtFunc
  of "frequency":
    ok = (t.kind == vtDimension and unitDimension(t.text) == "frequency") or t.kind == vtFunc
  of "resolution":
    ok = (t.kind == vtDimension and unitDimension(t.text) == "resolution") or t.kind == vtFunc
  of "flex":
    ok = t.kind == vtDimension and unitDimension(t.text) == "flex"
  of "string":
    ok = t.kind == vtString
  of "hex-color":
    ok = t.kind == vtHash
  of "custom-ident", "dashed-ident", "ident", "custom-property-name", "keyframes-name":
    ok = t.kind == vtIdent
  of "url":
    ok = t.kind == vtFunc or t.kind == vtString
  of "dimension":
    ok = t.kind == vtDimension
  else:
    ok = false
  if ok: return @[pos+1]
  expect(pos, "a " & name)
  @[]

proc matchOrderless(kids: seq[int], flags: seq[bool], pos: int,
                    requireAll: bool, count: int): seq[int] =
  ## `||` / `&&`: consume alternatives in any order, each at most once.
  result = @[]
  var i = 0
  if requireAll:
    # `&&` succeeds here only if every not-yet-consumed operand can match empty
    # at `pos` (i.e. is optional). Otherwise `A && b?` would wrongly demand `b`.
    var canFinish = true
    while i < kids.len:
      if not flags[i]:
        var zero = false
        for e in matchNode(kids[i], pos):
          if e == pos: zero = true
        if not zero: canFinish = false
      inc i
    if canFinish: addUniq(result, pos)
  else:
    if count >= 1: addUniq(result, pos)
  i = 0
  while i < kids.len:
    if not flags[i]:
      for e in matchNode(kids[i], pos):
        if e > pos:
          var u2 = flags
          u2[i] = true
          for e2 in matchOrderless(kids, u2, e, requireAll, count + 1):
            addUniq(result, e2)
    inc i

proc repeat(id, pos, lo, hi: int, comma: bool): seq[int] =
  result = @[]
  if lo == 0: addUniq(result, pos)
  var frontier = @[pos]
  var reps = 0
  while reps < hi and frontier.len > 0:
    var nxt: seq[int] = @[]
    var f = 0
    while f < frontier.len:
      var sp = frontier[f]
      var ok = true
      if reps > 0 and comma:
        if sp < gToks.len and gToks[sp].kind == vtComma: sp = sp + 1
        else: ok = false
      if ok:
        for e in matchOne(id, sp):
          if e > sp: addUniq(nxt, e)
      inc f
    reps += 1
    frontier = nxt
    if reps >= lo:
      var k = 0
      while k < frontier.len:
        addUniq(result, frontier[k])
        inc k

proc matchOne(id, pos: int): seq[int] =
  let n = arena[id]
  case n.op
  of opKw:
    if pos < gToks.len and gToks[pos].kind == vtIdent and
       lower(gToks[pos].text) == lower(n.text):
      result = @[pos+1]
    else:
      expect(pos, "'" & n.text & "'")
      result = @[]
  of opLit:
    if n.text == "/" and pos < gToks.len and gToks[pos].kind == vtSlash:
      result = @[pos+1]
    elif n.text == "," and pos < gToks.len and gToks[pos].kind == vtComma:
      result = @[pos+1]
    else:
      expect(pos, "'" & n.text & "'")
      result = @[]
  of opPrim:
    result = matchPrim(n.text, pos)
  of opFuncTok:
    if pos < gToks.len and gToks[pos].kind == vtFunc:
      result = @[pos+1]
    else:
      expect(pos, "a function")
      result = @[]
  of opRef:
    result = matchNode(n.target, pos)
  of opSeq:
    var frontier = @[pos]
    var i = 0
    while i < n.kids.len:
      var nxt: seq[int] = @[]
      var f = 0
      while f < frontier.len:
        for e in matchNode(n.kids[i], frontier[f]): addUniq(nxt, e)
        inc f
      frontier = nxt
      if frontier.len == 0: break
      inc i
    result = frontier
  of opOr:
    result = @[]
    var i = 0
    while i < n.kids.len:
      for e in matchNode(n.kids[i], pos): addUniq(result, e)
      inc i
  of opAny:
    result = matchOrderless(n.kids, newUsed(n.kids.len), pos, false, 0)
  of opAll:
    result = matchOrderless(n.kids, newUsed(n.kids.len), pos, true, 0)

proc matchNode(id, pos: int): seq[int] =
  let key = id * 100000 + pos
  if gMemo.hasKey(key): return gMemo.getOrDefault(key, @[])
  if key in gInprog: return @[]          # left-recursion guard
  gInprog.incl key
  let m = arena[id].mult
  case m
  of mkOne:
    result = matchOne(id, pos)
  of mkOpt:
    result = @[pos]
    for p in matchOne(id, pos): addUniq(result, p)
  of mkStar:
    result = repeat(id, pos, 0, HugeN, false)
  of mkPlus:
    result = repeat(id, pos, 1, HugeN, false)
  of mkHash:
    result = repeat(id, pos, 1, HugeN, true)
  of mkRange:
    result = repeat(id, pos, arena[id].lo, arena[id].hi, false)
  gInprog.excl key
  gMemo[key] = result

# `repeat`, `matchOne`, `matchOrderless` reference each other and `matchNode`;
# nimony resolves the forward use of `matchOne`/`matchNode` above.

# ---------------------------------------------------------------------------
# public API
# ---------------------------------------------------------------------------

func isGlobalKeyword(w: string): bool =
  let l = lower(w)
  l == "inherit" or l == "initial" or l == "unset" or l == "revert" or l == "revert-layer"

proc describeTok(t: VTok): string =
  case t.kind
  of vtIdent: "'" & t.text & "'"
  of vtNumber: "number '" & t.num & "'"
  of vtDimension: "'" & t.num & t.text & "'"
  of vtPercent: "'" & t.num & "%'"
  of vtString: "a string"
  of vtHash: "'#" & t.text & "'"
  of vtFunc: "'" & t.text & "(…)'"
  of vtComma: "','"
  of vtSlash: "'/'"
  of vtDelim: "'" & t.text & "'"

proc resetMatch(toks: seq[VTok]) =
  gToks = toks
  gMemo = initTable[int, seq[int]]()
  gInprog = initHashSet[int]()
  gErrPos = 0
  gExpected = @[]

proc valueMatches*(prop, value: string): bool =
  let toks = lexValue(value)
  if toks.len == 0: return false
  if toks.len == 1 and toks[0].kind == vtIdent and isGlobalKeyword(toks[0].text):
    return true
  if not isProperty(prop): return false
  resetMatch(toks)
  let root = getGrammar("p:" & prop, propertySyntax(prop))
  for e in matchNode(root, 0):
    if e == toks.len: return true
  false

proc validateValue*(prop, value: string): tuple[valid: bool, error: string] =
  if not isProperty(prop):
    return (false, prop & " is not a known CSS property")
  if valueMatches(prop, value):
    return (true, "")
  # build a farthest-failure message from the last match attempt
  var got = "end of value"
  if gErrPos < gToks.len: got = describeTok(gToks[gErrPos])
  var exp = ""
  var i = 0
  while i < gExpected.len and i < 6:
    if i > 0: exp.add " | "
    exp.add gExpected[i]
    inc i
  if gExpected.len > 6: exp.add " | …"
  if exp.len == 0: exp = "a valid value"
  (false, "at token " & $(gErrPos + 1) & ": expected " & exp & ", got " & got)
