## match.nim — does a selector match an element?
##
## Runs the parsed selector AST (`css/selectors`) against the element tree of
## `css/dom`, right to left, the way engines do: the rightmost compound must
## match the element itself, then each combinator walks to the candidates for
## the compound on its left.
##
##   matches(el, "ul > li:nth-child(2n+1 of .item):not(.hidden)")
##   querySelectorAll(doc, "a[href^=\"https\"]:hover")
##   closest(el, "section:has(> h2)")
##
## Supported: every combinator but the column one (`||` needs a table model);
## type (case-insensitive), universal, class, id, attribute (all seven
## operators, `i`/`s` flags); the logical pseudo-classes (`:not`, `:is`,
## `:where`, `:has` with relative selectors); all tree-structural ones
## (`:root`, `:empty`, `:first/last/only-child`, `:first/last/only-of-type`,
## `:nth-child(An+B of S)` and friends); `:lang()` and `:dir()` from the
## attributes on the ancestor chain; form state from attributes (`:checked`,
## `:disabled`, `:enabled`, `:required`, `:optional`, `:read-only`,
## `:read-write`, `:placeholder-shown`, `:link`, `:any-link`); `:scope`;
## `:focus-within`; and every other pseudo-class as a dynamic state set with
## `setState(el, "hover")`. A selector ending in a pseudo-element never matches
## an element (it matches a part of one).
##
## The nesting selector `&` matches what the enclosing rule's selector matches;
## pass that selector list as `parent`.

import selectors
import dom

