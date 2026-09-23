## computed.nim — the cascade, inheritance and computed values.
##
##   let eng = newStyleEngine()                 # a 1280×720 screen by default
##   eng.addUserAgentDefaults()                 # HTML's default display/margins
##   eng.addStylesheet(readFile("site.css"))
##   let cs = eng.computedStyle(el)
##   cs.get("color")            # the computed colour
##   cs.get("margin-top")       # "16px" — em/rem/%/pt/vw made absolute
##   eng.why(el, "color")       # which rule won, and why
##
## What a stylesheet contributes, and when:
##   * style rules, with CSS Nesting resolved (`&` and relative selectors
##     become `:is(parent)`, which is also their specificity);
##   * `@media` (evaluated at computeStyle time, so changing `eng.env` takes
##     effect), `@supports` (evaluated by this library's validator), `@layer`
##     (named, nested `a.b`, anonymous, and the ordering statement), `@scope`
##     (roots, limits, and `:scope`), `@property` (a registered custom
##     property's inheritance and initial value);
##   * the `style` attribute, as element-attached declarations;
##   * a rule whose selector ends in `::before` / `::after` / … styles that
##     pseudo-element: ask for it with `computedStyle(el, "before")`.
##
## The cascade (CSS Cascade 5): origin and importance (user-agent < user <
## author for normal declarations, reversed for !important), then element-
## attached before rules, then layers (later wins for normal, earlier for
## !important, unlayered last/first), then specificity, then order.
##
## Computing: shorthands are expanded to longhands (`css/shorthand`); custom
## properties are resolved first, `var()` substituted with fallbacks and cycle
## detection (a cycle is invalid at computed-value time); the CSS-wide keywords
## `inherit`/`initial`/`unset`/`revert`/`revert-layer` are applied; a value
## still invalid after substitution becomes `unset`; inherited properties flow
## from the parent; lengths in em/rem/ex/ch/%(font-size)/pt/pc/in/cm/mm/Q/vw/vh
## /vmin/vmax and the font-size keywords become px. Everything else is the
## specified value, as written.
##
## Not modelled: layout (so `@container` queries are false and percentages of
## a containing block stay percentages), animations and transitions, shadow
## trees, and `@import` (resolve it first with `css/imports`).

import std/tables
import parse
import selectors
import cascade
import dom
import match
import media
import shorthand
import validator
import data_load
import color

type
  Origin* = enum
    oUserAgent, oUser, oAuthor

  CDecl = object
    prop: string            ## a longhand, a custom property, or a shorthand
                            ## whose value holds var() (expanded after substitution)
    value: string
    important: bool
    line: int

  StyleRule = object
    list: SelectorList      ## nesting resolved
    pseudo: string          ## "" or the pseudo-element this rule styles
    decls: seq[CDecl]
    origin: Origin
    layer: int              ## rank in the layer order; unlayered = high
    layerName: string
    order: int
    media: seq[string]      ## every enclosing @media list (all must hold)
    scopeStart: SelectorList
    scopeEnd: SelectorList
    scoped: bool
    source: string          ## sheet name
    selectorText: string
    line: int

  Registered = object
    name: string
    syntax: string
    inherits: bool
    initial: string

  StyleEngine* = ref object
    env*: MediaEnv
    rules: seq[StyleRule]
    layerOrder: seq[string]
    registered: seq[Registered]
    nextOrder: int
    anon: int
    index: Table[string, seq[int]]    ## rightmost-compound key → rule indices
    seen: seq[int]                    ## per-rule stamp, to dedupe index hits
    stamp: int
    mediaCache: Table[string, bool]   ## per computedStyle/computeTree call
    validCache: Table[string, bool]   ## prop \0 value → valid
    expandCache: Table[string, seq[Longhand]]

  ComputedStyle* = object
    values*: Table[string, string]   ## every property set on or inherited by
                                     ## the element; `get` falls back to initial

  Candidate = object
    value: string
    important: bool
    origin: Origin
    inline: bool
    layer: int
    spec: Specificity
    order: int
    fromShorthand: string   ## the var()-holding shorthand this came from
    ruleIdx: int            ## -1 for the style attribute
    line: int

const Unlayered = 1000000

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc isCustom(p: string): bool = p.len > 2 and p[0] == '-' and p[1] == '-'

proc hasVar(v: string): bool =
  var i = 0
  while i + 3 < v.len:
    if (v[i] == 'v' or v[i] == 'V') and (v[i+1] == 'a' or v[i+1] == 'A') and
       (v[i+2] == 'r' or v[i+2] == 'R') and v[i+3] == '(' and
       (i == 0 or not ((v[i-1] >= 'a' and v[i-1] <= 'z') or v[i-1] == '-')):
      return true
    inc i
  false

proc newStyleEngine*(env = defaultEnv()): StyleEngine =
  StyleEngine(env: env, rules: @[], layerOrder: @[], registered: @[], nextOrder: 0, anon: 0,
              index: initTable[string, seq[int]](), seen: @[], stamp: 0,
              mediaCache: initTable[string, bool](), validCache: initTable[string, bool](),
              expandCache: initTable[string, seq[Longhand]]())

proc keyOf(c: Complex): string =
  ## The bucket a complex selector is filed under: its rightmost compound's
  ## id, else a class, else its tag, else "*".
  if c.compounds.len == 0: return "*"
  let comp = c.compounds[c.compounds.len - 1]
  var cls = ""
  var tag = ""
  var i = 0
  while i < comp.simples.len:
    let sp = comp.simples[i]
    case sp.kind
    of skId: return "#" & sp.name
    of skClass:
      if cls.len == 0: cls = "." & sp.name
    of skType: tag = lower(sp.name)
    else: discard
    inc i
  if cls.len > 0: return cls
  if tag.len > 0: return tag
  "*"

proc fileRule(e: StyleEngine, idx: int) =
  var keys: seq[string] = @[]
  var i = 0
  while i < e.rules[idx].list.len:
    let k = keyOf(e.rules[idx].list[i])
    var dup = false
    var j = 0
    while j < keys.len:
      if keys[j] == k: dup = true
      inc j
    if not dup: keys.add k
    inc i
  i = 0
  while i < keys.len:
    var b = e.index.getOrDefault(keys[i], @[])
    b.add idx
    e.index[keys[i]] = b
    inc i
  e.seen.add 0

proc validCached(e: StyleEngine, prop, value: string): bool =
  let k = prop & "\x00" & value
  if e.validCache.hasKey(k): return e.validCache.getOrDefault(k, false)
  let r = validateValue(prop, value).valid
  e.validCache[k] = r
  r

proc expandCached(e: StyleEngine, prop, value: string): tuple[ok: bool, longhands: seq[Longhand]] =
  let k = prop & "\x00" & value
  if e.expandCache.hasKey(k): return (true, e.expandCache.getOrDefault(k, @[]))
  let x = expandShorthand(prop, value)
  if x.ok: e.expandCache[k] = x.longhands
  x

proc mediaTrue(e: StyleEngine, q: string): bool =
  if e.mediaCache.hasKey(q): return e.mediaCache.getOrDefault(q, false)
  let r = evalMediaQueryList(q, e.env)
  e.mediaCache[q] = r
  r

