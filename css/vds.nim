## vds.nim — MDN value-definition-syntax: lexer + parser + AST.
##
## Parses grammar strings like
##     <'margin-top'>{1,4}
##     [ <display-outside> || <display-inside> ] | <display-listitem>
##     <length-percentage>{1,4} [ / <length-percentage>{1,4} ]?
##     abs( <calc-sum> )
## into a `VNode` tree the matcher (vds_match.nim) walks.
##
## Combinator precedence, loosest→tightest:  `|`  <  `||`  <  `&&`  <  juxtaposition.
## Multipliers (postfix): `?` `*` `+` `#` `{m,n}` `!`.
##
## nimony notes: no raising string slices (we char-walk), object variants + ref +
## recursion are all fine.

# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------

type
  Comb* = enum
    cbSeq                 ## juxtaposition: A B C  (all, in order)
    cbOr                  ## A | B          (exactly one)
    cbAny                 ## A || B         (one or more, any order)
    cbAll                 ## A && B         (all, any order)

  Mult* = enum
    mkOne                 ## (no multiplier)
    mkOpt                 ## ?  0 or 1
    mkStar                ## *  0 or more
    mkPlus                ## +  1 or more
    mkHash                ## #  comma-separated, 1 or more
    mkRange               ## {m,n}

  NodeKind* = enum
    nkKeyword             ## a literal identifier value: auto, flex, solid
    nkLiteral             ## a literal token that must appear: / or ,
    nkType                ## <name>   — a data type OR named syntax (resolved later)
    nkProp                ## <'name'> — reference to another property's grammar
    nkFunc                ## name( arg )
    nkList                ## a combinator over children

  VNode* = ref object
    mult*: Mult
    lo*, hi*: int         ## for mkRange (hi < 0 means unbounded)
    case kind*: NodeKind
    of nkKeyword, nkLiteral:
      text*: string
    of nkType, nkProp:
      name*: string
    of nkFunc:
      fname*: string
      arg*: VNode
    of nkList:
      comb*: Comb
      kids*: seq[VNode]

const HugeN* = 1000000    ## stand-in for ∞ in {m,} and unbounded ranges

# ---------------------------------------------------------------------------
# Grammar lexer
# ---------------------------------------------------------------------------

type
  GTokKind = enum
    gtIdent, gtType, gtProp, gtBar, gtDbar, gtAmp,
    gtLBrack, gtRBrack, gtLParen, gtRParen, gtComma, gtSlash,
    gtStar, gtPlus, gtQues, gtHash, gtBang, gtBrace, gtEof
  GTok = object
    kind: GTokKind
    text: string
    lo, hi: int