proc lowerS(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc startsWith(s, p: string): bool =
  if s.len < p.len: return false
  var i = 0
  while i < p.len:
    if s[i] != p[i]: return false
    inc i
  true

proc endsWith(s, p: string): bool =
  if s.len < p.len: return false
  var i = 0
  let off = s.len - p.len
  while i < p.len:
    if s[off + i] != p[i]: return false
    inc i
  true

proc contains(s, p: string): bool =
  if p.len == 0: return true
  var i = 0
  while i + p.len <= s.len:
    var j = 0
    while j < p.len and s[i+j] == p[j]: inc j
    if j == p.len: return true
    inc i
  false

proc strip2(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t'): inc a
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t'): dec b
  result = ""
  var i = a
  while i < b:
    result.add s[i]
    inc i

type MatchCtx = object
  parent: SelectorList     ## what `&` stands for (empty = :scope)
  scope: nil Element       ## the :scope element (nil = the root)

proc matchComplexAt(e: Element, c: Complex, ctx: MatchCtx): bool
proc matchListAt(e: Element, list: SelectorList, ctx: MatchCtx): bool

# --- attribute ----------------------------------------------------------------

proc attrMatches(e: Element, sp: Simple): bool =
  let name = lowerS(sp.name)
  var found = false
  var val = ""
  var i = 0
  while i < e.attrs.len:
    if lowerS(e.attrs[i].name) == name:
      found = true
      val = e.attrs[i].value
    inc i
  if not found: return false
  if sp.op == aoExists: return true
  var v = val
  var want = sp.value
  if sp.caseFlag == 'i':
    v = lowerS(v)
    want = lowerS(want)
  case sp.op
  of aoExists: true
  of aoEquals: v == want
  of aoIncludes:
    if want.len == 0: return false
    var cur = ""
    var k = 0
    while k <= v.len:
      if k == v.len or v[k] == ' ' or v[k] == '\t' or v[k] == '\n':
        if cur == want: return true
        cur = ""
      else:
        cur.add v[k]
      inc k
    false
  of aoDashMatch: v == want or startsWith(v, want & "-")
  of aoPrefix: want.len > 0 and startsWith(v, want)
  of aoSuffix: want.len > 0 and endsWith(v, want)
  of aoSubstring: want.len > 0 and contains(v, want)

# --- structural ----------------------------------------------------------------

proc anbMatches(a, b, pos: int): bool =
  ## Is the 1-based `pos` = a*n + b for some n >= 0?
  if a == 0: return pos == b
  let d = pos - b
  if d mod a != 0: return false
  d div a >= 0

proc siblingPos(e: Element, fromEnd, ofType: bool, sel: SelectorList,
                ctx: MatchCtx): int =
  ## 1-based position among siblings (counting only same-type ones, or only
  ## those matching `sel` when given), from the start or the end.
  if e.parent == nil: return 1
  let sibs = e.siblings
  var n = 0
  var i = (if fromEnd: sibs.len - 1 else: 0)
  while i >= 0 and i < sibs.len:
    let s = sibs[i]
    var counts = true
    if ofType: counts = s.tag == e.tag
    elif sel.len > 0: counts = matchListAt(s, sel, ctx)
    if counts: inc n
    if s == e: return n
    i = (if fromEnd: i - 1 else: i + 1)
  n

proc isFormControl(e: Element): bool =
  e.tag == "input" or e.tag == "button" or e.tag == "select" or
    e.tag == "textarea" or e.tag == "option" or e.tag == "optgroup" or
    e.tag == "fieldset"

proc langOf(e: Element): string =
  var x: nil Element = e
  while x != nil:
    if x.hasAttr("lang"): return lowerS(x.getAttr("lang"))
    if x.hasAttr("xml:lang"): return lowerS(x.getAttr("xml:lang"))
    x = x.parent
  ""

proc dirOf(e: Element): string =
  var x: nil Element = e
  while x != nil:
    let d = lowerS(x.getAttr("dir"))
    if d == "ltr" or d == "rtl": return d
    x = x.parent
  "ltr"

proc langMatches(lang, arg: string): bool =
  ## :lang() takes comma-separated ranges; `*-CH` wildcards the primary tag.
  var ranges: seq[string] = @[]
  var cur = ""
  var i = 0
  while i <= arg.len:
    if i == arg.len or arg[i] == ',':
      var t = ""
      var k = 0
      while k < cur.len:
        let c = cur[k]
        if c != ' ' and c != '"' and c != '\'' and c != '\t': t.add c
        inc k
      if t.len > 0: ranges.add lowerS(t)
      cur = ""
    else:
      cur.add arg[i]
    inc i
  var r = 0
  while r < ranges.len:
    let want = ranges[r]
    if want == lang or startsWith(lang, want & "-"): return true
    if startsWith(want, "*-"):
      var rest = ""
      var k = 1
      while k < want.len:
        rest.add want[k]
        inc k
      if contains(lang, rest): return true
    inc r
  false

proc hasFocusInside(e: Element): bool =
  if e.hasState("focus"): return true
  var i = 0
  while i < e.children.len:
    if hasFocusInside(e.children[i]): return true
    inc i
  false

proc matchRelative(anchor: Element, c: Complex, ctx: MatchCtx): bool

proc pseudoClassMatches(e: Element, sp: Simple, ctx: MatchCtx): bool =
  case sp.name
  of "not": not matchListAt(e, sp.sub, ctx)
  of "is", "where", "matches", "any", "-webkit-any", "-moz-any":
    matchListAt(e, sp.sub, ctx)
  of "has":
    var i = 0
    while i < sp.sub.len:
      if matchRelative(e, sp.sub[i], ctx): return true
      inc i
    false
  of "root": e.parent == nil
  of "scope": (if ctx.scope != nil: e == ctx.scope else: e.parent == nil)
  of "empty": e.children.len == 0 and e.text.len == 0
  of "first-child": siblingPos(e, false, false, @[], ctx) == 1
  of "last-child": siblingPos(e, true, false, @[], ctx) == 1
  of "only-child":
    siblingPos(e, false, false, @[], ctx) == 1 and siblingPos(e, true, false, @[], ctx) == 1
  of "first-of-type": siblingPos(e, false, true, @[], ctx) == 1
  of "last-of-type": siblingPos(e, true, true, @[], ctx) == 1
  of "only-of-type":
    siblingPos(e, false, true, @[], ctx) == 1 and siblingPos(e, true, true, @[], ctx) == 1
  of "nth-child":
    if sp.sub.len > 0 and not matchListAt(e, sp.sub, ctx): false
    else: anbMatches(sp.a, sp.b, siblingPos(e, false, false, sp.sub, ctx))
  of "nth-last-child":
    if sp.sub.len > 0 and not matchListAt(e, sp.sub, ctx): false
    else: anbMatches(sp.a, sp.b, siblingPos(e, true, false, sp.sub, ctx))
  of "nth-of-type": anbMatches(sp.a, sp.b, siblingPos(e, false, true, @[], ctx))
  of "nth-last-of-type": anbMatches(sp.a, sp.b, siblingPos(e, true, true, @[], ctx))
  of "lang": langMatches(langOf(e), sp.arg)
  of "dir": dirOf(e) == lowerS(sp.arg).strip2()
  of "link", "any-link":
    (e.tag == "a" or e.tag == "area") and e.hasAttr("href") and
      (sp.name == "any-link" or not e.hasState("visited"))
  of "visited": e.hasState("visited")
  of "checked":
    e.hasState("checked") or
      ((e.tag == "input") and e.hasAttr("checked")) or
      (e.tag == "option" and e.hasAttr("selected"))
  of "disabled": isFormControl(e) and (e.hasAttr("disabled") or e.hasState("disabled"))
  of "enabled": isFormControl(e) and not e.hasAttr("disabled") and not e.hasState("disabled")
  of "required": isFormControl(e) and e.hasAttr("required")
  of "optional":
    (e.tag == "input" or e.tag == "select" or e.tag == "textarea") and not e.hasAttr("required")
  of "read-only":
    not ((e.tag == "input" or e.tag == "textarea") and not e.hasAttr("readonly") and
         not e.hasAttr("disabled")) and not e.hasAttr("contenteditable")
  of "read-write":
    ((e.tag == "input" or e.tag == "textarea") and not e.hasAttr("readonly") and
     not e.hasAttr("disabled")) or e.hasAttr("contenteditable")
  of "placeholder-shown":
    (e.tag == "input" or e.tag == "textarea") and e.hasAttr("placeholder") and
      e.getAttr("value").len == 0
  of "defined": true
  of "focus-within": hasFocusInside(e)
  of "host", "host-context": false
  else: e.hasState(sp.name)

proc simpleMatches(e: Element, sp: Simple, ctx: MatchCtx): bool =
  case sp.kind
  of skUniversal: true
  of skType: lowerS(sp.name) == e.tag
  of skClass: e.hasClass(sp.name)
  of skId: e.id == sp.name
  of skAttr: attrMatches(e, sp)
  of skPseudoClass: pseudoClassMatches(e, sp, ctx)
  of skPseudoElement: false
  of skNesting:
    if ctx.parent.len == 0: (if ctx.scope != nil: e == ctx.scope else: e.parent == nil)
    else:
      # & stands for the parent rule's selector; inside it, & is ITS parent —
      # unknown here, so the inner match treats it as :scope.
      matchListAt(e, ctx.parent, MatchCtx(parent: @[], scope: ctx.scope))

proc compoundMatches(e: Element, comp: Compound, ctx: MatchCtx): bool =
  var i = 0
  while i < comp.simples.len:
    if not simpleMatches(e, comp.simples[i], ctx): return false
    inc i
  true

proc matchFrom(e: Element, c: Complex, k: int, ctx: MatchCtx): bool =
  ## Does `e` match compounds[0..k] of `c`, with compounds[k] on `e`?
  if not compoundMatches(e, c.compounds[k], ctx): return false
  if k == 0: return true
  case c.combs[k-1]
  of cmChild:
    let p = e.parent
    if p == nil: false else: matchFrom(p, c, k - 1, ctx)
  of cmDescendant:
    var x = e
    while true:
      let p = x.parent
      if p == nil: break
      if matchFrom(p, c, k - 1, ctx): return true
      x = p
    false
  of cmNextSibling:
    let i = e.index
    let sibs = e.siblings
    i > 0 and matchFrom(sibs[i-1], c, k - 1, ctx)
  of cmSubsequentSibling:
    let i = e.index
    let sibs = e.siblings
    var j = i - 1
    while j >= 0:
      if matchFrom(sibs[j], c, k - 1, ctx): return true
      dec j
    false
  of cmColumn, cmNone:
    false

proc matchComplexAt(e: Element, c: Complex, ctx: MatchCtx): bool =
  if c.compounds.len == 0: return false
  if c.lead != cmNone:
    # a relative selector outside :has() (a nested rule): it is relative to &
    var withAmp = c
    withAmp.lead = cmNone
    withAmp.compounds = @[Compound(simples: @[Simple(kind: skNesting, name: "&", caseFlag: '\0')])]
    var i = 0
    while i < c.compounds.len:
      withAmp.compounds.add c.compounds[i]
      inc i
    withAmp.combs = @[c.lead]
    i = 0
    while i < c.combs.len:
      withAmp.combs.add c.combs[i]
      inc i
    return matchFrom(e, withAmp, withAmp.compounds.len - 1, ctx)
  matchFrom(e, c, c.compounds.len - 1, ctx)

proc matchListAt(e: Element, list: SelectorList, ctx: MatchCtx): bool =
  var i = 0
  while i < list.len:
    if matchComplexAt(e, list[i], ctx): return true
    inc i
  false

proc matchForward(x: Element, c: Complex, k: int, ctx: MatchCtx): bool =
  ## :has() runs left to right from the anchor: does `x` match compound k, and
  ## can the rest of the chain be completed from it?
  if not compoundMatches(x, c.compounds[k], ctx): return false
  if k == c.compounds.len - 1: return true
  case c.combs[k]
  of cmChild:
    var i = 0
    while i < x.children.len:
      if matchForward(x.children[i], c, k + 1, ctx): return true
      inc i
    false
  of cmDescendant:
    let ds = x.descendants
    var i = 0
    while i < ds.len:
      if matchForward(ds[i], c, k + 1, ctx): return true
      inc i
    false
  of cmNextSibling:
    let i = x.index
    let sibs = x.siblings
    i >= 0 and i + 1 < sibs.len and matchForward(sibs[i+1], c, k + 1, ctx)
  of cmSubsequentSibling:
    let i = x.index
    if i < 0: return false
    let sibs = x.siblings
    var j = i + 1
    while j < sibs.len:
      if matchForward(sibs[j], c, k + 1, ctx): return true
      inc j
    false
  of cmColumn, cmNone: false

proc matchRelative(anchor: Element, c: Complex, ctx: MatchCtx): bool =
  if c.compounds.len == 0: return false
  var cands: seq[Element] = @[]
  case c.lead
  of cmChild:
    cands = anchor.children
  of cmNextSibling:
    let i = anchor.index
    let sibs = anchor.siblings
    if i >= 0 and i + 1 < sibs.len: cands.add sibs[i+1]
  of cmSubsequentSibling:
    let i = anchor.index
    let sibs = anchor.siblings
    if i >= 0:
      var j = i + 1
      while j < sibs.len:
        cands.add sibs[j]
        inc j
  else:
    cands = anchor.descendants
  var i = 0
  while i < cands.len:
    if matchForward(cands[i], c, 0, ctx): return true
    inc i
  false

# --- public API -------------------------------------------------------------------

proc matchesList*(e: Element, list: SelectorList, parent: SelectorList = @[],
                  scope: nil Element = nil): bool =
  ## Match an already-parsed selector list (no re-parse per element).
  matchListAt(e, list, MatchCtx(parent: parent, scope: scope))

proc matches*(e: Element, sel: string, parent = ""): bool =
  ## Does `e` match `sel`? An invalid selector matches nothing. `parent` is the
  ## enclosing rule's selector, for a nested selector that uses `&`.
  let r = parseSelector(sel, true)
  if not r.ok: return false
  var p: SelectorList = @[]
  if parent.len > 0:
    let pr = parseSelector(parent, true)
    if pr.ok: p = pr.list
  matchListAt(e, r.list, MatchCtx(parent: p, scope: nil))

proc querySelectorAll*(root: Element, sel: string): seq[Element] =
  ## Every descendant of `root` (not `root` itself) matching `sel`, in
  ## document order. `:scope` is `root`.
  result = @[]
  let r = parseSelector(sel, true)
  if not r.ok: return
  let ctx = MatchCtx(parent: @[], scope: root)
  let ds = root.descendants
  var i = 0
  while i < ds.len:
    if matchListAt(ds[i], r.list, ctx): result.add ds[i]
    inc i

proc querySelector*(root: Element, sel: string): nil Element =
  ## The first match, or nil.
  result = nil
  let all = querySelectorAll(root, sel)
  if all.len > 0: result = all[0]

proc closest*(e: Element, sel: string): nil Element =
  ## `e` or its nearest ancestor matching `sel`, or nil.
  let r = parseSelector(sel, true)
  if not r.ok: return nil
  let ctx = MatchCtx(parent: @[], scope: nil)
  var x = e
  while true:
    if matchListAt(x, r.list, ctx): return x
    let p = x.parent
    if p == nil: break
    x = p
  nil