# --- adding sheets ---------------------------------------------------------------

proc layerRank(e: StyleEngine, name: string): int =
  if name.len == 0: return Unlayered
  var i = 0
  while i < e.layerOrder.len:
    if e.layerOrder[i] == name: return i
    inc i
  e.layerOrder.add name
  e.layerOrder.len - 1

proc declareLayer(e: StyleEngine, name: string) = discard layerRank(e, name)

proc joinLayer(prefix, name: string): string =
  if prefix.len == 0: name else: prefix & "." & name

proc splitCommaList(s: string): seq[string] =
  result = @[]
  var cur = ""
  var i = 0
  while i <= s.len:
    if i == s.len or s[i] == ',':
      var t = ""
      var k = 0
      while k < cur.len:
        if cur[k] != ' ' and cur[k] != '\t' and cur[k] != '\n': t.add cur[k]
        inc k
      if t.len > 0: result.add t
      cur = ""
    else:
      cur.add s[i]
    inc i

proc toCDecls(decls: seq[Declaration]): seq[CDecl] =
  ## Longhands as they are; shorthands expanded now unless they hold var().
  result = @[]
  var i = 0
  while i < decls.len:
    let d = decls[i]
    let p = (if isCustom(d.prop): d.prop else: lower(d.prop))
    if isCustom(p):
      result.add CDecl(prop: p, value: d.value, important: d.important, line: d.line)
    elif isShorthand(p) or p == "overflow" or p == "gap" or p == "place-items" or
         p == "place-content" or p == "place-self" or p == "inset" or p == "grid-gap":
      if hasVar(d.value):
        result.add CDecl(prop: p, value: d.value, important: d.important, line: d.line)
      else:
        let x = expandShorthand(p, d.value)
        if x.ok:
          var k = 0
          while k < x.longhands.len:
            result.add CDecl(prop: x.longhands[k].name, value: x.longhands[k].value,
                             important: d.important, line: d.line)
            inc k
    elif isProperty(p) or hasVar(d.value):
      result.add CDecl(prop: p, value: d.value, important: d.important, line: d.line)
    inc i

proc makeIs(parent: SelectorList): Simple =
  Simple(kind: skPseudoClass, name: "is", hasArg: true, sub: parent, caseFlag: '\0')

proc hasNesting(c: Complex): bool =
  var i = 0
  while i < c.compounds.len:
    var j = 0
    while j < c.compounds[i].simples.len:
      if c.compounds[i].simples[j].kind == skNesting: return true
      inc j
    inc i
  false

proc resolveNesting(list: SelectorList, parent: SelectorList): SelectorList =
  ## `&` → `:is(parent)`; a selector without `&` is relative to the parent
  ## (`> a` → `:is(parent) > a`, `a` → `:is(parent) a`).
  result = @[]
  var i = 0
  while i < list.len:
    var c = list[i]
    if hasNesting(c):
      var k = 0
      while k < c.compounds.len:
        var j = 0
        while j < c.compounds[k].simples.len:
          if c.compounds[k].simples[j].kind == skNesting:
            c.compounds[k].simples[j] = makeIs(parent)
          inc j
        inc k
      if c.lead != cmNone:
        var nc = Complex(lead: cmNone, compounds: @[Compound(simples: @[makeIs(parent)])],
                         combs: @[c.lead])
        var m = 0
        while m < c.compounds.len:
          nc.compounds.add c.compounds[m]
          inc m
        m = 0
        while m < c.combs.len:
          nc.combs.add c.combs[m]
          inc m
        c = nc
    else:
      var nc = Complex(lead: cmNone, compounds: @[Compound(simples: @[makeIs(parent)])],
                       combs: @[(if c.lead != cmNone: c.lead else: cmDescendant)])
      var m = 0
      while m < c.compounds.len:
        nc.compounds.add c.compounds[m]
        inc m
      m = 0
      while m < c.combs.len:
        nc.combs.add c.combs[m]
        inc m
      c = nc
    result.add c
    inc i

proc scopePrefixed(list: SelectorList): SelectorList =
  ## Inside @scope a selector without `&`/`:scope` is a descendant of the scope
  ## root: prepend `& ` (the matcher's `&` with no parent is :scope).
  result = @[]
  var i = 0
  while i < list.len:
    var c = list[i]
    var mentions = hasNesting(c)
    var k = 0
    while k < c.compounds.len:
      var j = 0
      while j < c.compounds[k].simples.len:
        let sp = c.compounds[k].simples[j]
        if sp.kind == skPseudoClass and sp.name == "scope": mentions = true
        inc j
      inc k
    if not mentions:
      var nc = Complex(lead: cmNone,
                       compounds: @[Compound(simples: @[Simple(kind: skNesting, name: "&", caseFlag: '\0')])],
                       combs: @[(if c.lead != cmNone: c.lead else: cmDescendant)])
      var m = 0
      while m < c.compounds.len:
        nc.compounds.add c.compounds[m]
        inc m
      m = 0
      while m < c.combs.len:
        nc.combs.add c.combs[m]
        inc m
      c = nc
    result.add c
    inc i

proc splitPseudo(c: Complex): tuple[c: Complex, pseudo: string] =
  ## Peel a trailing pseudo-element off the last compound.
  var r = c
  if r.compounds.len == 0: return (r, "")
  let last = r.compounds.len - 1
  var simples = r.compounds[last].simples
  var pseudo = ""
  var kept: seq[Simple] = @[]
  var i = 0
  while i < simples.len:
    if simples[i].kind == skPseudoElement and pseudo.len == 0:
      pseudo = simples[i].name
    elif pseudo.len == 0:
      kept.add simples[i]
    inc i
  if pseudo.len == 0: return (r, "")
  if kept.len == 0: kept.add Simple(kind: skUniversal, name: "*", caseFlag: '\0')
  r.compounds[last] = Compound(simples: kept)
  (r, pseudo)

type Frame = object
  parent: SelectorList
  hasParent: bool
  layer: string
  media: seq[string]
  scopeStart: SelectorList
  scopeEnd: SelectorList
  scoped: bool

proc addRuleDecls(e: StyleEngine, list: SelectorList, text: string, decls: seq[Declaration],
                  fr: Frame, origin: Origin, source: string, line: int) =
  if decls.len == 0: return
  let cds = toCDecls(decls)
  # one StyleRule per distinct target (the element itself, or a pseudo-element)
  var groups: seq[tuple[pseudo: string, list: SelectorList]] = @[]
  var i = 0
  while i < list.len:
    let sp = splitPseudo(list[i])
    var found = -1
    var g = 0
    while g < groups.len:
      if groups[g].pseudo == sp.pseudo: found = g
      inc g
    if found < 0:
      groups.add (pseudo: sp.pseudo, list: @[sp.c])
    else:
      groups[found].list.add sp.c
    inc i
  var g = 0
  while g < groups.len:
    e.rules.add StyleRule(list: groups[g].list, pseudo: groups[g].pseudo, decls: cds,
                          origin: origin, layer: layerRank(e, fr.layer),
                          layerName: fr.layer, order: e.nextOrder, media: fr.media,
                          scopeStart: fr.scopeStart, scopeEnd: fr.scopeEnd,
                          scoped: fr.scoped, source: source, selectorText: text,
                          line: line)
    fileRule(e, e.rules.len - 1)
    inc e.nextOrder
    inc g

