## lint.nim — validate a WHOLE stylesheet, in context, with line numbers.
##
## `validateValue` answers "is this value right for this property?" and
## `validateSelector` "is this a selector?". A stylesheet needs more than the
## two glued together, because what a block may contain depends on WHERE it is:
##
##   style rule        properties; nested style rules (relative selectors, `&`)
##                     and nested conditional group rules (CSS Nesting)
##   @media/@supports/ at the top: rules; inside a style rule: properties too
##   @container/@layer/
##   @scope/@starting-style
##   @font-face        its descriptors, and it needs font-family + src
##   @keyframes        keyframe blocks (from/to/%), which hold properties but
##                     never `!important`
##   @page             properties + page descriptors + margin at-rules
##   @property         syntax/inherits/initial-value — and initial-value must
##                     parse under the declared syntax
##   @counter-style    its descriptors, with the system's requirements
##   @font-feature-values / @font-palette-values / @view-transition / …
##
## plus the ordering rules (@charset first, @import before everything but
## @charset/@layer statements, @namespace after @import), at-rules that are
## only legal at the top level, every at-rule prelude (`css/atrules`), and
## whatever the parser had to recover from (unclosed blocks, stray `}`,
## declarations without a `:`).

import parse
import validator
import selectors
import atrules
import data_load

type
  Severity* = enum
    sevError, sevWarning

  Diagnostic* = object
    line*: int             ## 1-based source line
    severity*: Severity
    message*: string
    context*: string       ## the selector / at-rule head / declaration involved

  Ctx = enum
    cxTop            ## top level of the sheet
    cxGroupTop       ## a conditional group rule's body, outside any style rule
    cxStyle          ## a style rule's body (or a group rule nested in one)
    cxFontFace
    cxKeyframes      ## @keyframes body: keyframe blocks only
    cxKeyframe       ## one keyframe block
    cxPage
    cxPageMargin
    cxDescriptors    ## a descriptor-only block (@counter-style, @property, …)
    cxFontFeatureValues
    cxFeatureBlock   ## @swash { name: 1 } …
    cxPositionTry

proc oneLine(s: string): string =
  ## Collapse runs of whitespace (a multi-line selector) to single spaces.
  result = ""
  var sp = false
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == ' ' or c == '\t' or c == '\n' or c == '\r':
      sp = result.len > 0
    else:
      if sp: result.add ' '
      sp = false
      result.add c
    inc i

proc `$`*(d: Diagnostic): string =
  $d.line & ": " & (if d.severity == sevError: "error" else: "warning") & ": " &
    d.message & (if d.context.len > 0: "   [" & oneLine(d.context) & "]" else: "")

proc add(ds: var seq[Diagnostic], line: int, sev: Severity, msg, ctx: string) =
  ds.add Diagnostic(line: line, severity: sev, message: msg, context: ctx)

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc hasPrefix(s, p: string): bool =
  if s.len < p.len: return false
  var i = 0
  while i < p.len:
    if s[i] != p[i]: return false
    inc i
  true

proc isCustomProp(p: string): bool = p.len > 2 and p[0] == '-' and p[1] == '-'

proc declText(d: Declaration): string =
  d.prop & ": " & d.value & (if d.important: " !important" else: "")

proc isConditionalGroup(kw: string): bool =
  kw == "media" or kw == "supports" or kw == "container" or kw == "layer" or
    kw == "scope" or kw == "starting-style" or kw == "document" or kw == "-moz-document"

proc isKeyframesKw(kw: string): bool =
  kw == "keyframes" or kw == "-webkit-keyframes" or kw == "-moz-keyframes" or
    kw == "-o-keyframes" or kw == "-ms-keyframes"

proc isPageMargin(kw: string): bool =
  kw == "top-left-corner" or kw == "top-left" or kw == "top-center" or
    kw == "top-right" or kw == "top-right-corner" or kw == "bottom-left-corner" or
    kw == "bottom-left" or kw == "bottom-center" or kw == "bottom-right" or
    kw == "bottom-right-corner" or kw == "left-top" or kw == "left-middle" or
    kw == "left-bottom" or kw == "right-top" or kw == "right-middle" or
    kw == "right-bottom"

