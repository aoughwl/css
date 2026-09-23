## dom.nim — the smallest element tree selectors and the cascade can run on.
##
## Just enough of a document for `css/match` and `css/computed`: a tag name,
## attributes (id / class / style are ordinary attributes, read through
## helpers), children, a parent link, and a set of dynamic states standing for
## what a browser would know at runtime (`hover`, `focus`, `checked`, …).
##
## Build a tree by hand, or with the selector-shaped builder:
##
##   let doc = elem("html",
##     elem("body.dark",
##       elem("ul#nav",
##         elem("li.item.active").withText("Home"),
##         elem("li.item[data-x=\"1\"]"))))
##
## The builder spec is parsed by the real selector parser (`css/selectors`), so
## escapes and quoted attribute values work exactly as they do in CSS.

import selectors

type
  Element* = ref object
    tag*: string                    ## lower-case for HTML
    ns*: string                     ## namespace URI ("" = HTML)
    attrs*: seq[tuple[name, value: string]]
    children*: seq[Element]
    parent*: nil Element             ## nil for a root
    text*: string                   ## text content (for :empty and friends)
    states*: seq[string]            ## dynamic pseudo-class states: "hover", …

proc lowerStr(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc newElement*(tag: string): Element =
  Element(tag: lowerStr(tag), ns: "", attrs: @[], children: @[], parent: nil,
          text: "", states: @[])

proc getAttr*(e: Element, name: string): string =
  ## The attribute's value, or "" (use `hasAttr` to tell absent from empty).
  result = ""
  var i = 0
  while i < e.attrs.len:
    if e.attrs[i].name == name: return e.attrs[i].value
    inc i

proc hasAttr*(e: Element, name: string): bool =
  var i = 0
  while i < e.attrs.len:
    if e.attrs[i].name == name: return true
    inc i
  false

proc setAttr*(e: Element, name, value: string) =
  var i = 0
  while i < e.attrs.len:
    if e.attrs[i].name == name:
      e.attrs[i] = (name: name, value: value)
      return
    inc i
  e.attrs.add (name: name, value: value)

proc id*(e: Element): string = e.getAttr("id")

proc classes*(e: Element): seq[string] =
  ## The whitespace-separated tokens of the class attribute.
  result = @[]
  let c = e.getAttr("class")
  var cur = ""
  var i = 0
  while i <= c.len:
    if i == c.len or c[i] == ' ' or c[i] == '\t' or c[i] == '\n':
      if cur.len > 0: result.add cur
      cur = ""
    else:
      cur.add c[i]
    inc i

proc hasClass*(e: Element, cls: string): bool =
  let cs = e.classes
  var i = 0
  while i < cs.len:
    if cs[i] == cls: return true
    inc i
  false

proc addClass*(e: Element, cls: string) =
  if not e.hasClass(cls):
    let c = e.getAttr("class")
    e.setAttr("class", (if c.len > 0: c & " " & cls else: cls))

proc hasState*(e: Element, state: string): bool =
  var i = 0
  while i < e.states.len:
    if e.states[i] == state: return true
    inc i
  false

proc setState*(e: Element, state: string, on = true) =
  ## Turn a dynamic state (`hover`, `focus`, `active`, `checked`, `visited`,
  ## `target`, …) on or off. The matcher reads states for every pseudo-class
  ## whose truth only the runtime knows.
  if on:
    if not e.hasState(state): e.states.add state
  else:
    var kept: seq[string] = @[]
    var i = 0
    while i < e.states.len:
      if e.states[i] != state: kept.add e.states[i]
      inc i
    e.states = kept

proc appendChild*(parent, child: Element) =
  child.parent = parent
  parent.children.add child

proc index*(e: Element): int =
  ## Position among the parent's element children (0-based), -1 for a root.
  let p = e.parent
  if p == nil: return -1
  var i = 0
  while i < p.children.len:
    if p.children[i] == e: return i
    inc i
  -1

proc siblings*(e: Element): seq[Element] =
  ## The parent's element children (including `e`), or `@[e]` for a root.
  let p = e.parent
  if p == nil: @[e] else: p.children

proc root*(e: Element): Element =
  result = e
  while true:
    let p = result.parent
    if p == nil: break
    result = p

proc elem*(spec: string, kids: varargs[Element]): Element =
  ## Build an element from a compound-selector-shaped spec —
  ## `tag#id.class1.class2[attr="v"][flag]` — with children. States can be
  ## given as pseudo-classes: `a:hover` sets the `hover` state.
  var tag = "div"
  var e = newElement(tag)
  let r = parseSelector(spec, false)
  if r.ok and r.list.len == 1 and r.list[0].compounds.len == 1:
    let simples = r.list[0].compounds[0].simples
    var i = 0
    while i < simples.len:
      let sp = simples[i]
      case sp.kind
      of skType: e.tag = lowerStr(sp.name)
      of skId: e.setAttr("id", sp.name)
      of skClass: e.addClass(sp.name)
      of skAttr: e.setAttr(sp.name, (if sp.op == aoExists: "" else: sp.value))
      of skPseudoClass: e.setState(sp.name)
      else: discard
      inc i
  else:
    e.tag = lowerStr(spec)
  var k = 0
  while k < kids.len:
    e.appendChild(kids[k])
    inc k
  e

proc withText*(e: Element, text: string): Element =
  e.text = text
  e

proc walkAll(e: Element, dest: var seq[Element]) =
  var i = 0
  while i < e.children.len:
    dest.add e.children[i]
    walkAll(e.children[i], dest)
    inc i

proc descendants*(e: Element): seq[Element] =
  ## Every descendant in document (pre-)order.
  result = @[]
  walkAll(e, result)

proc `$`*(e: Element): string =
  ## A short selector-like description: `li#x.a.b`.
  result = e.tag
  let i = e.id
  if i.len > 0: result.add "#" & i
  let cs = e.classes
  var k = 0
  while k < cs.len:
    result.add "." & cs[k]
    inc k