proc unquote(s: string): string =
  if s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len-1] == s[0]:
    result = ""
    var i = 1
    while i < s.len - 1:
      result.add s[i]
      inc i
  else:
    result = s

proc registerProperty(e: StyleEngine, r: ParsedRule) =
  var reg = Registered(name: r.atPrelude, syntax: "*", inherits: true, initial: "")
  var i = 0
  while i < r.decls.len:
    let d = r.decls[i]
    case lower(d.prop)
    of "syntax": reg.syntax = unquote(d.value)
    of "inherits": reg.inherits = lower(d.value) == "true"
    of "initial-value": reg.initial = d.value
    else: discard
    inc i
  e.registered.add reg

proc flatten(e: StyleEngine, rules: seq[ParsedRule], fr: Frame, origin: Origin, source: string) =
  var i = 0
  while i < rules.len:
    let r = rules[i]
    if not r.isAtRule:
      let parsed = parseSelector(r.prelude, fr.hasParent or fr.scoped)
      if parsed.ok:
        var list = parsed.list
        if fr.hasParent: list = resolveNesting(list, fr.parent)
        elif fr.scoped: list = scopePrefixed(list)
        addRuleDecls(e, list, r.prelude, r.decls, fr, origin, source, r.line)
        var child = fr
        child.parent = list
        child.hasParent = true
        flatten(e, r.children, child, origin, source)
    else:
      let kw = lower(r.atKeyword)
      case kw
      of "media":
        var child = fr
        child.media.add r.atPrelude
        if fr.hasParent: addRuleDecls(e, fr.parent, "&", r.decls, child, origin, source, r.line)
        flatten(e, r.children, child, origin, source)
      of "supports":
        if evalSupports(r.atPrelude):
          if fr.hasParent: addRuleDecls(e, fr.parent, "&", r.decls, fr, origin, source, r.line)
          flatten(e, r.children, fr, origin, source)
      of "layer":
        if r.hasBlock:
          var name = r.atPrelude
          if name.len == 0:
            inc e.anon
            name = "\x01anon" & $e.anon
          var child = fr
          child.layer = joinLayer(fr.layer, name)
          declareLayer(e, child.layer)
          if fr.hasParent: addRuleDecls(e, fr.parent, "&", r.decls, child, origin, source, r.line)
          flatten(e, r.children, child, origin, source)
        else:
          let names = splitCommaList(r.atPrelude)
          var k = 0
          while k < names.len:
            declareLayer(e, joinLayer(fr.layer, names[k]))
            inc k
      of "scope":
        var child = fr
        child.scoped = true
        child.hasParent = false
        child.scopeStart = @[]
        child.scopeEnd = @[]
        # (start) to (end)
        let p = r.atPrelude
        var depth = 0
        var parts: seq[string] = @[]
        var cur = ""
        var k = 0
        while k < p.len:
          let c = p[k]
          if c == '(':
            if depth == 0: cur = "" else: cur.add c
            inc depth
          elif c == ')':
            dec depth
            if depth == 0: parts.add cur else: cur.add c
          elif depth > 0:
            cur.add c
          elif depth == 0 and (c == 't' or c == 'T') and k + 1 < p.len and
               (p[k+1] == 'o' or p[k+1] == 'O') and parts.len == 0:
            parts.add ""        # `@scope to (x)`: no start
          inc k
        if parts.len >= 1 and parts[0].len > 0:
          let s = parseSelector(parts[0], false)
          if s.ok: child.scopeStart = s.list
        if parts.len >= 2:
          let s = parseSelector(parts[1], false)
          if s.ok: child.scopeEnd = s.list
        flatten(e, r.children, child, origin, source)
      of "property":
        registerProperty(e, r)
      of "starting-style", "container", "keyframes", "-webkit-keyframes",
         "font-face", "page", "counter-style", "font-feature-values",
         "font-palette-values", "view-transition", "position-try", "import",
         "charset", "namespace":
        discard
      else:
        discard
    inc i

proc addSheet*(e: StyleEngine, sheet: ParsedSheet, origin = oAuthor, name = "") =
  ## Add an already-parsed sheet. Later sheets come later in source order.
  flatten(e, sheet.rules, Frame(parent: @[], hasParent: false, layer: "", media: @[],
                                scopeStart: @[], scopeEnd: @[], scoped: false),
          origin, name)

proc addStylesheet*(e: StyleEngine, src: string, origin = oAuthor, name = "") =
  ## Parse and add a stylesheet. `origin` places it in the cascade.
  addSheet(e, parseStylesheet(src), origin, name)

const userAgentCss* = """
html, address, blockquote, body, dd, div, dl, dt, fieldset, figcaption, figure,
footer, form, h1, h2, h3, h4, h5, h6, header, hgroup, hr, legend, main, menu,
nav, ol, p, pre, search, section, ul, article, aside, details, summary, dialog { display: block }
head, link, meta, script, style, template, title, [hidden], area, base, datalist, noscript, param, rp { display: none }
li { display: list-item }
table { display: table; border-collapse: separate; border-spacing: 2px; box-sizing: border-box; text-indent: initial }
caption { display: table-caption; text-align: center }
thead { display: table-header-group; vertical-align: middle }
tbody { display: table-row-group; vertical-align: middle }
tfoot { display: table-footer-group; vertical-align: middle }
tr { display: table-row; vertical-align: inherit }
td, th { display: table-cell; vertical-align: inherit; padding: 1px }
th { font-weight: bold; text-align: center }
col { display: table-column }
colgroup { display: table-column-group }
ruby { display: ruby }
rt { display: ruby-text }
body { margin: 8px }
p, blockquote, figure, dl, pre, menu, ol, ul { margin-block: 1em }
blockquote, figure { margin-inline: 40px }
dd { margin-inline-start: 40px }
ol, ul, menu { padding-inline-start: 40px }
ol { list-style-type: decimal }
ul, menu { list-style-type: disc }
ul ul, ol ul, menu ul { list-style-type: circle }
h1 { font-size: 2em; margin-block: 0.67em; font-weight: bold }
h2 { font-size: 1.5em; margin-block: 0.83em; font-weight: bold }
h3 { font-size: 1.17em; margin-block: 1em; font-weight: bold }
h4 { margin-block: 1.33em; font-weight: bold }
h5 { font-size: 0.83em; margin-block: 1.67em; font-weight: bold }
h6 { font-size: 0.67em; margin-block: 2.33em; font-weight: bold }
hr { color: gray; border-style: inset; border-width: 1px; margin: 0.5em auto }
b, strong { font-weight: bolder }
i, cite, em, var, dfn { font-style: italic }
code, kbd, samp, tt, pre { font-family: monospace }
pre { white-space: pre }
small { font-size: smaller }
big { font-size: larger }
sub { vertical-align: sub; font-size: smaller }
sup { vertical-align: super; font-size: smaller }
u, ins { text-decoration: underline }
s, strike, del { text-decoration: line-through }
mark { background-color: Mark; color: MarkText }
a:link, a:visited { color: LinkText; text-decoration: underline; cursor: pointer }
a:visited { color: VisitedText }
center { display: block; text-align: center }
img { overflow: clip }
button, input, select, textarea { display: inline-block }
[dir="rtl" i] { direction: rtl }
[dir="ltr" i] { direction: ltr }
"""