proc isFeatureBlock(kw: string): bool =
  kw == "swash" or kw == "annotation" or kw == "ornaments" or kw == "stylistic" or
    kw == "styleset" or kw == "character-variant" or kw == "historical-forms"

proc isVendor(s: string): bool = s.len > 1 and s[0] == '-' and s[1] != '-'

# --- declarations ----------------------------------------------------------------

proc checkProperty(d: Declaration, ds: var seq[Diagnostic], allowImportant: bool) =
  if not allowImportant and d.important:
    ds.add d.line, sevError, "!important is not allowed here (it is ignored in keyframes)", declText(d)
  if isCustomProp(d.prop):
    if d.value.len == 0 and not d.important:
      discard                       # `--x:;` is a valid empty custom property
    return
  let r = validateValue(d.prop, d.value)
  if not r.valid:
    ds.add d.line, sevError, r.error, declText(d)

proc checkDescriptor(atRule: string, d: Declaration, ds: var seq[Diagnostic]) =
  let r = validateDescriptor(atRule, d.prop, d.value & (if d.important: " !important" else: ""))
  if not r.valid:
    ds.add d.line, sevError, r.error, declText(d)

proc findDecl(decls: seq[Declaration], name: string): int =
  result = -1
  var i = 0
  while i < decls.len:
    if lower(decls[i].prop) == name: result = i
    inc i

# --- @property -------------------------------------------------------------------

proc unquote(s: string): string =
  if s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len-1] == s[0]:
    result = ""
    var i = 1
    while i < s.len - 1:
      result.add s[i]
      inc i
  else:
    result = s

proc trimWs(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n'): inc a
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\n'): dec b
  result = ""
  var i = a
  while i < b:
    result.add s[i]
    inc i

const registeredTypes = ["angle", "color", "custom-ident", "image", "integer",
  "length", "length-percentage", "number", "percentage", "resolution", "string",
  "time", "transform-function", "transform-list", "url"]

proc checkRegisteredSyntax(syn: string): tuple[valid: bool, error: string, vds: string] =
  ## The `syntax` descriptor of @property (CSS Properties & Values): `*`, or
  ## `|`-separated components, each `<type>` (+ or # allowed) or an ident.
  ## Returns the equivalent value-definition syntax for checking initial-value.
  let s = trimWs(syn)
  if s == "*": return (true, "", "*")
  if s.len == 0: return (false, "empty syntax string", "")
  var vds = ""
  var comp = ""
  var i = 0
  while i <= s.len:
    if i == s.len or s[i] == '|':
      let c = trimWs(comp)
      if c.len == 0: return (false, "empty component in syntax '" & s & "'", "")
      var mult = ""
      var body = c
      if c[c.len-1] == '+' or c[c.len-1] == '#':
        mult = ""
        mult.add c[c.len-1]
        body = ""
        var k = 0
        while k < c.len - 1:
          body.add c[k]
          inc k
      if body.len >= 2 and body[0] == '<' and body[body.len-1] == '>':
        var name = ""
        var k = 1
        while k < body.len - 1:
          name.add body[k]
          inc k
        var known = false
        var t = 0
        while t < registeredTypes.len:
          if registeredTypes[t] == name: known = true
          inc t
        if not known: return (false, "'<" & name & ">' is not a registrable syntax type", "")
        if name == "transform-list":
          if mult.len > 0: return (false, "<transform-list> cannot take a multiplier", "")
          body = "<transform-function>"
          mult = "+"
      else:
        # a literal ident
        var k = 0
        while k < body.len:
          let ch = body[k]
          if not ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                  (ch >= '0' and ch <= '9') or ch == '-' or ch == '_'):
            return (false, "'" & body & "' is not a type or an identifier", "")
          inc k
      if vds.len > 0: vds.add " | "
      vds.add body & mult
      comp = ""
    else:
      comp.add s[i]
    inc i
  (true, "", vds)

