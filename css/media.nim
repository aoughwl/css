## media.nim — EVALUATE media queries and feature queries.
##
## `css/atrules` says whether `@media (min-width: 600px)` is well formed; this
## module says whether it is TRUE for a given environment:
##
##   var env = defaultEnv()          # screen, 1280×720, light, 1dppx
##   env.width = 375
##   evalMediaQueryList("(max-width: 600px) and (hover: none)", env)  # …
##   evalSupports("(display: grid) and selector(:has(a))")            # true
##
## An ill-formed query is false (the spec turns it into `not all`); an unknown
## feature is false. Lengths are resolved with `em`/`rem` = the environment's
## initial font size, as media queries require. `@supports` is answered by this
## library's own validator: a declaration is "supported" when its property is
## known and its value matches the MDN grammar.

import validator
import selectors
import atrules

type
  MediaEnv* = object
    mediaType*: string          ## "screen" | "print" | …
    width*, height*: float      ## viewport, CSS px
    resolution*: float          ## device pixels per CSS px (dppx)
    fontSize*: float            ## initial font size (px) for em/rem in queries
    colorScheme*: string        ## "light" | "dark"
    reducedMotion*: bool
    reducedTransparency*: bool
    contrast*: string           ## "no-preference" | "more" | "less" | "custom"
    forcedColors*: bool
    hover*: bool                ## primary pointer can hover
    pointer*: string            ## "none" | "coarse" | "fine"
    colorBits*: int             ## bits per colour component
    colorGamut*: string         ## "srgb" | "p3" | "rec2020"
    displayMode*: string        ## "browser" | "standalone" | …
    scripting*: string          ## "enabled" | "initial-only" | "none"
    dynamicRange*: string       ## "standard" | "high"

proc defaultEnv*(): MediaEnv =
  ## A desktop browser window: screen, 1280×720 CSS px at 1dppx, light mode,
  ## fine hovering pointer, 8-bit sRGB, 16px initial font.
  MediaEnv(mediaType: "screen", width: 1280.0, height: 720.0, resolution: 1.0,
           fontSize: 16.0, colorScheme: "light", reducedMotion: false,
           reducedTransparency: false, contrast: "no-preference",
           forcedColors: false, hover: true, pointer: "fine", colorBits: 8,
           colorGamut: "srgb", displayMode: "browser", scripting: "enabled",
           dynamicRange: "standard")

# --- tiny scanner --------------------------------------------------------------

type Sc = object
  s: string
  pos: int
  bad: bool