proc addUserAgentDefaults*(e: StyleEngine) =
  ## The HTML user-agent stylesheet (the parts that matter for computed
  ## display, margins, fonts and lists), in the user-agent origin.
  addStylesheet(e, userAgentCss, oUserAgent, "user-agent")

# --- logical properties ---------------------------------------------------------------
# A logical property IS its physical counterpart for the cascade (CSS Logical
# Properties §4): `margin-block-start` and `margin-top` compete, and the later
# or stronger one wins. Which physical side it names depends on the element's
# writing-mode and direction.

proc hasPrefixS(s, p: string): bool =
  if s.len < p.len: return false
  var i = 0
  while i < p.len:
    if s[i] != p[i]: return false
    inc i
  true

proc cutPrefix(s, p: string): string =
  result = ""
  var i = p.len
  while i < s.len:
    result.add s[i]
    inc i

proc sideFor(axis, edge, wm, dir: string): string =
  ## "block"/"inline" × "start"/"end" → "top"/"right"/"bottom"/"left".
  let vertical = wm == "vertical-rl" or wm == "vertical-lr" or
                 wm == "sideways-rl" or wm == "sideways-lr"
  let rtl = dir == "rtl"
  if axis == "block":
    if not vertical: return (if edge == "start": "top" else: "bottom")
    let rl = wm == "vertical-rl" or wm == "sideways-rl"
    if edge == "start": return (if rl: "right" else: "left")
    return (if rl: "left" else: "right")
  # inline axis
  if not vertical:
    if edge == "start": return (if rtl: "right" else: "left")
    return (if rtl: "left" else: "right")
  let up = wm == "sideways-lr"      # sideways-lr runs bottom-to-top
  if edge == "start": return (if rtl != up: "bottom" else: "top")
  (if rtl != up: "top" else: "bottom")

proc physicalOf*(prop, wm, dir: string): string =
  ## The physical property a logical one maps to for this writing mode and
  ## direction (`margin-inline-start` → `margin-left` in ltr horizontal-tb);
  ## a physical or unrelated property maps to itself.
  let vertical = wm == "vertical-rl" or wm == "vertical-lr" or
                 wm == "sideways-rl" or wm == "sideways-lr"
  case prop
  of "inline-size": return (if vertical: "height" else: "width")
  of "block-size": return (if vertical: "width" else: "height")
  of "min-inline-size": return (if vertical: "min-height" else: "min-width")
  of "min-block-size": return (if vertical: "min-width" else: "min-height")
  of "max-inline-size": return (if vertical: "max-height" else: "max-width")
  of "max-block-size": return (if vertical: "max-width" else: "max-height")
  of "contain-intrinsic-inline-size":
    return (if vertical: "contain-intrinsic-height" else: "contain-intrinsic-width")
  of "contain-intrinsic-block-size":
    return (if vertical: "contain-intrinsic-width" else: "contain-intrinsic-height")
  of "overflow-inline": return (if vertical: "overflow-y" else: "overflow-x")
  of "overflow-block": return (if vertical: "overflow-x" else: "overflow-y")
  of "overscroll-behavior-inline":
    return (if vertical: "overscroll-behavior-y" else: "overscroll-behavior-x")
  of "overscroll-behavior-block":
    return (if vertical: "overscroll-behavior-x" else: "overscroll-behavior-y")
  else: discard
  # border-<block>-<inline>-radius corners
  if hasPrefixS(prop, "border-start-") or hasPrefixS(prop, "border-end-"):
    let rest = cutPrefix(prop, "border-")          # start-end-radius
    var a = ""
    var b = ""
    var i = 0
    var part = 0
    while i < rest.len:
      if rest[i] == '-': inc part
      elif part == 0: a.add rest[i]
      elif part == 1: b.add rest[i]
      inc i
    if (a == "start" or a == "end") and (b == "start" or b == "end"):
      let bs = sideFor("block", a, wm, dir)
      let isd = sideFor("inline", b, wm, dir)
      let vert = (if bs == "top" or bs == "bottom": bs else: isd)
      let horz = (if bs == "left" or bs == "right": bs else: isd)
      return "border-" & vert & "-" & horz & "-radius"
  # <prefix>-(block|inline)-(start|end)[-suffix]
  for prefix in ["margin-", "padding-", "inset-", "scroll-margin-", "scroll-padding-",
                 "border-"]:
    if hasPrefixS(prop, prefix):
      let rest = cutPrefix(prop, prefix)             # block-start[-width]
      var axis = ""
      if hasPrefixS(rest, "block-"): axis = "block"
      elif hasPrefixS(rest, "inline-"): axis = "inline"
      if axis.len > 0:
        let r2 = cutPrefix(rest, axis & "-")         # start[-width]
        var edge = ""
        if hasPrefixS(r2, "start"): edge = "start"
        elif hasPrefixS(r2, "end"): edge = "end"
        if edge.len > 0:
          let suffix = cutPrefix(r2, edge)           # "" or "-width"
          let side = sideFor(axis, edge, wm, dir)
          if prefix == "inset-": return side & suffix
          return prefix & side & suffix
  prop

# --- the cascade ---------------------------------------------------------------------

proc importanceRank(origin: Origin, important: bool): int =
  if not important:
    case origin
    of oUserAgent: 1
    of oUser: 2
    of oAuthor: 3
  else:
    case origin
    of oAuthor: 4
    of oUser: 5
    of oUserAgent: 6

proc beats(a, b: Candidate): bool =
  ## Does candidate `a` win over `b`?
  let ra = importanceRank(a.origin, a.important)
  let rb = importanceRank(b.origin, b.important)
  if ra != rb: return ra > rb
  if a.inline != b.inline: return a.inline
  if a.layer != b.layer:
    if a.important: return a.layer < b.layer
    return a.layer > b.layer
  if not (a.spec == b.spec): return b.spec < a.spec
  a.order > b.order

proc inScope(e: StyleEngine, el: Element, r: StyleRule): tuple[ok: bool, root: Element] =
  ## For a rule inside @scope: the scope root (nearest ancestor-or-self
  ## matching the start, or the document root when there is none) such that
  ## no scoping limit sits between it and `el`.
  var x = el
  while true:
    var isRoot = false
    if r.scopeStart.len == 0:
      isRoot = x.parent == nil
    else:
      isRoot = matchesList(x, r.scopeStart)
    if isRoot:
      # check the lower boundary between x (exclusive) and el (inclusive)
      var blocked = false
      if r.scopeEnd.len > 0:
        var y = el
        while y != x:
          if matchesList(y, r.scopeEnd, @[], x): blocked = true
          let p = y.parent
          if p == nil: break
          y = p
      if not blocked: return (true, x)
    let p = x.parent
    if p == nil: break
    x = p
  (false, el)