proc hasRelativeUnit(v: string): bool =
  ## An initial-value must be computationally independent: no font- or
  ## viewport-relative lengths.
  var i = 0
  while i < v.len:
    if v[i] >= '0' and v[i] <= '9':
      var j = i
      while j < v.len and ((v[j] >= '0' and v[j] <= '9') or v[j] == '.'): inc j
      var u = ""
      while j < v.len and ((v[j] >= 'a' and v[j] <= 'z') or (v[j] >= 'A' and v[j] <= 'Z')):
        u.add v[j]
        inc j
      let l = lower(u)
      if l == "em" or l == "rem" or l == "ex" or l == "ch" or l == "lh" or
         l == "rlh" or l == "vw" or l == "vh" or l == "vmin" or l == "vmax" or
         l == "cap" or l == "ic" or l == "svw" or l == "svh" or l == "lvw" or
         l == "lvh" or l == "dvw" or l == "dvh" or l == "cqw" or l == "cqh":
        return true
      i = j
    else:
      inc i
  false

proc checkPropertyRule(r: ParsedRule, ds: var seq[Diagnostic]) =
  let si = findDecl(r.decls, "syntax")
  let ii = findDecl(r.decls, "inherits")
  let vi = findDecl(r.decls, "initial-value")
  if si < 0: ds.add r.line, sevError, "@property requires a 'syntax' descriptor", r.prelude
  if ii < 0: ds.add r.line, sevError, "@property requires an 'inherits' descriptor", r.prelude
  if si < 0: return
  let synDecl = r.decls[si]
  let rs = checkRegisteredSyntax(unquote(synDecl.value))
  if not rs.valid:
    ds.add synDecl.line, sevError, rs.error, declText(synDecl)
    return
  if rs.vds != "*" and vi < 0:
    ds.add r.line, sevError, "@property with a syntax other than \"*\" requires 'initial-value'", r.prelude
  if vi >= 0 and rs.vds != "*":
    let iv = r.decls[vi]
    let m = validateAgainst(rs.vds, iv.value)
    if not m.valid:
      ds.add iv.line, sevError, "initial-value does not match syntax " & synDecl.value & ": " & m.error, declText(iv)
    elif hasRelativeUnit(iv.value):
      ds.add iv.line, sevError, "initial-value must be computationally independent (no em/rem/vw…)", declText(iv)

# --- @counter-style ------------------------------------------------------------------

proc countWords(v: string): int =
  ## Rough count of <symbol>s: strings, idents, images.
  result = 0
  var i = 0
  var inTok = false
  var q = '\0'
  var depth = 0
  while i < v.len:
    let c = v[i]
    if q != '\0':
      if c == q: q = '\0'
    elif c == '"' or c == '\'':
      if not inTok and depth == 0: inc result
      q = c
      inTok = true
    elif c == '(':
      inc depth
    elif c == ')':
      if depth > 0: dec depth
    elif c == ' ' or c == '\t' or c == '\n':
      if depth == 0: inTok = false
    else:
      if not inTok and depth == 0: inc result
      inTok = true
    inc i

proc checkCounterStyle(r: ParsedRule, ds: var seq[Diagnostic]) =
  let sy = findDecl(r.decls, "system")
  var system = "symbolic"
  if sy >= 0:
    var w = ""
    var i = 0
    let v = lower(trimWs(r.decls[sy].value))
    while i < v.len and v[i] != ' ':
      w.add v[i]
      inc i
    system = w
  let syms = findDecl(r.decls, "symbols")
  let adds = findDecl(r.decls, "additive-symbols")
  if system == "extends":
    if syms >= 0 or adds >= 0:
      ds.add r.line, sevError, "an 'extends' counter style cannot define symbols", r.prelude
    return
  if system == "additive":
    if adds < 0: ds.add r.line, sevError, "system: additive requires 'additive-symbols'", r.prelude
    return
  if syms < 0:
    ds.add r.line, sevError, "system: " & system & " requires 'symbols'", r.prelude
  elif (system == "alphabetic" or system == "numeric") and countWords(r.decls[syms].value) < 2:
    ds.add r.decls[syms].line, sevError, "system: " & system & " needs at least two symbols", declText(r.decls[syms])

# --- the walk ---------------------------------------------------------------------------

proc walk(rules: seq[ParsedRule], decls: seq[Declaration], ctx: Ctx, atRule: string,
          ds: var seq[Diagnostic])