proc cur(t: Sc): char = (if t.pos < t.s.len: t.s[t.pos] else: '\0')
proc atEnd(t: Sc): bool = t.pos >= t.s.len
proc isWs(c: char): bool = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'
proc isIdC(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
    c == '-' or c == '_'

proc skipWs(t: var Sc) =
  while not atEnd(t):
    if isWs(cur(t)): inc t.pos
    elif cur(t) == '/' and t.pos + 1 < t.s.len and t.s[t.pos+1] == '*':
      t.pos = t.pos + 2
      while t.pos + 1 < t.s.len and not (t.s[t.pos] == '*' and t.s[t.pos+1] == '/'): inc t.pos
      t.pos = t.pos + 2
    else: break

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc word(t: var Sc): string =
  result = ""
  if not atEnd(t) and cur(t) == '-' and t.pos + 1 < t.s.len and t.s[t.pos+1] >= '0' and t.s[t.pos+1] <= '9':
    return
  while not atEnd(t) and isIdC(cur(t)):
    result.add cur(t)
    inc t.pos
  result = lower(result)

proc closeAt(t: Sc, open: int): int =
  var depth = 0
  var i = open
  var q = '\0'
  while i < t.s.len:
    let c = t.s[i]
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

proc sub(s: string, a, b: int): string =
  result = ""
  var i = a
  while i < b and i < s.len:
    if i >= 0: result.add s[i]
    inc i

proc trimmed(s: string): string =
  var a = 0
  var b = s.len
  while a < b and isWs(s[a]): inc a
  while b > a and isWs(s[b-1]): dec b
  sub(s, a, b)

# --- values ----------------------------------------------------------------------

proc parseNum(s: string, ok: var bool): float =
  ## A leading CSS number; `ok` false if none.
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
  ok = digits > 0
  if neg: -r else: r

proc unitOf(s: string): string =
  var i = 0
  while i < s.len and ((s[i] >= '0' and s[i] <= '9') or s[i] == '.' or s[i] == '-' or s[i] == '+'):
    inc i
  lower(sub(s, i, s.len))

proc lengthPx(v: string, env: MediaEnv, ok: var bool): float =
  let t = trimmed(v)
  let n = parseNum(t, ok)
  if not ok: return 0.0
  let u = unitOf(t)
  if u == "" and n != 0.0:
    ok = false
    return 0.0
  case u
  of "px", "": n
  of "em", "rem": n * env.fontSize
  of "ex", "ch": n * env.fontSize * 0.5
  of "in": n * 96.0
  of "cm": n * 96.0 / 2.54
  of "mm": n * 96.0 / 25.4
  of "q": n * 96.0 / 101.6
  of "pt": n * 96.0 / 72.0
  of "pc": n * 16.0
  of "vw": n * env.width / 100.0
  of "vh": n * env.height / 100.0
  of "vmin": n * (if env.width < env.height: env.width else: env.height) / 100.0
  of "vmax": n * (if env.width > env.height: env.width else: env.height) / 100.0
  else:
    ok = false
    0.0

proc ratioOf(v: string, ok: var bool): float =
  var slash = -1
  var i = 0
  while i < v.len:
    if v[i] == '/': slash = i
    inc i
  if slash < 0: return parseNum(trimmed(v), ok)
  var ok2 = false
  let a = parseNum(trimmed(sub(v, 0, slash)), ok)
  let b = parseNum(trimmed(sub(v, slash + 1, v.len)), ok2)
  ok = ok and ok2 and b != 0.0
  if ok: a / b else: 0.0

proc resolutionOf(v: string, ok: var bool): float =
  let t = trimmed(v)
  if lower(t) == "infinite":
    ok = true
    return 1.0e300
  let n = parseNum(t, ok)
  if not ok: return 0.0
  case unitOf(t)
  of "dppx", "x": n
  of "dpi": n / 96.0
  of "dpcm": n * 2.54 / 96.0
  else:
    ok = false
    0.0

# --- features -----------------------------------------------------------------------

type FKind = enum fkLength, fkRatio, fkRes, fkInt, fkKeyword, fkUnknown

proc featureKind(name: string): FKind =
  case name
  of "width", "height", "device-width", "device-height": fkLength
  of "aspect-ratio", "device-aspect-ratio": fkRatio
  of "resolution": fkRes
  of "device-pixel-ratio": fkInt       # Compat: -webkit-device-pixel-ratio
  of "color", "color-index", "monochrome", "grid",
     "horizontal-viewport-segments", "vertical-viewport-segments": fkInt
  of "orientation", "scan", "update", "overflow-block", "overflow-inline",
     "color-gamut", "video-color-gamut", "pointer", "any-pointer", "hover",
     "any-hover", "prefers-reduced-motion", "prefers-reduced-transparency",
     "prefers-reduced-data", "prefers-contrast", "prefers-color-scheme",
     "forced-colors", "inverted-colors", "dynamic-range", "video-dynamic-range",
     "display-mode", "scripting", "environment-blending", "nav-controls",
     "device-posture": fkKeyword
  else: fkUnknown

proc numericFeature(name: string, env: MediaEnv): float =
  case name
  of "width", "device-width": env.width
  of "height", "device-height": env.height
  of "aspect-ratio", "device-aspect-ratio": (if env.height > 0.0: env.width / env.height else: 0.0)
  of "resolution", "device-pixel-ratio": env.resolution
  of "color": float(env.colorBits)
  of "color-index", "monochrome", "grid": 0.0
  of "horizontal-viewport-segments", "vertical-viewport-segments": 1.0
  else: 0.0

proc keywordFeature(name: string, env: MediaEnv): string =
  case name
  of "orientation": (if env.height >= env.width: "portrait" else: "landscape")
  of "scan": "progressive"
  of "update": (if env.mediaType == "print": "none" else: "fast")
  of "overflow-block": (if env.mediaType == "print": "paged" else: "scroll")
  of "overflow-inline": (if env.mediaType == "print": "none" else: "scroll")
  of "color-gamut", "video-color-gamut": env.colorGamut
  of "pointer", "any-pointer": env.pointer
  of "hover", "any-hover": (if env.hover: "hover" else: "none")
  of "prefers-reduced-motion": (if env.reducedMotion: "reduce" else: "no-preference")
  of "prefers-reduced-transparency": (if env.reducedTransparency: "reduce" else: "no-preference")
  of "prefers-reduced-data": "no-preference"
  of "prefers-contrast": env.contrast
  of "prefers-color-scheme": env.colorScheme
  of "forced-colors": (if env.forcedColors: "active" else: "none")
  of "inverted-colors": "none"
  of "dynamic-range", "video-dynamic-range": env.dynamicRange
  of "display-mode": env.displayMode
  of "scripting": env.scripting
  of "environment-blending": "opaque"
  of "nav-controls": "back"
  of "device-posture": "continuous"
  else: ""

proc gamutRank(g: string): int =
  case g
  of "srgb": 1
  of "p3": 2
  of "rec2020": 3
  else: 0

proc valueOf(kind: FKind, v: string, env: MediaEnv, ok: var bool): float =
  case kind
  of fkLength: lengthPx(v, env, ok)
  of fkRatio: ratioOf(v, ok)
  of fkRes: resolutionOf(v, ok)
  of fkInt: parseNum(trimmed(v), ok)
  else:
    ok = false
    0.0

proc absF(x: float): float = (if x < 0.0: -x else: x)

proc compare(a: float, op: string, b: float): bool =
  case op
  of "<": a < b
  of "<=": a <= b
  of ">": a > b
  of ">=": a >= b
  else: absF(a - b) < 1e-9

proc flipOp(op: string): string =
  case op
  of "<": ">"
  of "<=": ">="
  of ">": "<"
  of ">=": "<="
  else: op

proc evalFeature(inner: string, env: MediaEnv): bool =
  ## The inside of `( … )`: boolean, plain (`name: value`) or range.
  let t = trimmed(inner)
  # find a top-level ':' (plain) or comparison operators (range)
  var colon = -1
  var hasOp = false
  var i = 0
  while i < t.len:
    if t[i] == ':' and colon < 0: colon = i
    if t[i] == '<' or t[i] == '>' or t[i] == '=': hasOp = true
    inc i
  if colon >= 0 and not hasOp:
    var name = lower(trimmed(sub(t, 0, colon)))
    let value = trimmed(sub(t, colon + 1, t.len))
    # the Compat Standard's prefixed spellings of resolution
    if name == "-webkit-device-pixel-ratio": name = "device-pixel-ratio"
    elif name == "-webkit-min-device-pixel-ratio" or name == "min--moz-device-pixel-ratio":
      name = "min-device-pixel-ratio"
    elif name == "-webkit-max-device-pixel-ratio" or name == "max--moz-device-pixel-ratio":
      name = "max-device-pixel-ratio"
    var prefix = ""
    if name.len > 4 and (sub(name, 0, 4) == "min-" or sub(name, 0, 4) == "max-"):
      prefix = sub(name, 0, 3)
      name = sub(name, 4, name.len)
    let kind = featureKind(name)
    if kind == fkUnknown: return false
    if kind == fkKeyword:
      if prefix.len > 0: return false
      let actual = keywordFeature(name, env)
      let want = lower(value)
      if name == "color-gamut" or name == "video-color-gamut":
        return gamutRank(actual) >= gamutRank(want) and gamutRank(want) > 0
      if name == "any-pointer" and want == "coarse": return false
      return actual == want
    var ok = false
    let v = valueOf(kind, value, env, ok)
    if not ok: return false
    let actual = numericFeature(name, env)
    if prefix == "min": return actual >= v - 1e-9
    if prefix == "max": return actual <= v + 1e-9
    return absF(actual - v) < 1e-9
  if not hasOp:
    # boolean context: true unless the feature's value is 0 / none
    let name = lower(t)
    let kind = featureKind(name)
    case kind
    of fkUnknown: return false
    of fkKeyword:
      let v = keywordFeature(name, env)
      return v != "none" and v != "no-preference" and v.len > 0
    else:
      return numericFeature(name, env) != 0.0
  # range: split into operands and operators
  var parts: seq[string] = @[]
  var ops: seq[string] = @[]
  var cur = ""
  i = 0
  while i < t.len:
    let c = t[i]
    if c == '<' or c == '>' or c == '=':
      parts.add trimmed(cur)
      cur = ""
      var op = ""
      op.add c
      if (c == '<' or c == '>') and i + 1 < t.len and t[i+1] == '=':
        op.add '='
        inc i
      ops.add op
    else:
      cur.add c
    inc i
  parts.add trimmed(cur)
  var nameIdx = -1
  var k = 0
  while k < parts.len:
    if featureKind(lower(parts[k])) != fkUnknown: nameIdx = k
    inc k
  if nameIdx < 0: return false
  let name = lower(parts[nameIdx])
  let kind = featureKind(name)
  if kind == fkKeyword: return false
  let actual = numericFeature(name, env)
  if parts.len == 2:
    var ok = false
    if nameIdx == 0:
      let v = valueOf(kind, parts[1], env, ok)
      return ok and compare(actual, ops[0], v)
    let v = valueOf(kind, parts[0], env, ok)
    return ok and compare(actual, flipOp(ops[0]), v)
  if parts.len == 3 and nameIdx == 1:
    var ok1 = false
    var ok2 = false
    let lo = valueOf(kind, parts[0], env, ok1)
    let hi = valueOf(kind, parts[2], env, ok2)
    return ok1 and ok2 and compare(lo, ops[0], actual) and compare(actual, ops[1], hi)
  false

# --- boolean conditions ------------------------------------------------------------

type Leaf = proc (inner: string, env: MediaEnv): bool {.nimcall.}
type FnLeaf = proc (name, args: string): bool {.nimcall.}

proc evalCondition(t: var Sc, env: MediaEnv, leaf: Leaf, fnLeaf: FnLeaf): bool

proc evalInParens(t: var Sc, env: MediaEnv, leaf: Leaf, fnLeaf: FnLeaf): bool =
  skipWs(t)
  if cur(t) == '(':
    let close = closeAt(t, t.pos)
    if close < 0:
      t.bad = true
      return false
    let inner = sub(t.s, t.pos + 1, close)
    t.pos = close + 1
    let ti = trimmed(inner)
    let l3 = lower(sub(ti, 0, 4))
    if (ti.len > 0 and ti[0] == '(') or l3 == "not " or l3 == "not(":
      var st = Sc(s: ti, pos: 0, bad: false)
      let r = evalCondition(st, env, leaf, fnLeaf)
      skipWs(st)
      if st.bad or not atEnd(st): return false
      return r
    return leaf(inner, env)
  let name = word(t)
  if name.len > 0 and cur(t) == '(':
    let close = closeAt(t, t.pos)
    if close < 0:
      t.bad = true
      return false
    let args = sub(t.s, t.pos + 1, close)
    t.pos = close + 1
    return fnLeaf(name, args)
  t.bad = true
  false

proc evalCondition(t: var Sc, env: MediaEnv, leaf: Leaf, fnLeaf: FnLeaf): bool =
  skipWs(t)
  let save = t.pos
  if word(t) == "not":
    return not evalInParens(t, env, leaf, fnLeaf)
  t.pos = save
  result = evalInParens(t, env, leaf, fnLeaf)
  var joiner = ""
  while true:
    skipWs(t)
    if atEnd(t) or cur(t) == ',': break
    let s2 = t.pos
    let w = word(t)
    if w != "and" and w != "or":
      t.pos = s2
      break
    if joiner.len > 0 and joiner != w:
      t.bad = true
      return false
    joiner = w
    let r = evalInParens(t, env, leaf, fnLeaf)
    if w == "and": result = result and r
    else: result = result or r

proc noFn(name, args: string): bool = false

proc evalMediaQuery(q: string, env: MediaEnv): bool =
  var t = Sc(s: q, pos: 0, bad: false)
  skipWs(t)
  if cur(t) == '(':
    let r = evalCondition(t, env, evalFeature, noFn)
    skipWs(t)
    return r and not t.bad and atEnd(t)
  let save = t.pos
  var negate = false
  var w = word(t)
  if w == "not":
    skipWs(t)
    if cur(t) == '(':
      t.pos = save
      let r = evalCondition(t, env, evalFeature, noFn)
      skipWs(t)
      return r and not t.bad and atEnd(t)
    negate = true
    w = word(t)
  elif w == "only":
    skipWs(t)
    w = word(t)
  if w.len == 0: return false
  var typeOk = w == "all" or w == env.mediaType
  skipWs(t)
  var condOk = true
  if not atEnd(t):
    if word(t) != "and": return false
    condOk = evalCondition(t, env, evalFeature, noFn)
    skipWs(t)
    if t.bad or not atEnd(t): return false
  let r = typeOk and condOk
  if negate: not r else: r

proc splitCommas(s: string): seq[string] =
  result = @[]
  var depth = 0
  var cur = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '(': inc depth
    elif c == ')':
      if depth > 0: dec depth
    if c == ',' and depth == 0:
      result.add cur
      cur = ""
    else:
      cur.add c
    inc i
  result.add cur

proc evalMediaQueryList*(s: string, env: MediaEnv): bool =
  ## Is the media query list true in `env`? Empty = `all` = true. An
  ## ill-formed query in the list counts as `not all` (false) without
  ## poisoning the others.
  if trimmed(s).len == 0: return true
  let qs = splitCommas(s)
  var i = 0
  while i < qs.len:
    let wf = validateMediaQueryList(qs[i])
    if wf.valid and evalMediaQuery(qs[i], env): return true
    inc i
  false

# --- @supports -------------------------------------------------------------------------

proc supportsDecl(inner: string, env: MediaEnv): bool =
  var colon = -1
  var i = 0
  while i < inner.len:
    if inner[i] == ':':
      colon = i
      break
    inc i
  if colon < 0: return false
  let prop = trimmed(sub(inner, 0, colon))
  let value = trimmed(sub(inner, colon + 1, inner.len))
  if prop.len > 2 and prop[0] == '-' and prop[1] == '-': return value.len > 0 or true
  validateValue(prop, value).valid

proc supportsFn(name, args: string): bool =
  case name
  of "selector": validateSelector(trimmed(args)).valid
  of "font-tech":
    let a = lower(trimmed(args))
    a == "color-colrv0" or a == "color-colrv1" or a == "color-svg" or
      a == "color-sbix" or a == "color-cbdt" or a == "features-opentype" or
      a == "features-aat" or a == "features-graphite" or a == "incremental" or
      a == "variations" or a == "palettes"
  of "font-format":
    let a = lower(trimmed(args))
    a == "woff2" or a == "woff" or a == "truetype" or a == "opentype" or
      a == "collection" or a == "embedded-opentype" or a == "svg"
  else: false

proc evalSupports*(s: string): bool =
  ## Is the `@supports` condition true for this engine (i.e. for the MDN data
  ## this library validates against)?
  var t = Sc(s: s, pos: 0, bad: false)
  let r = evalCondition(t, defaultEnv(), supportsDecl, supportsFn)
  skipWs(t)
  r and not t.bad and atEnd(t)