proc ruleMatches(e: StyleEngine, el: Element, r: StyleRule, pseudo: string):
    tuple[ok: bool, spec: Specificity] =
  if r.pseudo != pseudo: return (false, Specificity())
  var mi = 0
  while mi < r.media.len:
    if not mediaTrue(e, r.media[mi]): return (false, Specificity())
    inc mi
  var scope: nil Element = nil
  if r.scoped:
    let sc = inScope(e, el, r)
    if not sc.ok: return (false, Specificity())
    scope = sc.root
  var best = Specificity()
  var any = false
  var i = 0
  while i < r.list.len:
    if matchesList(el, @[r.list[i]], @[], scope):
      let sp = ofComplex(r.list[i])
      if not any or best < sp: best = sp
      any = true
    inc i
  (any, best)

proc candidateRules(e: StyleEngine, el: Element): seq[int] =
  ## The rules whose rightmost compound could match `el`, in source order.
  result = @[]
  inc e.stamp
  var keys = @["*", el.tag]
  let id = el.id
  if id.len > 0: keys.add "#" & id
  let cls = el.classes
  var i = 0
  while i < cls.len:
    keys.add "." & cls[i]
    inc i
  i = 0
  while i < keys.len:
    if e.index.hasKey(keys[i]):
      let b = e.index.getOrDefault(keys[i], @[])
      var j = 0
      while j < b.len:
        let r = b[j]
        if e.seen[r] != e.stamp:
          e.seen[r] = e.stamp
          result.add r
        inc j
    inc i
  # insertion sort: source order (buckets are each already sorted)
  var a = 1
  while a < result.len:
    let x = result[a]
    var b = a - 1
    while b >= 0 and result[b] > x:
      let moved = result[b]
      result[b + 1] = moved
      dec b
    result[b + 1] = x
    inc a

proc collect(e: StyleEngine, el: Element, pseudo: string): Table[string, seq[Candidate]] =
  result = initTable[string, seq[Candidate]]()
  let ruleIdx = candidateRules(e, el)
  var rk = 0
  while rk < ruleIdx.len:
    let ri = ruleIdx[rk]
    inc rk
    let r = e.rules[ri]
    let m = ruleMatches(e, el, r, pseudo)
    if m.ok:
      var k = 0
      while k < r.decls.len:
        let d = r.decls[k]
        let c = Candidate(value: d.value, important: d.important, origin: r.origin,
                          inline: false, layer: r.layer, spec: m.spec,
                          order: r.order * 100000 + k,
                          fromShorthand: "", ruleIdx: ri, line: d.line)
        var names: seq[string] = @[]
        if not isCustom(d.prop) and hasVar(d.value) and
           (isShorthand(d.prop) or d.prop == "overflow" or d.prop == "gap" or
            d.prop == "inset" or d.prop == "place-items" or d.prop == "place-content" or
            d.prop == "place-self"):
          names = shorthandLonghands(d.prop)
          var j = 0
          while j < names.len:
            var cc = c
            cc.fromShorthand = d.prop
            var s = result.getOrDefault(names[j], @[])
            s.add cc
            result[names[j]] = s
            inc j
        else:
          var s = result.getOrDefault(d.prop, @[])
          s.add c
          result[d.prop] = s
        inc k
  # the style attribute: element-attached, author origin
  if pseudo.len == 0 and el.hasAttr("style"):
    let ds = toCDecls(parseDeclarations(el.getAttr("style")))
    var k = 0
    while k < ds.len:
      let d = ds[k]
      let c = Candidate(value: d.value, important: d.important, origin: oAuthor,
                        inline: true, layer: Unlayered, spec: Specificity(),
                        order: 1000000000000 + k, fromShorthand: "", ruleIdx: -1, line: 0)
      if not isCustom(d.prop) and hasVar(d.value) and isShorthand(d.prop):
        let names = shorthandLonghands(d.prop)
        var j = 0
        while j < names.len:
          var cc = c
          cc.fromShorthand = d.prop
          var s = result.getOrDefault(names[j], @[])
          s.add cc
          result[names[j]] = s
          inc j
      else:
        var s = result.getOrDefault(d.prop, @[])
        s.add c
        result[d.prop] = s
      inc k

proc winner(cands: seq[Candidate], maxOrigin: Origin, belowLayerOf: int,
            respectLayer: bool): tuple[found: bool, c: Candidate] =
  ## The winning candidate among those from origins <= maxOrigin (for
  ## `revert`) and, when respectLayer, from layers below `belowLayerOf`
  ## (for `revert-layer`).
  var best = Candidate()
  var found = false
  var i = 0
  while i < cands.len:
    let c = cands[i]
    var eligible = ord(c.origin) <= ord(maxOrigin)
    if respectLayer and eligible: eligible = c.layer < belowLayerOf
    if eligible and (not found or beats(c, best)):
      best = c
      found = true
    inc i
  (found, best)

# --- value computation ---------------------------------------------------------------

proc fmtNum(x: float): string =
  ## Up to 4 decimals, no trailing zeros: 16 -> "16", 13.3333 -> "13.3333".
  var v = x
  var neg = false
  if v < 0.0:
    neg = true
    v = -v
  var scaled = int(v * 10000.0 + 0.5)
  let ip = scaled div 10000
  var frac = scaled mod 10000
  result = (if neg and scaled > 0: "-" else: "") & $ip
  if frac > 0:
    var fs = $frac
    while fs.len < 4: fs = "0" & fs
    while fs.len > 0 and fs[fs.len-1] == '0':
      var t = ""
      var k = 0
      while k < fs.len - 1:
        t.add fs[k]
        inc k
      fs = t
    result.add "." & fs

proc parseNumPrefix(s: string, n: var float, unit: var string): bool =
  var i = 0
  var neg = false
  if i < s.len and (s[i] == '-' or s[i] == '+'):
    neg = s[i] == '-'
    inc i
  var r = 0.0
  var digits = 0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    r = r * 10.0 + float(ord(s[i]) - ord('0'))
    inc i
    inc digits
  if i < s.len and s[i] == '.':
    inc i
    var scale = 0.1
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      r = r + float(ord(s[i]) - ord('0')) * scale
      scale = scale * 0.1
      inc i
      inc digits
  if digits == 0: return false
  if i < s.len and (s[i] == 'e' or s[i] == 'E') and i + 1 < s.len and
     ((s[i+1] >= '0' and s[i+1] <= '9') or s[i+1] == '-' or s[i+1] == '+'):
    return false                   # exponent forms: leave as written
  unit = ""
  while i < s.len:
    unit.add s[i]
    inc i
  n = (if neg: -r else: r)
  true

type LenCtx = object
  fontPx: float        ## this element's font size (em for most properties)
  parentFontPx: float  ## the parent's (em/% for font-size itself)
  rootFontPx: float
  env: MediaEnv
  forFontSize: bool

