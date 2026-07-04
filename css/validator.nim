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
import data
import math

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

func lowerStr(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    var c = s[i]
    if c >= 'A' and c <= 'Z': c = char(ord(c) + 32)
    result.add c
    inc i

proc compileVNode(v: VNode): int
proc getGrammar(key, src: string): int

proc compileVNode(v: VNode): int =
  case v.kind
  of nkKeyword:
    # store the keyword pre-lowered so matching never re-lowercases it
    result = allocNode CNode(op: opKw, text: lowerStr(v.text), mult: v.mult, lo: v.lo, hi: v.hi)
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
var gLower: seq[string] = @[]   ## gToks[i].text pre-lowered once per value (for opKw)
var gMemo = initTable[int, seq[int]]()
var gInprog = initHashSet[int]()
var gErrPos = 0
var gExpected: seq[string] = @[]
var gTrack = true               ## record farthest-failure info? (off on success path)

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
  # Farthest-failure bookkeeping is only needed to phrase an error message, so it
  # is skipped entirely on the success path (gTrack=false) — a big saving, since a
  # single `<color>` match tries dozens of failing keyword alternatives.
  if not gTrack: return
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
    # n.text is pre-lowered at compile; gLower[pos] is the token pre-lowered once
    # per value — so a big keyword OR never re-lowercases the same token.
    if pos < gToks.len and gToks[pos].kind == vtIdent and gLower[pos] == n.text:
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
  of mkHashRange:
    result = repeat(id, pos, arena[id].lo, arena[id].hi, true)
  gInprog.excl key
  gMemo[key] = result

# `repeat`, `matchOne`, `matchOrderless` reference each other and `matchNode`;
# nimony resolves the forward use of `matchOne`/`matchNode` above.

# ---------------------------------------------------------------------------
# strict function-notation validation
# ---------------------------------------------------------------------------
# The value lexer collapses `rgb(255, 0, 0)` into ONE opaque function token (with
# the arguments captured as `.args`), so the top-level property grammar only ever
# checks "a function appears here" and never looks inside. This pass fills that
# gap: for every function anywhere in a value it looks up the function's own MDN
# grammar and matches its arguments against it — catching wrong arity, wrong
# argument types, and entirely unknown function names. Math functions keep their
# dedicated recursive checker in math.aowl (which has finer-grained messages).

func isFnIdentStart(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-'
func isFnIdentCh(c: char): bool =
  isFnIdentStart(c) or (c >= '0' and c <= '9')

proc addFuncNames(s: string, dest: var HashSet[string]) =
  ## Collect every `name(` occurring in a grammar string — this catches both the
  ## top-level `rgb()` syntaxes AND functions defined only inline inside another
  ## grammar (`cubic-bezier(…)`, `steps(…)`, `rect(…)`, `symbols(…)`, `type(…)`).
  var i = 0
  while i < s.len:
    if isFnIdentStart(s[i]):
      var j = i
      var w = ""
      while j < s.len and isFnIdentCh(s[j]):
        w.add s[j]
        inc j
      if j < s.len and s[j] == '(':
        dest.incl lower(w)
      i = j
      if i == 0: inc i           # never stall
    else:
      inc i

proc buildFuncVocab(): HashSet[string] =
  ## The full vocabulary of function names the MDN data knows about, built once
  ## from the raw blobs (avoids relying on Table iteration order/support).
  result = initHashSet[string]()
  addFuncNames(cssSyntaxBlob, result)
  addFuncNames(cssPropertyBlob, result)

let funcVocab = buildFuncVocab()

# MDN writes legacy comma-separated function forms with the comma *outside* the
# optional part it belongs to — `rgb( <number>#{3} , <alpha-value>? )` and
# `linear-gradient( [ <angle> … ]? , <color-stop-list> )`. Taken literally that
# demands a comma even when the optional argument is absent, so `rgb(255,0,0)` and
# `linear-gradient(red, blue)` would be rejected. Real CSS drops the comma with
# the optional part. We fix this structurally: a comma sitting next to an optional
# operand is folded *into* an optional group, so the comma appears only when its
# neighbour does. This is spec-faithful and fixes every function with the wart.

func isCommaLit(n: VNode): bool =
  n.kind == nkLiteral and n.text == "," and n.mult == mkOne
func isOptOperand(n: VNode): bool = n.mult == mkOpt

proc mkOptSeq(a, b: VNode): VNode =
  VNode(kind: nkList, comb: cbSeq, kids: @[a, b], mult: mkOpt)

proc mkOptGroup(kids: seq[VNode]): VNode =
  VNode(kind: nkList, comb: cbSeq, kids: kids, mult: mkOpt)

proc foldSeqCommas(kids: seq[VNode]): seq[VNode] =
  result = @[]
  var i = 0
  while i < kids.len:
    let k = kids[i]
    if isCommaLit(k) and i + 1 < kids.len and isOptOperand(kids[i+1]):
      # `, X?`  →  `[ , X ]?`  (comma appears only with its trailing arg)
      let x = kids[i+1]
      x.mult = mkOne
      result.add mkOptSeq(k, x)
      i += 2
    elif isOptOperand(k):
      # a run of optional operands `A? B? …` immediately before a comma binds the
      # comma to the whole run:  `A? B? ,`  →  `[ A? B? , ]?`  (the operands stay
      # optional inside, so any subset — or none — of the prefix is accepted).
      var j = i
      while j < kids.len and isOptOperand(kids[j]): inc j
      if j < kids.len and isCommaLit(kids[j]):
        var grp: seq[VNode] = @[]
        var m = i
        while m <= j:
          grp.add kids[m]
          inc m
        result.add mkOptGroup(grp)
        i = j + 1
      else:
        result.add k
        i += 1
    else:
      result.add k
      i += 1

proc normalizeCommas(v: VNode): VNode =
  case v.kind
  of nkFunc:
    v.arg = normalizeCommas(v.arg)
  of nkList:
    var i = 0
    while i < v.kids.len:
      v.kids[i] = normalizeCommas(v.kids[i])
      inc i
    if v.comb == cbSeq:
      v.kids = foldSeqCommas(v.kids)
  else: discard
  v

var funcRootsCache = initTable[string, seq[int]]()

func isSubstitutionFunc(name: string): bool =
  ## var()/env() substitute an arbitrary token stream at used-value time, so a
  ## value containing one can't be fully validated statically — accept the call
  ## itself (checked for non-emptiness below) and don't over-constrain it.
  let l = lower(name)
  l == "var" or l == "env"

func isOpaqueFunc(name: string): bool =
  ## url() carries an opaque URL/string payload, not a value-grammar expression.
  lower(name) == "url"

proc hasTopLevelSubst(s: string): bool =
  ## Does `s` contain a top-level var()/env()? (Nested functions are already
  ## single opaque tokens, so any var/env we see here is at this scope.) When it
  ## does, the surrounding scope can expand to any token stream and is accepted.
  let toks = lexValue(s)
  var i = 0
  while i < toks.len:
    if toks[i].kind == vtFunc and isSubstitutionFunc(toks[i].text): return true
    inc i
  false

func hasPrefix(s, p: string): bool =
  if s.len < p.len: return false
  var i = 0
  while i < p.len:
    var c = s[i]
    if c >= 'A' and c <= 'Z': c = char(ord(c) + 32)
    if c != p[i]: return false
    inc i
  true

func isVendorProperty(prop: string): bool =
  ## Browser-prefixed properties (`-webkit-…`, `-moz-…`, …) are valid CSS we
  ## can't grammar-check (no MDN entry), so accept rather than falsely reject.
  hasPrefix(prop, "-webkit-") or hasPrefix(prop, "-moz-") or
  hasPrefix(prop, "-ms-") or hasPrefix(prop, "-o-") or hasPrefix(prop, "-khtml-")

proc funcArgRoots(name: string): seq[int] =
  ## Compiled inner-argument grammars for every `name( … )` alternative in the
  ## MDN data — a function like rgb() has four space/comma forms. Cached per name.
  let key = lower(name)
  if funcRootsCache.hasKey(key): return funcRootsCache.getOrDefault(key, @[])
  var res: seq[int] = @[]
  let synKey = name & "()"
  if isSyntax(synKey):
    let root = normalizeCommas(parseSyntax(syntaxOf(synKey)))
    var alts: seq[VNode] = @[]
    if root.kind == nkFunc:
      alts.add root
    elif root.kind == nkList and root.comb == cbOr:
      var i = 0
      while i < root.kids.len:
        if root.kids[i].kind == nkFunc: alts.add root.kids[i]
        inc i
    var i = 0
    while i < alts.len:
      if lower(alts[i].fname) == lower(name):
        res.add compileVNode(alts[i].arg)
      inc i
  funcRootsCache[key] = res
  res

proc argsMatch(name, args: string): bool =
  ## Does `args` fully satisfy some alternative grammar for `name( … )`?
  let roots = funcArgRoots(name)
  if roots.len == 0: return false
  let toks = lexValue(args)
  resetMatch(toks)
  var i = 0
  while i < roots.len:
    for e in matchNode(roots[i], 0):
      if e == toks.len: return true
    inc i
  false

proc checkFunctionsIn(value: string): tuple[valid: bool, error: string] =
  ## Validate every function token appearing anywhere in `value`, recursing into
  ## nested calls. Runs to completion before the whole-value match, and each
  ## `argsMatch` fully finishes before the next, so the shared matcher state is
  ## never re-entered mid-match.
  let toks = lexValue(value)
  var i = 0
  while i < toks.len:
    let t = toks[i]
    if t.kind == vtFunc:
      if isMathFunc(t.text):
        discard                      # handled by validateFunctionsIn, better msgs
      elif isSubstitutionFunc(t.text):
        if t.args.len == 0:
          return (false, t.text & "() requires an argument")
      elif isOpaqueFunc(t.text):
        discard                        # url(): opaque URL/string payload
      elif hasTopLevelSubst(t.args):
        discard                        # e.g. rgba(var(--rgb), .5): var() may
                                       # expand to any number of values — can't
                                       # meaningfully arg-check this call
      elif isSyntax(t.text & "()"):
        if not argsMatch(t.text, t.args):
          return (false, "invalid arguments to " & t.text & "(): '" &
            t.args & "' — expected " & syntaxOf(t.text & "()"))
        let inner = checkFunctionsIn(t.args)
        if not inner.valid: return inner
      elif funcVocab.contains(lower(t.text)):
        # a function the data knows only inline (cubic-bezier/steps/rect/…): we
        # have no clean top-level grammar to arg-check, so accept the call but
        # still descend to reject any unknown/invalid nested function.
        let inner = checkFunctionsIn(t.args)
        if not inner.valid: return inner
      else:
        return (false, "unknown function '" & t.text & "()'")
    inc i
  (true, "")

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

# ---------------------------------------------------------------------------
# validation levels — trade coverage for speed, 1:1 with what other tools do
# ---------------------------------------------------------------------------

type Level* = enum
  lvValues    ## whole-value grammar match only (fast — the tier peers stop at)
  lvFull      ## + recursive math checking + strict function-argument grammars

var gLevel = lvFull
proc setLevel*(l: Level) = gLevel = l
proc level*(): Level = gLevel

proc resetMatch(toks: seq[VTok]) =
  gToks = toks
  gLower = @[]
  var i = 0
  while i < toks.len:
    if toks[i].kind == vtIdent: gLower.add lowerStr(toks[i].text)
    else: gLower.add ""      # only idents are ever compared as keywords
    inc i
  gMemo.clear()          # reuse the table's capacity instead of re-allocating it
  # gInprog is self-clearing: every `incl` in matchNode is paired with an `excl`,
  # so it is already empty here — no realloc needed.
  gErrPos = 0
  gExpected = @[]

proc valueMatchesToks(prop: string, toks: seq[VTok]): bool =
  resetMatch(toks)
  let root = getGrammar("p:" & prop, propertySyntax(prop))
  for e in matchNode(root, 0):
    if e == toks.len: return true
  false

proc valueMatches*(prop, value: string): bool =
  let toks = lexValue(value)
  if toks.len == 0: return false
  if toks.len == 1 and toks[0].kind == vtIdent and isGlobalKeyword(toks[0].text):
    return true
  if not isProperty(prop): return false
  gTrack = false
  valueMatchesToks(prop, toks)

proc validateValue*(prop, value: string): tuple[valid: bool, error: string] =
  var prop = prop
  if not isProperty(prop):
    if isVendorProperty(prop):
      return (true, "")              # browser-prefixed property: accept, uncheckable
    elif lower(prop) == "color-adjust" and isProperty("print-color-adjust"):
      prop = "print-color-adjust"    # deprecated alias for print-color-adjust
    else:
      return (false, prop & " is not a known CSS property")
  # Lex the value ONCE and share the tokens across every check below (the value
  # lexer collapses nested functions to single opaque tokens, so a var()/env() or
  # function seen here is at the value's top level).
  let toks = lexValue(value)
  if toks.len == 0:
    return (false, "empty value")
  if toks.len == 1 and toks[0].kind == vtIdent and isGlobalKeyword(toks[0].text):
    return (true, "")                # inherit / initial / unset / revert
  # A lone browser-prefixed keyword value (-webkit-sticky, -moz-max-content, …).
  if toks.len == 1 and toks[0].kind == vtIdent and isVendorProperty(toks[0].text):
    return (true, "")
  var hasFn = false
  var i = 0
  while i < toks.len:
    if toks[i].kind == vtFunc:
      hasFn = true
      # a top-level var()/env() makes the used value unknowable → accept.
      if isSubstitutionFunc(toks[i].text): return (true, "")
    inc i
  # Function-argument validation runs only when the value actually contains a
  # function AND the caller wants the full level — precise math/arity errors.
  if hasFn and gLevel == lvFull:
    let fr = validateFunctionsIn(value)     # recursive math (calc/min/max/clamp…)
    if not fr.valid:
      return (false, fr.error)
    let cf = checkFunctionsIn(value)        # rgb/hsl/gradients/… own grammars
    if not cf.valid:
      return (false, cf.error)
  # …then the whole-value grammar match (reusing the tokens we already lexed).
  # First pass with error-tracking OFF (fast); only if it fails do we re-run with
  # tracking ON to phrase a precise farthest-failure message.
  gTrack = false
  if valueMatchesToks(prop, toks):
    return (true, "")
  gTrack = true
  discard valueMatchesToks(prop, toks)
  # build a farthest-failure message from the last match attempt
  var got = "end of value"
  if gErrPos < gToks.len: got = describeTok(gToks[gErrPos])
  var exp = ""
  i = 0
  while i < gExpected.len and i < 6:
    if i > 0: exp.add " | "
    exp.add gExpected[i]
    inc i
  if gExpected.len > 6: exp.add " | …"
  if exp.len == 0: exp = "a valid value"
  (false, "at token " & $(gErrPos + 1) & ": expected " & exp & ", got " & got)