func isIdentCh(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
  (c >= '0' and c <= '9') or c == '-' or c == '_'

func stripSpaces(s: string): string =
  var i = 0
  var j = s.len
  while i < s.len and s[i] == ' ': inc i
  while j > i and s[j-1] == ' ': dec j
  result = ""
  while i < j:
    result.add s[i]
    inc i

func parseIntSafe(s: string): int =
  ## Non-raising decimal parse (nimony's parseInt is `.raises`).
  result = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= '0' and c <= '9':
      result = result * 10 + (ord(c) - ord('0'))
    inc i

proc lexGrammar(src: string): seq[GTok] =
  result = @[]
  var i = 0
  let n = src.len
  while i < n:
    let c = src[i]
    if c == ' ' or c == '\t' or c == '\n':
      inc i
    elif c == '<':
      inc i
      if i < n and src[i] == '\'':
        # <'property'>
        inc i
        var nm = ""
        while i < n and src[i] != '\'':
          nm.add src[i]; inc i
        if i < n: inc i          # closing '
        while i < n and src[i] != '>': inc i
        if i < n: inc i          # closing >
        result.add GTok(kind: gtProp, text: nm)
      else:
        # <name> possibly with a numeric range: <length [0,∞]>
        var inner = ""
        while i < n and src[i] != '>':
          inner.add src[i]; inc i
        if i < n: inc i          # closing >
        # split off " [range]" if present
        var nm = inner
        var b = 0
        while b < inner.len and inner[b] != '[': inc b
        if b < inner.len:
          nm = ""
          var k = 0
          while k < b: nm.add inner[k]; inc k
        result.add GTok(kind: gtType, text: stripSpaces(nm))
    elif c == '|':
      if i+1 < n and src[i+1] == '|':
        result.add GTok(kind: gtDbar); i += 2
      else:
        result.add GTok(kind: gtBar); inc i
    elif c == '&':
      if i+1 < n and src[i+1] == '&':
        result.add GTok(kind: gtAmp); i += 2
      else:
        inc i                    # stray '&' — ignore
    elif c == '[':
      result.add GTok(kind: gtLBrack); inc i
    elif c == ']':
      result.add GTok(kind: gtRBrack); inc i
    elif c == '(':
      result.add GTok(kind: gtLParen); inc i
    elif c == ')':
      result.add GTok(kind: gtRParen); inc i
    elif c == ',':
      result.add GTok(kind: gtComma); inc i
    elif c == '/':
      result.add GTok(kind: gtSlash); inc i
    elif c == '*':
      result.add GTok(kind: gtStar); inc i
    elif c == '+':
      result.add GTok(kind: gtPlus); inc i
    elif c == '?':
      result.add GTok(kind: gtQues); inc i
    elif c == '#':
      result.add GTok(kind: gtHash); inc i
    elif c == '!':
      result.add GTok(kind: gtBang); inc i
    elif c == '{':
      inc i
      var body = ""
      while i < n and src[i] != '}':
        body.add src[i]; inc i
      if i < n: inc i            # closing }
      # parse "{m,n}" / "{m,}" / "{m}"
      var mm = 0
      var nn = 0
      var acc = ""
      var stage = 0              # 0 = before comma, 1 = after
      var p = 0
      while p < body.len:
        let ch = body[p]
        if ch == ',':
          if acc.len > 0: mm = parseIntSafe(acc)
          acc = ""
          stage = 1
        elif ch >= '0' and ch <= '9':
          acc.add ch
        inc p
      if stage == 0:
        if acc.len > 0: mm = parseIntSafe(acc)
        nn = mm
      else:
        if acc.len > 0: nn = parseIntSafe(acc) else: nn = HugeN
      result.add GTok(kind: gtBrace, lo: mm, hi: nn)
    elif isIdentCh(c):
      var w = ""
      while i < n and isIdentCh(src[i]):
        w.add src[i]; inc i
      result.add GTok(kind: gtIdent, text: w)
    else:
      inc i                      # skip anything unrecognized
  result.add GTok(kind: gtEof)

# ---------------------------------------------------------------------------
# Grammar parser (precedence climbing, single proc → self-recursive for groups)
# ---------------------------------------------------------------------------

type Parser = object
  toks: seq[GTok]
  pos: int

func peek(p: Parser): GTok = p.toks[p.pos]
proc advance(p: var Parser): GTok =
  result = p.toks[p.pos]
  if p.pos < p.toks.len - 1: inc p.pos

func combPrec(k: GTokKind): int =
  case k
  of gtBar: 1
  of gtDbar: 2
  of gtAmp: 3
  else: 0

func startsPrimary(k: GTokKind): bool =
  case k
  of gtIdent, gtType, gtProp, gtLBrack, gtSlash, gtComma: true
  else: false

func combOf(k: GTokKind): Comb =
  case k
  of gtBar: cbOr
  of gtDbar: cbAny
  of gtAmp: cbAll
  else: cbSeq

proc parseExpr(p: var Parser, minPrec: int): VNode

proc parsePrimary(p: var Parser): VNode =
  let t = p.peek
  case t.kind
  of gtIdent:
    discard p.advance
    # function?  ident immediately followed by (
    if p.peek.kind == gtLParen:
      discard p.advance                 # (
      let a = parseExpr(p, 0)
      if p.peek.kind == gtRParen: discard p.advance
      result = VNode(kind: nkFunc, fname: t.text, arg: a, mult: mkOne)
    else:
      result = VNode(kind: nkKeyword, text: t.text, mult: mkOne)
  of gtType:
    discard p.advance
    result = VNode(kind: nkType, name: t.text, mult: mkOne)
  of gtProp:
    discard p.advance
    result = VNode(kind: nkProp, name: t.text, mult: mkOne)
  of gtSlash:
    discard p.advance
    result = VNode(kind: nkLiteral, text: "/", mult: mkOne)
  of gtComma:
    discard p.advance
    result = VNode(kind: nkLiteral, text: ",", mult: mkOne)
  of gtLBrack:
    discard p.advance
    result = parseExpr(p, 0)
    if p.peek.kind == gtRBrack: discard p.advance
  else:
    discard p.advance
    result = VNode(kind: nkKeyword, text: "?", mult: mkOne)

proc parseTerm(p: var Parser): VNode =
  result = parsePrimary(p)
  # postfix multiplier
  let t = p.peek
  case t.kind
  of gtQues: discard p.advance; result.mult = mkOpt
  of gtStar: discard p.advance; result.mult = mkStar
  of gtPlus: discard p.advance; result.mult = mkPlus
  of gtHash: discard p.advance; result.mult = mkHash
  of gtBang: discard p.advance                     # required-group flag; treat as one
  of gtBrace:
    discard p.advance
    result.mult = mkRange
    result.lo = t.lo
    result.hi = t.hi
  else: discard

proc mkList(comb: Comb, a, b: VNode): VNode =
  # flatten right-nesting of the same combinator into one n-ary node
  if a.kind == nkList and a.comb == comb and a.mult == mkOne:
    a.kids.add b
    a
  else:
    VNode(kind: nkList, comb: comb, kids: @[a, b], mult: mkOne)

proc parseExpr(p: var Parser, minPrec: int): VNode =
  result = parseTerm(p)
  while true:
    let k = p.peek.kind
    let prec = combPrec(k)
    if prec > 0 and prec >= minPrec:
      discard p.advance
      let rhs = parseExpr(p, prec + 1)
      result = mkList(combOf(k), result, rhs)
    elif startsPrimary(k) and 4 >= minPrec:
      # juxtaposition (implicit sequence), precedence 4 (tightest combinator)
      let rhs = parseExpr(p, 5)
      result = mkList(cbSeq, result, rhs)
    else:
      break

proc parseSyntax*(src: string): VNode =
  ## Parse a value-definition-syntax string into a grammar tree.
  var p = Parser(toks: lexGrammar(src), pos: 0)
  result = parseExpr(p, 0)

# ---------------------------------------------------------------------------
# Render (round-trip / debugging)
# ---------------------------------------------------------------------------

func multStr(m: Mult, lo, hi: int): string =
  case m
  of mkOne: ""
  of mkOpt: "?"
  of mkStar: "*"
  of mkPlus: "+"
  of mkHash: "#"
  of mkRange:
    if hi >= HugeN: "{" & $lo & ",}"
    elif lo == hi: "{" & $lo & "}"
    else: "{" & $lo & "," & $hi & "}"

func combStr(c: Comb): string =
  case c
  of cbSeq: " "
  of cbOr: " | "
  of cbAny: " || "
  of cbAll: " && "

proc render*(n: VNode): string =
  case n.kind
  of nkKeyword: result = n.text
  of nkLiteral: result = n.text
  of nkType: result = "<" & n.name & ">"
  of nkProp: result = "<'" & n.name & "'>"
  of nkFunc: result = n.fname & "( " & render(n.arg) & " )"
  of nkList:
    var parts: seq[string] = @[]
    var i = 0
    while i < n.kids.len:
      parts.add render(n.kids[i])
      inc i
    let sep = combStr(n.comb)
    result = ""
    var j = 0
    while j < parts.len:
      if j > 0: result.add sep
      result.add parts[j]
      inc j
    if n.comb != cbSeq or n.mult != mkOne:
      result = "[ " & result & " ]"
  result.add multStr(n.mult, n.lo, n.hi)
