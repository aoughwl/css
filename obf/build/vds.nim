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
  o1* = enum
    o18                 ## juxtaposition: A B C  (all, in order)
    o17                  ## A | B          (exactly one)
    o16                 ## A || B         (one or more, any order)
    o15                 ## A && B         (all, any order)

  o4* = enum
    o74                 ## (no multiplier)
    o75                 ## ?  0 or 1
    o80                ## *  0 or more
    o78                ## +  1 or more
    o71                ## #  comma-separated, 1 or more
    o79               ## {m,n}
    o72           ## #{m,n}  comma-separated, m..n times

  o5* = enum
    o84             ## a literal identifier value: auto, flex, solid
    o86             ## a literal token that must appear: / or ,
    o88                ## <name>   — a data type OR named syntax (resolved later)
    o87                ## <'name'> — reference to another property's grammar
    o83                ## name( arg )
    o85                ## a combinator over children

  o8* = ref object
    mult*: o4
    lo*, hi*: int         ## for mkRange (hi < 0 means unbounded)
    case kind*: o5
    of o84, o86:
      text*: string
    of o88, o87:
      name*: string
    of o83:
      fname*: string
      arg*: o8
    of o85:
      comb*: o1
      kids*: seq[o8]

const HugeN* = 1000000    ## stand-in for ∞ in {m,} and unbounded ranges

# ---------------------------------------------------------------------------
# Grammar lexer
# ---------------------------------------------------------------------------

type
  o3 = enum
    o39, o49, o43, o33, o36, o31,
    o40, o45, o41, o46, o35, o47,
    o48, o42, o44, o38, o32, o34, o37
  o2 = object
    kind: o3
    text: string
    lo, hi: int

