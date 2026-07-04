## style_plugin — lowers  `style "name":  prop: value …`  into `styleOne(…)`
## calls. Public build: it imports the published `plugin` package (the aoughwl
## plugin-authoring runtime, github.com/aoughwl/plugin) rather than the in-tree
## `aoughwl/plugin`, so the DSL compiles with plain nim / nimony.
##
## Input shape: (stmts style "name" (stmts (call <prop> (stmts <value>)) ...))

import plugin

proc kebab(s: string): string =
  ## camelCase property ident → kebab-case CSS name.
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z':
      result.add '-'
      result.add char(ord(c) + 32)
    else:
      result.add c
    inc i

proc unitStr(name: string): string =
  if name == "percent" or name == "pct": "%" else: name

proc renderVal(n: Node): string =
  ## Render a value node into a CSS value string.
  case n.kind
  of nkIdent, nkStr, nkSym: result = n.sval
  of nkInt: result = $n.ival
  of nkFloat: result = $n.fval
  of nkEmpty: result = ""
  of nkTree:
    if n.tag == "dot":                     # 10.px
      result = renderVal(n[0]) & unitStr(n[1].sval)
    elif n.tag == "cmd":                   # 10.px 20.px  (space-separated)
      result = ""
      var i = 0
      while i < n.len:
        if i > 0: result.add " "
        result.add renderVal(n[i])
        inc i
    elif n.tag == "call":                  # rgb(1, 2, 3)
      result = renderVal(n[0]) & "("
      var i = 1
      while i < n.len:
        if i > 1: result.add ","
        result.add renderVal(n[i])
        inc i
      result.add ")"
    else:
      result = ""

proc transform(input: Node): Node =
  # input = (stmts style "name" (stmts <decls>))
  let name = input[1].sval
  let body = input[2]
  # Search the block for every `prop: value` declaration (a `call` node) and
  # rewrite it into a `styleOne(name, prop, value)` call.
  body.rewrite(
    proc (x: Node): bool {.closure.} = x.isTree("call"),
    proc (decl: Node): Node {.closure.} =
      call("styleOne", @[str(name),
                         str(kebab(decl[0].sval)),
                         str(renderVal(decl[1][0]))]))

runPlugin transform