proc checkDecls(decls: seq[Declaration], ctx: Ctx, atRule: string, ds: var seq[Diagnostic]) =
  var i = 0
  while i < decls.len:
    let d = decls[i]
    case ctx
    of cxTop, cxGroupTop, cxKeyframes, cxFontFeatureValues:
      ds.add d.line, sevError, "a declaration is not allowed here", declText(d)
    of cxStyle, cxPageMargin, cxPositionTry:
      checkProperty(d, ds, true)
    of cxKeyframe:
      checkProperty(d, ds, false)
      let l = lower(d.prop)
      if (l == "animation" or hasPrefix(l, "animation-")) and
         l != "animation-timing-function" and l != "animation-composition":
        ds.add d.line, sevWarning, "'" & d.prop & "' is ignored inside a keyframe", declText(d)
    of cxFontFace:
      checkDescriptor("@font-face", d, ds)
    of cxPage:
      if isDescriptor("@page", lower(d.prop)): checkDescriptor("@page", d, ds)
      else: checkProperty(d, ds, true)
    of cxDescriptors:
      checkDescriptor(atRule, d, ds)
    of cxFeatureBlock:
      let r = validateAgainst("<integer [0,∞]>+", d.value)
      if not r.valid:
        ds.add d.line, sevError, "a feature value is one or more non-negative integers", declText(d)
    inc i

proc walkRule(r: ParsedRule, ctx: Ctx, atRule: string, ds: var seq[Diagnostic]) =
  if not r.isAtRule:
    # a style rule / keyframe block
    if ctx == cxKeyframes:
      let k = validateKeyframeSelector(r.prelude)
      if not k.valid: ds.add r.line, sevError, k.error, r.prelude
      walk(r.children, r.decls, cxKeyframe, "", ds)
      if r.children.len > 0:
        ds.add r.children[0].line, sevError, "rules are not allowed inside a keyframe", r.prelude
      return
    if ctx == cxStyle:
      let s = validateNestedSelector(r.prelude)
      if not s.valid: ds.add r.line, sevError, s.error, r.prelude
    elif ctx == cxTop or ctx == cxGroupTop:
      let s = validateSelector(r.prelude)
      if not s.valid: ds.add r.line, sevError, s.error, r.prelude
    else:
      ds.add r.line, sevError, "a style rule is not allowed here", r.prelude
      return
    walk(r.children, r.decls, cxStyle, "", ds)
    return
  let kw = lower(r.atKeyword)
  # where may this at-rule appear?
  if (kw == "charset" or kw == "import" or kw == "namespace") and ctx != cxTop:
    ds.add r.line, sevError, "@" & kw & " is only allowed at the top level", r.prelude
  if isPageMargin(kw) and ctx != cxPage:
    ds.add r.line, sevError, "@" & kw & " is only allowed inside @page", r.prelude
  if isFeatureBlock(kw) and ctx != cxFontFeatureValues:
    ds.add r.line, sevError, "@" & kw & " is only allowed inside @font-feature-values", r.prelude
  if ctx == cxKeyframes or ctx == cxKeyframe or ctx == cxFontFace or ctx == cxDescriptors or
     ctx == cxFeatureBlock or ctx == cxPageMargin:
    ds.add r.line, sevError, "@" & kw & " is not allowed here", r.prelude
    return
  let p = validateAtRulePrelude(kw, r.atPrelude, r.hasBlock)
  if not p.valid:
    ds.add r.line, sevError, p.error, r.prelude
  if not r.hasBlock: return
  if isConditionalGroup(kw):
    walk(r.children, r.decls, (if ctx == cxStyle: cxStyle else: cxGroupTop), "", ds)
  elif isKeyframesKw(kw):
    walk(r.children, r.decls, cxKeyframes, "", ds)
  elif kw == "font-face":
    walk(r.children, r.decls, cxFontFace, "@font-face", ds)
    if findDecl(r.decls, "font-family") < 0:
      ds.add r.line, sevError, "@font-face requires a 'font-family' descriptor", r.prelude
    if findDecl(r.decls, "src") < 0:
      ds.add r.line, sevError, "@font-face requires a 'src' descriptor", r.prelude
  elif kw == "page":
    walk(r.children, r.decls, cxPage, "@page", ds)
  elif isPageMargin(kw):
    walk(r.children, r.decls, cxPageMargin, "", ds)
  elif kw == "property":
    walk(r.children, r.decls, cxDescriptors, "@property", ds)
    checkPropertyRule(r, ds)
  elif kw == "counter-style":
    walk(r.children, r.decls, cxDescriptors, "@counter-style", ds)
    checkCounterStyle(r, ds)
  elif kw == "font-palette-values" or kw == "view-transition":
    walk(r.children, r.decls, cxDescriptors, "@" & kw, ds)
  elif kw == "font-feature-values":
    # font-display is its one descriptor; the rest are feature blocks
    var i = 0
    while i < r.decls.len:
      let d = r.decls[i]
      if lower(d.prop) != "font-display":
        ds.add d.line, sevError, "only font-display is allowed directly in @font-feature-values", declText(d)
      elif not validateAgainst("auto | block | swap | fallback | optional", d.value).valid:
        ds.add d.line, sevError, "invalid font-display value", declText(d)
      inc i
    walk(r.children, @[], cxFontFeatureValues, "", ds)
  elif isFeatureBlock(kw):
    walk(r.children, r.decls, cxFeatureBlock, "", ds)
  elif kw == "position-try":
    walk(r.children, r.decls, cxPositionTry, "", ds)
  else:
    discard                           # vendor / obsolete: contents not checked