proc toPx(n: float, unit: string, c: LenCtx, ok: var bool): float =
  ok = true
  let em = (if c.forFontSize: c.parentFontPx else: c.fontPx)
  let w = c.env.width
  let h = c.env.height
  let vmin = (if w < h: w else: h)
  let vmax = (if w > h: w else: h)
  case lower(unit)
  of "px": n
  of "em": n * em
  of "rem": n * c.rootFontPx
  of "ex", "ch", "rex", "rch": n * (if unit[0] == 'r': c.rootFontPx else: em) * 0.5
  of "cap", "rcap": n * (if unit[0] == 'r': c.rootFontPx else: em) * 0.7
  of "ic", "ric": n * (if unit[0] == 'r': c.rootFontPx else: em)
  of "lh", "rlh": n * (if unit[0] == 'r': c.rootFontPx else: em) * 1.2
  of "in": n * 96.0
  of "cm": n * 96.0 / 2.54
  of "mm": n * 96.0 / 25.4
  of "q": n * 96.0 / 101.6
  of "pt": n * 96.0 / 72.0
  of "pc": n * 16.0
  of "vw", "svw", "lvw", "dvw", "vi", "svi", "lvi", "dvi": n * w / 100.0
  of "vh", "svh", "lvh", "dvh", "vb", "svb", "lvb", "dvb": n * h / 100.0
  of "vmin", "svmin", "lvmin", "dvmin": n * vmin / 100.0
  of "vmax", "svmax", "lvmax", "dvmax": n * vmax / 100.0
  of "%":
    if c.forFontSize: n * c.parentFontPx / 100.0
    else:
      ok = false
      0.0
  else:
    ok = false
    0.0

proc absolutize(value: string, c: LenCtx): string =
  ## Make every top-level length absolute (px); leave everything else.
  let toks = components(value)
  result = ""
  var i = 0
  while i < toks.len:
    let t = toks[i]
    var n = 0.0
    var unit = ""
    var outTok = t
    if parseNumPrefix(t, n, unit):
      if unit.len > 0:
        var ok = false
        let px = toPx(n, unit, c, ok)
        let lu = lower(unit)
        if ok: outTok = fmtNum(px) & "px"
        elif lu == "ms": outTok = fmtNum(n / 1000.0) & "s"      # times compute to s
        elif lu == "s" or lu == "deg" or lu == "%" or lu == "fr" or lu == "x" or
             lu == "dppx" or lu == "turn" or lu == "rad" or lu == "grad" or
             lu == "hz" or lu == "khz" or lu == "dpi" or lu == "dpcm":
          outTok = fmtNum(n) & lu                              # canonical number
      else:
        outTok = fmtNum(n)                                     # .5 → 0.5
    if i > 0 and t != "," and toks[i-1] != "/" and t != "/":
      result.add ' '
    elif i > 0 and (t == "/" or toks[i-1] == "/"):
      result.add ' '
    result.add outTok
    inc i

proc fontSizeKeyword(k: string, parentPx: float, ok: var bool): float =
  ok = true
  case k
  of "xx-small": 9.0
  of "x-small": 10.0
  of "small": 13.0
  of "medium": 16.0
  of "large": 18.0
  of "x-large": 24.0
  of "xx-large": 32.0
  of "xxx-large": 48.0
  of "larger": parentPx * 1.2
  of "smaller": parentPx / 1.2
  else:
    ok = false
    0.0

proc pxOf(v: string, fallback: float): float =
  var n = 0.0
  var u = ""
  if parseNumPrefix(v, n, u) and lower(u) == "px": n else: fallback

# var() substitution -------------------------------------------------------------------