func o56(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
  (c >= '0' and c <= '9') or c == '-' or c == '_'

func o109(s: string): string =
  var i = 0
  var j = s.len
  while i < s.len and s[i] == ' ': inc i
  while j > i and s[j-1] == ' ': dec j
  result = ""
  while i < j:
    result.add s[i]
    inc i

func o100(s: string): int =
  ## Non-raising decimal parse (nimony's parseInt is `.raises`).
  result = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= '0' and c <= '9':
      result = result * 10 + (ord(c) - ord('0'))
    inc i

proc o64(src: string): seq[o2] =
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
        result.add o2(kind: o43, text: nm)
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
        result.add o2(kind: o49, text: o109(nm))
    elif c == '|':
      if i+1 < n and src[i+1] == '|':
        result.add o2(kind: o36); i += 2
      else:
        result.add o2(kind: o33); inc i
    elif c == '&':
      if i+1 < n and src[i+1] == '&':
        result.add o2(kind: o31); i += 2
      else:
        inc i                    # stray '&' — ignore
    elif c == '[':
      result.add o2(kind: o40); inc i
    elif c == ']':
      result.add o2(kind: o45); inc i
    elif c == '(':
      result.add o2(kind: o41); inc i
    elif c == ')':
      result.add o2(kind: o46); inc i
    elif c == ',':
      result.add o2(kind: o35); inc i
    elif c == '/':
      result.add o2(kind: o47); inc i
    elif c == '*':
      result.add o2(kind: o48); inc i
    elif c == '+':
      result.add o2(kind: o42); inc i
    elif c == '?':
      result.add o2(kind: o44); inc i
    elif c == '#':
      result.add o2(kind: o38); inc i
    elif c == '!':
      result.add o2(kind: o32); inc i
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
          if acc.len > 0: mm = o100(acc)
          acc = ""
          stage = 1
        elif ch >= '0' and ch <= '9':
          acc.add ch
        inc p
      if stage == 0:
        if acc.len > 0: mm = o100(acc)
        nn = mm
      else:
        if acc.len > 0: nn = o100(acc) else: nn = HugeN
      result.add o2(kind: o34, lo: mm, hi: nn)
    elif o56(c):
      var w = ""
      while i < n and o56(src[i]):
        w.add src[i]; inc i
      result.add o2(kind: o39, text: w)
    else:
      inc i                      # skip anything unrecognized
  result.add o2(kind: o37)

# ---------------------------------------------------------------------------
# Grammar parser (precedence climbing, single proc → self-recursive for groups)
# ---------------------------------------------------------------------------

type o7 = object
  toks: seq[o2]
  pos: int

func o104(p: o7): o2 = p.toks[p.pos]
proc o11(p: var o7): o2 =
  result = p.toks[p.pos]
  if p.pos < p.toks.len - 1: inc p.pos

func o21(k: o3): int =
  case k
  of o33: 1
  of o36: 2
  of o31: 3
  else: 0

func o108(k: o3): bool =
  case k
  of o39, o49, o43, o40, o47, o35: true
  else: false

func o20(k: o3): o1 =
  case k
  of o33: o17
  of o36: o16
  of o31: o15
  else: o18

proc o99(p: var o7, minPrec: int): o8

proc o101(p: var o7): o8 =
  let t = p.o104
  case t.kind
  of o39:
    discard p.o11
    # function?  ident immediately followed by (
    if p.o104.kind == o41:
      discard p.o11                 # (
      let a = o99(p, 0)
      if p.o104.kind == o46: discard p.o11
      result = o8(kind: o83, fname: t.text, arg: a, mult: o74)
    else:
      result = o8(kind: o84, text: t.text, mult: o74)
  of o49:
    discard p.o11
    result = o8(kind: o88, name: t.text, mult: o74)
  of o43:
    discard p.o11
    result = o8(kind: o87, name: t.text, mult: o74)
  of o47:
    discard p.o11
    result = o8(kind: o86, text: "/", mult: o74)
  of o35:
    discard p.o11
    result = o8(kind: o86, text: ",", mult: o74)
  of o40:
    discard p.o11
    result = o99(p, 0)
    if p.o104.kind == o45: discard p.o11
  else:
    discard p.o11
    result = o8(kind: o84, text: "?", mult: o74)

proc o103(p: var o7): o8 =
  result = o101(p)
  # postfix multiplier
  let t = p.o104
  case t.kind
  of o44: discard p.o11; result.mult = o75
  of o48: discard p.o11; result.mult = o80
  of o42: discard p.o11; result.mult = o78
  of o38:
    discard p.o11
    # a `#` may itself be followed by a count: `<number>#{3}` = exactly 3,
    # comma-separated. Fold the two into one comma-repeat-with-bounds multiplier.
    if p.o104.kind == o34:
      let b = p.o11
      result.mult = o72
      result.lo = b.lo
      result.hi = b.hi
    else:
      result.mult = o71
  of o32: discard p.o11                     # required-group flag; treat as one
  of o34:
    discard p.o11
    result.mult = o79
    result.lo = t.lo
    result.hi = t.hi
  else: discard

proc o73(comb: o1, a, b: o8): o8 =
  # flatten right-nesting of the same combinator into one n-ary node
  if a.kind == o85 and a.comb == comb and a.mult == o74:
    a.kids.add b
    a
  else:
    o8(kind: o85, comb: comb, kids: @[a, b], mult: o74)

proc o99(p: var o7, minPrec: int): o8 =
  result = o103(p)
  while true:
    let k = p.o104.kind
    let prec = o21(k)
    if prec > 0 and prec >= minPrec:
      discard p.o11
      let rhs = o99(p, prec + 1)
      result = o73(o20(k), result, rhs)
    elif o108(k) and 4 >= minPrec:
      # juxtaposition (implicit sequence), precedence 4 (tightest combinator)
      let rhs = o99(p, 5)
      result = o73(o18, result, rhs)
    else:
      break

proc o102*(src: string): o8 =
  ## Parse a value-definition-syntax string into a grammar tree.
  var p = o7(toks: o64(src), pos: 0)
  result = o99(p, 0)

# ---------------------------------------------------------------------------
# Render (round-trip / debugging)
# ---------------------------------------------------------------------------

func o81(m: o4, lo, hi: int): string =
  case m
  of o74: ""
  of o75: "?"
  of o80: "*"
  of o78: "+"
  of o71: "#"
  of o79:
    if hi >= HugeN: "{" & $lo & ",}"
    elif lo == hi: "{" & $lo & "}"
    else: "{" & $lo & "," & $hi & "}"
  of o72:
    if lo == hi: "#{" & $lo & "}"
    else: "#{" & $lo & "," & $hi & "}"

func o22(c: o1): string =
  case c
  of o18: " "
  of o17: " | "
  of o16: " || "
  of o15: " && "

proc o105*(n: o8): string =
  case n.kind
  of o84: result = n.text
  of o86: result = n.text
  of o88: result = "<" & n.name & ">"
  of o87: result = "<'" & n.name & "'>"
  of o83: result = n.fname & "( " & o105(n.arg) & " )"
  of o85:
    var parts: seq[string] = @[]
    var i = 0
    while i < n.kids.len:
      parts.add o105(n.kids[i])
      inc i
    let sep = o22(n.comb)
    result = ""
    var j = 0
    while j < parts.len:
      if j > 0: result.add sep
      result.add parts[j]
      inc j
    if n.comb != o18 or n.mult != o74:
      result = "[ " & result & " ]"
  result.add o81(n.mult, n.lo, n.hi)