proc walk(rules: seq[ParsedRule], decls: seq[Declaration], ctx: Ctx, atRule: string,
          ds: var seq[Diagnostic]) =
  checkDecls(decls, ctx, atRule, ds)
  var i = 0
  while i < rules.len:
    walkRule(rules[i], ctx, atRule, ds)
    inc i

proc checkOrder(sheet: ParsedSheet, ds: var seq[Diagnostic]) =
  ## @charset first; @import only after @charset/@layer statements;
  ## @namespace only after @charset/@import/@layer statements.
  var seenOther = false      # anything but @charset / @import / @layer-statement / @namespace
  var seenNamespace = false
  var i = 0
  while i < sheet.rules.len:
    let r = sheet.rules[i]
    let kw = lower(r.atKeyword)
    if r.isAtRule and kw == "charset":
      if i != 0:
        ds.add r.line, sevError, "@charset must be the very first thing in the stylesheet", r.prelude
    elif r.isAtRule and kw == "import":
      if seenOther or seenNamespace:
        ds.add r.line, sevError, "@import must come before all other rules (except @charset and @layer statements); this one is ignored", r.prelude
    elif r.isAtRule and kw == "layer" and not r.hasBlock:
      discard
    elif r.isAtRule and kw == "namespace":
      if seenOther:
        ds.add r.line, sevError, "@namespace must come before all rules other than @charset, @import and @layer statements", r.prelude
      seenNamespace = true
    else:
      seenOther = true
    inc i

proc lintSheet*(sheet: ParsedSheet): seq[Diagnostic] =
  ## Every problem in an already-parsed sheet, in source order.
  result = @[]
  var i = 0
  while i < sheet.problems.len:
    result.add sheet.problems[i].line, sevError, sheet.problems[i].message, ""
    inc i
  checkOrder(sheet, result)
  walk(sheet.rules, @[], cxTop, "", result)
  # stable sort by line (insertion sort: diagnostics are few and nearly sorted)
  var a = 1
  while a < result.len:
    let x = result[a]
    var b = a - 1
    while b >= 0 and result[b].line > x.line:
      let moved = result[b]
      result[b + 1] = moved
      dec b
    result[b + 1] = x
    inc a

proc lintStylesheet*(src: string): seq[Diagnostic] =
  ## Parse `src` and report every problem, in source order. An empty result
  ## means the stylesheet is valid against the MDN grammars and the CSS
  ## rules above.
  lintSheet(parseStylesheet(src))

proc errorCount*(ds: seq[Diagnostic]): int =
  result = 0
  var i = 0
  while i < ds.len:
    if ds[i].severity == sevError: inc result
    inc i