proc findClose(s: string, open: int): int =
  var depth = 0
  var i = open
  var q = '\0'
  while i < s.len:
    let c = s[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c == '"' or c == '\'': q = c
    elif c == '(': inc depth
    elif c == ')':
      dec depth
      if depth == 0: return i
    inc i
  -1

proc trimS(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n'): inc a
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\n'): dec b
  result = ""
  var i = a
  while i < b:
    result.add s[i]
    inc i

proc substitute(v: string, vars: Table[string, string], ok: var bool, depth: int): string =
  ## Replace every var(--x[, fallback]) using `vars` ("" = guaranteed-invalid).
  ## `ok` turns false when a reference cannot be resolved.
  result = ""
  if depth > 32:
    ok = false
    return
  var i = 0
  while i < v.len:
    let isVar = i + 3 < v.len and (v[i] == 'v' or v[i] == 'V') and
                (v[i+1] == 'a' or v[i+1] == 'A') and (v[i+2] == 'r' or v[i+2] == 'R') and
                v[i+3] == '(' and
                (i == 0 or not ((v[i-1] >= 'a' and v[i-1] <= 'z') or v[i-1] == '-'))
    if isVar:
      let close = findClose(v, i + 3)
      if close < 0:
        ok = false
        return
      var inner = ""
      var k = i + 4
      while k < close:
        inner.add v[k]
        inc k
      # split name / fallback at the first top-level comma
      var comma = -1
      var depth2 = 0
      k = 0
      while k < inner.len:
        if inner[k] == '(': inc depth2
        elif inner[k] == ')': dec depth2
        elif inner[k] == ',' and depth2 == 0 and comma < 0: comma = k
        inc k
      var name = ""
      var fb = ""
      var hasFb = false
      if comma < 0: name = trimS(inner)
      else:
        k = 0
        while k < comma:
          name.add inner[k]
          inc k
        name = trimS(name)
        k = comma + 1
        while k < inner.len:
          fb.add inner[k]
          inc k
        hasFb = true
      let val = vars.getOrDefault(name, "")
      if val.len > 0:
        result.add val
      elif hasFb:
        result.add substitute(trimS(fb), vars, ok, depth + 1)
      else:
        ok = false
      i = close + 1
    else:
      result.add v[i]
      inc i

proc resolveCustom(name: string, raw: Table[string, string], done: var Table[string, string],
                   visiting: var seq[string]): string =
  ## Resolve one custom property's value, substituting the var()s inside it.
  ## A reference cycle makes every property on it guaranteed-invalid ("").
  if done.hasKey(name): return done.getOrDefault(name, "")
  var i = 0
  while i < visiting.len:
    if visiting[i] == name: return "\x00cycle"
    inc i
  let v = raw.getOrDefault(name, "")
  if not hasVar(v):
    done[name] = v
    return v
  visiting.add name
  # resolve each referenced name first
  var refs = initTable[string, string]()
  var k = 0
  while k + 5 < v.len:
    if v[k] == '-' and v[k+1] == '-' and k >= 1:
      var n = ""
      var j = k
      while j < v.len and v[j] != ',' and v[j] != ')' and v[j] != ' ':
        n.add v[j]
        inc j
      let rv = resolveCustom(n, raw, done, visiting)
      if rv == "\x00cycle":
        refs[n] = ""
        done[n] = ""
      else:
        refs[n] = rv
      k = j
    else:
      inc k
  var kept: seq[string] = @[]
  i = 0
  while i < visiting.len:
    if visiting[i] != name: kept.add visiting[i]
    inc i
  visiting = kept
  var ok = true
  let s = substitute(v, refs, ok, 0)
  let res = (if ok: s else: "")
  done[name] = res
  res

# --- the public entry points ------------------------------------------------------------

proc registeredOf(e: StyleEngine, name: string): tuple[found: bool, r: Registered] =
  var i = e.registered.len - 1
  while i >= 0:
    if e.registered[i].name == name: return (true, e.registered[i])
    dec i
  (false, Registered())

proc get*(cs: ComputedStyle, prop: string): string

var colorProps = initTable[string, bool]()

proc isColorProp*(p: string): bool =
  ## Does the property take a single colour (color, border-top-color, fill…)?
  if colorProps.hasKey(p): return colorProps.getOrDefault(p, false)
  let syn = propertySyntax(p)
  var r = syn == "<color>" or syn == "<color> | auto" or syn == "auto | <color>" or
          p == "color" or p == "background-color" or p == "outline-color"
  if not r and syn.len > 0:
    # e.g. "<'border-top-color'>" style references
    var i = 0
    var body = ""
    while i < syn.len:
      if syn[i] != '<' and syn[i] != '>' and syn[i] != '\'': body.add syn[i]
      inc i
    if body != p and (body == "color" or (body.len > 6 and isColorProp(body))): r = true
  colorProps[p] = r
  r

proc getLonghand(cs: ComputedStyle, p: string): string =
  var v = ""
  if cs.values.hasKey(p):
    v = cs.values.getOrDefault(p, "")
  elif isCustom(p):
    return ""
  else:
    let wm = (if cs.values.hasKey("writing-mode"): cs.values.getOrDefault("writing-mode", "") else: "horizontal-tb")
    let dir = (if cs.values.hasKey("direction"): cs.values.getOrDefault("direction", "") else: "ltr")
    let ph = physicalOf(p, wm, dir)
    if ph != p: return getLonghand(cs, ph)
    v = initialValue(p)
    if p == "color" and v.len > 0: v = normalizeColor(v)
  # the resolved value, as getComputedStyle reports it: currentcolor → colour
  if p != "color" and v.len > 0 and (v[0] == 'c' or v[0] == 'C') and
     lower(v) == "currentcolor" and isColorProp(p):
    return getLonghand(cs, "color")
  if v.len > 0 and isColorProp(p): v = normalizeColor(v)
  v

proc get*(cs: ComputedStyle, prop: string): string =
  ## The computed value of `prop`: set/inherited, or else its initial value.
  ## A logical property answers with its physical counterpart's value; a
  ## shorthand answers when all its longhands agree (`margin` → "0").
  let p = (if isCustom(prop): prop else: lower(prop))
  if isCustom(p) or cs.values.hasKey(p) or not isShorthand(p) and
     p != "overflow" and p != "gap" and p != "inset":
    return getLonghand(cs, p)
  let names = shorthandLonghands(p)
  if names.len == 0: return getLonghand(cs, p)
  let first = getLonghand(cs, names[0])
  var i = 1
  while i < names.len:
    if getLonghand(cs, names[i]) != first: return ""
    inc i
  first

proc has*(cs: ComputedStyle, prop: string): bool =
  ## Was `prop` set on, or inherited by, this element (vs. initial)?
  cs.values.hasKey(if isCustom(prop): prop else: lower(prop))

proc isWideKw(v: string): bool =
  let l = lower(trimS(v))
  l == "inherit" or l == "initial" or l == "unset" or l == "revert" or l == "revert-layer"

proc computeOne(e: StyleEngine, el: Element, pseudo: string, parent: ComputedStyle,
                hasParent: bool, rootFontPx: float): ComputedStyle =
  var cs = ComputedStyle(values: initTable[string, string]())
  let rawCands = collect(e, el, pseudo)
  # writing-mode / direction first: they decide what the logical properties mean
  var wm = (if hasParent: parent.get("writing-mode") else: "horizontal-tb")
  var dir = (if hasParent: parent.get("direction") else: "ltr")
  let wmW = winner(rawCands.getOrDefault("writing-mode", @[]), oAuthor, 0, false)
  if wmW.found and not isWideKw(wmW.c.value): wm = lower(trimS(wmW.c.value))
  let dirW = winner(rawCands.getOrDefault("direction", @[]), oAuthor, 0, false)
  if dirW.found and not isWideKw(dirW.c.value): dir = lower(trimS(dirW.c.value))
  var cands = initTable[string, seq[Candidate]]()
  for k, list in rawCands.pairs:
    let ph = (if isCustom(k): k else: physicalOf(k, wm, dir))
    var s2 = cands.getOrDefault(ph, @[])
    var i = 0
    while i < list.len:
      var c = list[i]
      if ph != k and c.fromShorthand.len > 0:
        c.fromShorthand = c.fromShorthand & "\x02" & k   # remember the logical name
      s2.add c
      inc i
    cands[ph] = s2
  # 1. inherited properties flow in from the parent
  if hasParent:
    for k, v in parent.values.pairs:
      if isCustom(k):
        let reg = registeredOf(e, k)
        if not reg.found or reg.r.inherits: cs.values[k] = v
      elif isInherited(k):
        cs.values[k] = v
  # 2. custom properties
  var rawCustom = initTable[string, string]()
  for k, v in cs.values.pairs:
    if isCustom(k): rawCustom[k] = v
  for i in 0 ..< e.registered.len:
    let r = e.registered[i]
    if not rawCustom.hasKey(r.name) and r.initial.len > 0: rawCustom[r.name] = r.initial
  for k, list in cands.pairs:
    if isCustom(k):
      let w = winner(list, oAuthor, 0, false)
      if w.found:
        let l = lower(trimS(w.c.value))
        if l == "initial":
          let reg = registeredOf(e, k)
          rawCustom[k] = (if reg.found: reg.r.initial else: "")
        elif l == "inherit" or l == "unset" or l == "revert" or l == "revert-layer":
          rawCustom[k] = (if hasParent: parent.values.getOrDefault(k, "") else: "")
        else:
          rawCustom[k] = w.c.value
  var done = initTable[string, string]()
  var visiting: seq[string] = @[]
  var names: seq[string] = @[]
  for k, _ in rawCustom.pairs: names.add k
  var vars = initTable[string, string]()
  for n in names:
    var r = resolveCustom(n, rawCustom, done, visiting)
    if r == "\x00cycle": r = ""
    let reg = registeredOf(e, n)
    if reg.found and reg.r.syntax != "*" and r.len > 0 and not matchesSyntax(reg.r.syntax, r):
      r = reg.r.initial          # invalid at computed-value time → initial
    if r.len > 0:
      vars[n] = r
      cs.values[n] = r
    elif cs.values.hasKey(n):
      cs.values.del(n)
  # 3. every other property with a cascaded value
  let parentFont = (if hasParent: pxOf(parent.get("font-size"), 16.0) else: 16.0)
  var order: seq[string] = @[]
  if cands.hasKey("font-size"): order.add "font-size"
  for k, _ in cands.pairs:
    if not isCustom(k) and k != "font-size": order.add k
  var fontPx = parentFont
  for p in order:
    let list = cands.getOrDefault(p, @[])
    let w = winner(list, oAuthor, 0, false)
    if not w.found: continue
    var v = w.c.value
    var chosen = w.c
    # revert / revert-layer roll back to an earlier origin / layer
    var guard = 0
    while guard < 4 and (lower(trimS(v)) == "revert" or lower(trimS(v)) == "revert-layer"):
      var w2: tuple[found: bool, c: Candidate]
      if lower(trimS(v)) == "revert":
        if chosen.origin == oUserAgent: w2 = (false, Candidate())
        else: w2 = winner(list, Origin(ord(chosen.origin) - 1), 0, false)
      else:
        w2 = winner(list, chosen.origin, chosen.layer, true)
      if w2.found:
        chosen = w2.c
        v = w2.c.value
      else:
        v = "unset"
      inc guard
    # a var()-holding shorthand: substitute, expand, take our longhand
    if chosen.fromShorthand.len > 0:
      var sh = ""
      var want = p
      var k = 0
      var second = false
      var logical = ""
      while k < chosen.fromShorthand.len:
        if chosen.fromShorthand[k] == '\x02': second = true
        elif second: logical.add chosen.fromShorthand[k]
        else: sh.add chosen.fromShorthand[k]
        inc k
      if logical.len > 0: want = logical
      var ok = true
      let sv = substitute(v, vars, ok, 0)
      if not ok:
        v = "unset"
      else:
        let x = expandCached(e, sh, sv)
        v = "unset"
        if x.ok:
          k = 0
          while k < x.longhands.len:
            if x.longhands[k].name == want: v = x.longhands[k].value
            inc k
    elif hasVar(v):
      var ok = true
      let sv = substitute(v, vars, ok, 0)
      v = (if ok and validCached(e, p, sv): sv else: "unset")
    let l = lower(trimS(v))
    if l == "unset": v = (if isInherited(p): "inherit" else: "initial")
    let l2 = lower(trimS(v))
    if l2 == "inherit":
      if hasParent and parent.values.hasKey(p): cs.values[p] = parent.values.getOrDefault(p, "")
      else:
        let iv = initialValue(p)
        if p == "font-size": cs.values[p] = "16px"
        elif iv.len > 0: cs.values[p] = iv
        elif cs.values.hasKey(p): cs.values.del(p)
      if p == "font-size": fontPx = pxOf(cs.values.getOrDefault(p, "16px"), parentFont)
      continue
    if l2 == "initial":
      if p == "font-size":
        cs.values[p] = "16px"
        fontPx = 16.0
      elif cs.values.hasKey(p) and not isInherited(p):
        cs.values.del(p)
      else:
        let iv = initialValue(p)
        if iv.len > 0: cs.values[p] = iv
        elif cs.values.hasKey(p): cs.values.del(p)
      continue
    # absolute lengths
    if p == "font-size":
      var ok = false
      let kw = fontSizeKeyword(l2, parentFont, ok)
      if ok:
        fontPx = kw
        cs.values[p] = fmtNum(kw) & "px"
      else:
        let a = absolutize(v, LenCtx(fontPx: parentFont, parentFontPx: parentFont,
                                     rootFontPx: rootFontPx, env: e.env, forFontSize: true))
        cs.values[p] = a
        fontPx = pxOf(a, parentFont)
    else:
      cs.values[p] = absolutize(v, LenCtx(fontPx: fontPx, parentFontPx: parentFont,
                                          rootFontPx: rootFontPx, env: e.env, forFontSize: false))
  # colours: the legacy sRGB forms compute to rgb()/rgba(); `color:
  # currentcolor` means the inherited colour
  var fixes: seq[tuple[k, v: string]] = @[]
  for k, v in cs.values.pairs:
    if not isCustom(k) and isColorProp(k):
      if k == "color" and lower(trimS(v)) == "currentcolor":
        fixes.add (k: k, v: (if hasParent: parent.get("color") else: "rgb(0, 0, 0)"))
      else:
        let n = normalizeColor(v)
        if n != v: fixes.add (k: k, v: n)
  for f in fixes: cs.values[f.k] = f.v
  cs

proc ancestorsTopDown(el: Element): seq[Element] =
  var chain: seq[Element] = @[]
  var x = el
  while true:
    chain.add x
    let p = x.parent
    if p == nil: break
    x = p
  result = @[]
  var i = chain.len - 1
  while i >= 0:
    result.add chain[i]
    dec i

proc computedStyle*(e: StyleEngine, el: Element, pseudo = ""): ComputedStyle =
  ## The computed style of `el` (or of its `::pseudo` part: "before", "after",
  ## "marker", …), computing its ancestors first for inheritance.
  e.mediaCache.clear()
  let chain = ancestorsTopDown(el)
  var parent = ComputedStyle(values: initTable[string, string]())
  var hasParent = false
  var rootFont = 16.0
  var i = 0
  while i < chain.len:
    let isTarget = i == chain.len - 1
    if isTarget and pseudo.len > 0:
      # the element itself first, then its pseudo-element inherits from it
      let own = computeOne(e, chain[i], "", parent, hasParent, rootFont)
      return computeOne(e, chain[i], lower(pseudo), own, true, rootFont)
    let cs = computeOne(e, chain[i], "", parent, hasParent, rootFont)
    if i == 0: rootFont = pxOf(cs.get("font-size"), 16.0)
    if isTarget: return cs
    parent = cs
    hasParent = true
    inc i
  parent

proc describe(e: StyleEngine, c: Candidate): string =
  var where = ""
  if c.ruleIdx < 0: where = "style attribute"
  else:
    let r = e.rules[c.ruleIdx]
    where = r.selectorText & (if r.source.len > 0: " (" & r.source & ":" & $c.line & ")"
                              else: " (line " & $c.line & ")")
    if r.layerName.len > 0 and r.layerName[0] != '\x01': where.add " @layer " & r.layerName
    if r.media.len > 0: where.add " @media " & r.media[r.media.len-1]
  var o = "author"
  if c.origin == oUserAgent: o = "user-agent"
  elif c.origin == oUser: o = "user"
  c.value & (if c.important: " !important" else: "") & "  from " & where &
    "  [" & o & ", specificity " & $c.spec & "]"

proc why*(e: StyleEngine, el: Element, prop: string, pseudo = ""): string =
  ## Explain the cascaded value of `prop` on `el`: the winning declaration,
  ## where it came from, and what it beat.
  let p = (if isCustom(prop): prop else: lower(prop))
  e.mediaCache.clear()
  let cands = collect(e, el, lower(pseudo))
  let list = cands.getOrDefault(p, @[])
  if list.len == 0:
    return p & ": no declaration applies — " &
      (if isInherited(p): "inherited from the parent" else: "initial value " & initialValue(p))
  let w = winner(list, oAuthor, 0, false)
  result = p & ": " & describe(e, w.c)
  var i = 0
  var others = 0
  while i < list.len:
    if list[i].order != w.c.order or list[i].ruleIdx != w.c.ruleIdx:
      if others < 5: result.add "\n  beats " & describe(e, list[i])
      inc others
    inc i

proc computeTreeInto(e: StyleEngine, el: Element, parent: ComputedStyle, hasParent: bool,
                     rootFont: float, dest: var seq[tuple[el: Element, style: ComputedStyle]]) =
  let cs = computeOne(e, el, "", parent, hasParent, rootFont)
  let rf = (if hasParent: rootFont else: pxOf(cs.get("font-size"), 16.0))
  dest.add (el: el, style: cs)
  var i = 0
  while i < el.children.len:
    computeTreeInto(e, el.children[i], cs, true, rf, dest)
    inc i

proc computeTree*(e: StyleEngine, root: Element): seq[tuple[el: Element, style: ComputedStyle]] =
  ## The computed style of `root` and every descendant, in document order —
  ## each element computed once, from its already-computed parent.
  result = @[]
  e.mediaCache.clear()
  computeTreeInto(e, root, ComputedStyle(values: initTable[string, string]()), false, 16.0, result)
