## shorthand.nim — expand a shorthand declaration into its longhands.
##
##   expandShorthand("margin", "0 auto")
##   # -> margin-top: 0, margin-right: auto, margin-bottom: 0, margin-left: auto
##   expandShorthand("border", "1px solid red")
##   # -> border-top-width: 1px, border-top-style: solid, … (12 longhands)
##   #    plus border-image-*: their initial values (border resets them)
##   expandShorthand("font", "italic bold 12px/30px Georgia, serif")
##
## A shorthand sets EVERY one of its longhands: a part left out of the value
## resets to its initial value. The CSS-wide keywords (`inherit`, `initial`,
## …) and `var()` are the caller's business (`css/computed` substitutes var()
## first and handles the keywords on the longhands).
##
## Each shorthand has a SHAPE here — four-sided box, two-valued pair, any-order
## `||` group, comma-separated layers, slash-separated grid lines, plus the
## irregular ones (`font`, `flex`, `border-radius`, `background`, `transition`,
## `animation`). Parts are assigned by asking the validator which longhand a
## run of tokens is valid for, so the grammar knowledge stays in the MDN data.
## MDN's own longhand lists are used only as a fallback: several are wrong
## (`border-block-start` lists `color`) or missing (`overflow`).

import validator
import data_load

type Longhand* = tuple[name, value: string]

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc tail(s: string, a: int): string =
  result = ""
  var i = a
  while i < s.len:
    result.add s[i]
    inc i

proc hasSpace(s: string): bool =
  var i = 0
  while i < s.len:
    if s[i] == ' ': return true
    inc i
  false

proc isWs(c: char): bool = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'

proc components*(value: string): seq[string] =
  ## Split a value into top-level components: whitespace separates, `/` and
  ## `,` are components of their own, functions and strings stay whole.
  result = @[]
  var cur = ""
  var depth = 0
  var q = '\0'
  var i = 0
  while i < value.len:
    let c = value[i]
    if q != '\0':
      cur.add c
      if c == '\\' and i + 1 < value.len:
        cur.add value[i+1]
        inc i
      elif c == q:
        q = '\0'
    elif c == '"' or c == '\'':
      q = c
      cur.add c
    elif c == '(':
      inc depth
      cur.add c
    elif c == ')':
      if depth > 0: dec depth
      cur.add c
    elif depth == 0 and isWs(c):
      if cur.len > 0: result.add cur
      cur = ""
    elif depth == 0 and (c == '/' or c == ','):
      if cur.len > 0: result.add cur
      cur = ""
      var one = ""
      one.add c
      result.add one
    else:
      cur.add c
    inc i
  if cur.len > 0: result.add cur

proc joinRange(toks: seq[string], a, b: int): string =
  result = ""
  var i = a
  while i < b:
    if i > a and toks[i] != "," and toks[i-1] != "/" and toks[i] != "/":
      result.add ' '
    elif i > a and (toks[i] == "/" or toks[i-1] == "/"):
      result.add ' '
    result.add toks[i]
    inc i

proc splitOn(toks: seq[string], sep: string): seq[seq[string]] =
  result = @[]
  var cur: seq[string] = @[]
  var i = 0
  while i < toks.len:
    if toks[i] == sep:
      result.add cur
      cur = @[]
    else:
      cur.add toks[i]
    inc i
  result.add cur

proc initialValue*(prop: string): string =
  ## The property's initial value as CSS text, or "" when MDN only describes
  ## it in prose (`font-family: dependsOnUserAgent`). Values are re-validated,
  ## so a prose sentinel can never leak out as if it were CSS.
  let raw = rawInitialValue(prop)
  if raw.len == 0: return ""
  if validateValue(prop, raw).valid: return raw
  # MDN writes a few initials descriptively; these are the spec values
  case prop
  of "font-family": "serif"
  of "quotes": "auto"
  of "text-align": "start"
  of "color", "caret-color", "column-rule-color", "outline-color",
     "text-decoration-color", "text-emphasis-color", "border-top-color",
     "border-right-color", "border-bottom-color", "border-left-color",
     "border-block-start-color", "border-block-end-color",
     "border-inline-start-color", "border-inline-end-color": "currentcolor"
  else: ""

# --- the shapes -------------------------------------------------------------------

proc box4(names: array[4, string], toks: seq[string], dest: var seq[Longhand]): bool =
  ## top right bottom left from 1-4 values.
  for t in toks:
    if t == "/" or t == ",": return false
  var v: array[4, string]
  case toks.len
  of 1: v = [toks[0], toks[0], toks[0], toks[0]]
  of 2: v = [toks[0], toks[1], toks[0], toks[1]]
  of 3: v = [toks[0], toks[1], toks[2], toks[1]]
  of 4: v = [toks[0], toks[1], toks[2], toks[3]]
  else: return false
  var i = 0
  while i < 4:
    dest.add (name: names[i], value: v[i])
    inc i
  true

proc validFor(prop, value: string): bool =
  if value.len == 0: return false
  validateValue(prop, value).valid

proc pair(a, b: string, toks: seq[string], dest: var seq[Longhand]): bool =
  ## `A B?`: B defaults to A. The split point is found by validation, so
  ## multi-token halves (`auto 100px`) work.
  if validFor(a, joinRange(toks, 0, toks.len)) and validFor(b, joinRange(toks, 0, toks.len)):
    dest.add (name: a, value: joinRange(toks, 0, toks.len))
    dest.add (name: b, value: joinRange(toks, 0, toks.len))
    return true
  var k = toks.len - 1
  while k >= 1:
    let x = joinRange(toks, 0, k)
    let y = joinRange(toks, k, toks.len)
    if validFor(a, x) and validFor(b, y):
      dest.add (name: a, value: x)
      dest.add (name: b, value: y)
      return true
    dec k
  false

proc assignAny(toks: seq[string], pos: int, names: seq[string], used: var seq[bool],
               vals: var seq[string]): bool =
  ## Any-order `A || B || C`: give every token run to some longhand, each
  ## longhand at most once. Longest runs first; backtracks.
  if pos >= toks.len: return true
  var i = 0
  while i < names.len:
    if not used[i]:
      var j = toks.len
      while j > pos:
        let v = joinRange(toks, pos, j)
        if validFor(names[i], v):
          used[i] = true
          vals[i] = v
          if assignAny(toks, j, names, used, vals): return true
          used[i] = false
          vals[i] = ""
        dec j
    inc i
  false

proc anyOrder(names: seq[string], toks: seq[string], dest: var seq[Longhand]): bool =
  var used: seq[bool] = @[]
  var vals: seq[string] = @[]
  var i = 0
  while i < names.len:
    used.add false
    vals.add ""
    inc i
  if not assignAny(toks, 0, names, used, vals): return false
  i = 0
  while i < names.len:
    dest.add (name: names[i], value: (if used[i]: vals[i] else: initialValue(names[i])))
    inc i
  true

const sides = ["top", "right", "bottom", "left"]

proc sideNames(prefix, suffix: string): array[4, string] =
  [prefix & "top" & suffix, prefix & "right" & suffix, prefix & "bottom" & suffix,
   prefix & "left" & suffix]

proc expandInto(prop: string, toks: seq[string], dest: var seq[Longhand]): bool

proc border(toks: seq[string], dest: var seq[Longhand]): bool =
  ## `border: width || style || color` — all four sides, and border-image reset.
  var one: seq[Longhand] = @[]
  if not anyOrder(@["border-top-width", "border-top-style", "border-top-color"], toks, one):
    return false
  var s = 0
  while s < 4:
    dest.add (name: "border-" & sides[s] & "-width", value: one[0].value)
    dest.add (name: "border-" & sides[s] & "-style", value: one[1].value)
    dest.add (name: "border-" & sides[s] & "-color", value: one[2].value)
    inc s
  for n in ["border-image-source", "border-image-slice", "border-image-width",
            "border-image-outset", "border-image-repeat"]:
    dest.add (name: n, value: initialValue(n))
  true

proc radius(toks: seq[string], dest: var seq[Longhand]): bool =
  let halves = splitOn(toks, "/")
  if halves.len > 2 or halves[0].len == 0: return false
  var h: seq[Longhand] = @[]
  if not box4(["a", "b", "c", "d"], halves[0], h): return false
  var v: seq[Longhand] = @[]
  if halves.len == 2:
    if not box4(["a", "b", "c", "d"], halves[1], v): return false
  let corners = ["border-top-left-radius", "border-top-right-radius",
                 "border-bottom-right-radius", "border-bottom-left-radius"]
  var i = 0
  while i < 4:
    let hv = h[i].value
    let vv = (if v.len == 4: v[i].value else: "")
    dest.add (name: corners[i], value: (if vv.len > 0 and vv != hv: hv & " " & vv else: hv))
    inc i
  true

proc isNumberTok(t: string): bool =
  if t.len == 0: return false
  var i = 0
  if t[0] == '+' or t[0] == '-': inc i
  var digits = 0
  while i < t.len:
    if t[i] >= '0' and t[i] <= '9': inc digits
    elif t[i] != '.': return false
    inc i
  digits > 0

proc flex(toks: seq[string], dest: var seq[Longhand]): bool =
  let one = (if toks.len == 1: lower(toks[0]) else: "")
  var g = "0"
  var s = "1"
  var b = "auto"
  if one == "none":
    g = "0"; s = "0"; b = "auto"
  elif one == "auto":
    g = "1"; s = "1"; b = "auto"
  elif toks.len == 0 or toks.len > 3:
    return false
  else:
    # <grow> <shrink>? || <basis>; a grow given without a basis means 0%
    var nums: seq[string] = @[]
    var basis = ""
    var i = 0
    while i < toks.len:
      if isNumberTok(toks[i]) and nums.len < 2 and (basis.len == 0 or nums.len == 0):
        nums.add toks[i]
      elif basis.len == 0 and validFor("flex-basis", toks[i]):
        basis = toks[i]
      else:
        return false
      inc i
    if nums.len >= 1: g = nums[0]
    if nums.len >= 2: s = nums[1]
    if basis.len > 0: b = basis
    elif nums.len > 0: b = "0%"
  dest.add (name: "flex-grow", value: g)
  dest.add (name: "flex-shrink", value: s)
  dest.add (name: "flex-basis", value: b)
  true

const fontResets = ["font-size-adjust", "font-kerning", "font-optical-sizing",
  "font-variation-settings", "font-palette", "font-language-override",
  "font-variant-ligatures", "font-variant-numeric", "font-variant-east-asian",
  "font-variant-alternates", "font-variant-position", "font-variant-emoji"]

proc font(toks: seq[string], dest: var seq[Longhand]): bool =
  if toks.len == 1:
    let l = lower(toks[0])
    if l == "caption" or l == "icon" or l == "menu" or l == "message-box" or
       l == "small-caption" or l == "status-bar":
      # a system font: every longhand comes from the platform
      for n in ["font-style", "font-variant-caps", "font-weight", "font-stretch",
                "font-size", "line-height"]:
        dest.add (name: n, value: initialValue(n))
      dest.add (name: "font-family", value: toks[0])
      return true
  var style = "normal"
  var caps = "normal"
  var weight = "normal"
  var stretch = "normal"
  var i = 0
  # prefix: style / small-caps / weight / stretch, any order, at most once each
  var seenS, seenC, seenW, seenT = false
  while i < toks.len:
    let t = toks[i]
    let l = lower(t)
    if l == "normal":
      inc i
      continue
    if not seenS and (l == "italic" or l == "oblique"):
      style = t
      seenS = true
      # oblique may take an angle
      if l == "oblique" and i + 1 < toks.len and validFor("font-style", "oblique " & toks[i+1]):
        style = "oblique " & toks[i+1]
        inc i
    elif not seenC and l == "small-caps":
      caps = t
      seenC = true
    elif not seenW and (l == "bold" or l == "bolder" or l == "lighter" or
                        (isNumberTok(t) and validFor("font-weight", t) and
                         i + 1 < toks.len and not (toks[i+1] == "/"))):
      # a bare number is a weight only if something (the size) follows it
      weight = t
      seenW = true
    elif not seenT and validFor("font-stretch", t) and not validFor("font-size", t):
      stretch = t
      seenT = true
    else:
      break
    inc i
  if i >= toks.len: return false
  let size = toks[i]
  if not validFor("font-size", size): return false
  inc i
  var lh = "normal"
  if i < toks.len and toks[i] == "/":
    if i + 1 >= toks.len: return false
    lh = toks[i+1]
    if not validFor("line-height", lh): return false
    i = i + 2
  if i >= toks.len: return false
  let family = joinRange(toks, i, toks.len)
  if not validFor("font-family", family): return false
  dest.add (name: "font-style", value: style)
  dest.add (name: "font-variant-caps", value: caps)
  dest.add (name: "font-weight", value: weight)
  dest.add (name: "font-stretch", value: stretch)
  dest.add (name: "font-size", value: size)
  dest.add (name: "line-height", value: lh)
  dest.add (name: "font-family", value: family)
  for n in fontResets:
    dest.add (name: n, value: initialValue(n))
  true

proc isAutoOrIdent(t: string): bool =
  t.len > 0 and ((t[0] >= 'a' and t[0] <= 'z') or (t[0] >= 'A' and t[0] <= 'Z') or
                 t[0] == '-' or t[0] == '_') and not isNumberTok(t)

proc gridLines(names: seq[string], toks: seq[string], dest: var seq[Longhand]): bool =
  ## `a / b / c / d`. An omitted line copies the opposite one when that one is
  ## a custom-ident, else it is `auto` (CSS Grid §8.4).
  let parts = splitOn(toks, "/")
  if parts.len > names.len: return false
  var vals: seq[string] = @[]
  var i = 0
  while i < parts.len:
    if parts[i].len == 0: return false
    vals.add joinRange(parts[i], 0, parts[i].len)
    inc i
  while vals.len < names.len:
    let k = vals.len
    # grid-area: 2nd copies 1st, 3rd copies 1st, 4th copies 2nd
    let src = (if names.len == 4: (if k == 3: 1 else: 0) else: 0)
    let v = vals[src]
    vals.add (if isAutoOrIdent(v) and lower(v) != "auto" and not hasSpace(v): v else: "auto")
  i = 0
  while i < names.len:
    if not validFor(names[i], vals[i]): return false
    dest.add (name: names[i], value: vals[i])
    inc i
  true

proc isTimeTok(t: string): bool =
  let l = lower(t)
  if l.len < 2: return false
  let ms = l.len > 2 and l[l.len-2] == 'm' and l[l.len-1] == 's'
  let s = l[l.len-1] == 's'
  if not (ms or s): return false
  var body = ""
  var i = 0
  while i < l.len - (if ms: 2 else: 1):
    body.add l[i]
    inc i
  isNumberTok(body) or (l.len > 5 and l[0] == 'c' and l[1] == 'a' and l[2] == 'l')

proc layered(names: seq[string], timeNames: seq[string], toks: seq[string],
             dest: var seq[Longhand]): bool =
  ## transition / animation: comma-separated items; in each, the first time is
  ## the duration and the second the delay; the rest are any-order.
  let items = splitOn(toks, ",")
  var cols: seq[string] = @[]
  var tcols: seq[string] = @[]
  var k = 0
  while k < names.len:
    cols.add ""
    inc k
  k = 0
  while k < timeNames.len:
    tcols.add ""
    inc k
  var it = 0
  while it < items.len:
    let item = items[it]
    if item.len == 0: return false
    var rest: seq[string] = @[]
    var times: seq[string] = @[]
    var i = 0
    while i < item.len:
      if isTimeTok(item[i]) and times.len < 2: times.add item[i]
      else: rest.add item[i]
      inc i
    var one: seq[Longhand] = @[]
    if rest.len > 0:
      if not anyOrder(names, rest, one): return false
    else:
      k = 0
      while k < names.len:
        one.add (name: names[k], value: initialValue(names[k]))
        inc k
    k = 0
    while k < names.len:
      if it > 0: cols[k].add ", "
      cols[k].add one[k].value
      inc k
    k = 0
    while k < timeNames.len:
      if it > 0: tcols[k].add ", "
      tcols[k].add (if k < times.len: times[k] else: "0s")
      inc k
    inc it
  k = 0
  while k < timeNames.len:
    dest.add (name: timeNames[k], value: tcols[k])
    inc k
  k = 0
  while k < names.len:
    dest.add (name: names[k], value: cols[k])
    inc k
  true

proc isBox(t: string): bool =
  let l = lower(t)
  l == "border-box" or l == "padding-box" or l == "content-box" or l == "text"

proc background(toks: seq[string], dest: var seq[Longhand]): bool =
  let layers = splitOn(toks, ",")
  var image, position, size, repeat, attachment, origin, clip = ""
  var color = "transparent"
  var li = 0
  while li < layers.len:
    var layer = layers[li]
    if layer.len == 0: return false
    var lImage = "none"
    var lPos = "0% 0%"
    var lSize = "auto"
    var lRepeat = "repeat"
    var lAtt = "scroll"
    var lOrigin = "padding-box"
    var lClip = "border-box"
    # boxes first: one sets origin AND clip, two set origin then clip
    var boxes: seq[string] = @[]
    var rest: seq[string] = @[]
    var i = 0
    while i < layer.len:
      if isBox(layer[i]) and boxes.len < 2: boxes.add layer[i]
      else: rest.add layer[i]
      inc i
    if boxes.len >= 1:
      lOrigin = boxes[0]
      lClip = boxes[0]
    if boxes.len == 2: lClip = boxes[1]
    # position [ / size ]
    var slash = -1
    i = 0
    while i < rest.len:
      if rest[i] == "/": slash = i
      inc i
    if slash >= 0:
      var a = slash - 1
      var found = -1
      while a >= 0:
        if validFor("background-position", joinRange(rest, a, slash)): found = a
        dec a
      if found < 0: return false
      var b = rest.len
      var foundB = -1
      while b > slash + 1:
        if validFor("background-size", joinRange(rest, slash + 1, b)):
          foundB = b
          break
        dec b
      if foundB < 0: return false
      lPos = joinRange(rest, found, slash)
      lSize = joinRange(rest, slash + 1, foundB)
      var r2: seq[string] = @[]
      i = 0
      while i < rest.len:
        if i < found or i >= foundB: r2.add rest[i]
        inc i
      rest = r2
    var names = @["background-image", "background-repeat", "background-attachment"]
    if slash < 0: names.add "background-position"
    if li == layers.len - 1: names.add "background-color"
    var one: seq[Longhand] = @[]
    if rest.len > 0:
      if not anyOrder(names, rest, one): return false
      i = 0
      while i < one.len:
        let n = one[i].name
        let v = one[i].value
        if v.len > 0:
          if n == "background-image": lImage = v
          elif n == "background-repeat": lRepeat = v
          elif n == "background-attachment": lAtt = v
          elif n == "background-position": lPos = v
          elif n == "background-color" and v != initialValue("background-color"): color = v
        inc i
    if li > 0:
      image.add ", "; position.add ", "; size.add ", "; repeat.add ", "
      attachment.add ", "; origin.add ", "; clip.add ", "
    image.add lImage; position.add lPos; size.add lSize; repeat.add lRepeat
    attachment.add lAtt; origin.add lOrigin; clip.add lClip
    inc li
  dest.add (name: "background-image", value: image)
  dest.add (name: "background-position", value: position)
  dest.add (name: "background-size", value: size)
  dest.add (name: "background-repeat", value: repeat)
  dest.add (name: "background-attachment", value: attachment)
  dest.add (name: "background-origin", value: origin)
  dest.add (name: "background-clip", value: clip)
  dest.add (name: "background-color", value: color)
  true

proc logicalBorder(side: string, toks: seq[string], dest: var seq[Longhand]): bool =
  anyOrder(@["border-" & side & "-width", "border-" & side & "-style",
             "border-" & side & "-color"], toks, dest)

# --- the table --------------------------------------------------------------------------

proc expandInto(prop: string, toks: seq[string], dest: var seq[Longhand]): bool =
  case prop
  of "margin": box4(sideNames("margin-", ""), toks, dest)
  of "padding": box4(sideNames("padding-", ""), toks, dest)
  of "inset": box4(["top", "right", "bottom", "left"], toks, dest)
  of "border-width": box4(sideNames("border-", "-width"), toks, dest)
  of "border-style": box4(sideNames("border-", "-style"), toks, dest)
  of "border-color": box4(sideNames("border-", "-color"), toks, dest)
  of "scroll-margin": box4(sideNames("scroll-margin-", ""), toks, dest)
  of "scroll-padding": box4(sideNames("scroll-padding-", ""), toks, dest)
  of "border-radius": radius(toks, dest)
  of "margin-block", "margin-inline", "padding-block", "padding-inline",
     "inset-block", "inset-inline", "scroll-margin-block", "scroll-margin-inline",
     "scroll-padding-block", "scroll-padding-inline":
    pair(prop & "-start", prop & "-end", toks, dest)
  of "border-block-width", "border-block-style", "border-block-color",
     "border-inline-width", "border-inline-style", "border-inline-color":
    # border-block-width → border-block-start-width / -end-width
    var axis = ""
    var what = ""
    var i = 0
    var dashes = 0
    while i < prop.len:
      if prop[i] == '-': inc dashes
      elif dashes == 1: axis.add prop[i]
      elif dashes == 2: what.add prop[i]
      inc i
    pair("border-" & axis & "-start-" & what, "border-" & axis & "-end-" & what, toks, dest)
  of "gap", "grid-gap": pair("row-gap", "column-gap", toks, dest)
  of "overflow": pair("overflow-x", "overflow-y", toks, dest)
  of "overscroll-behavior": pair("overscroll-behavior-x", "overscroll-behavior-y", toks, dest)
  of "place-content": pair("align-content", "justify-content", toks, dest)
  of "place-items": pair("align-items", "justify-items", toks, dest)
  of "place-self": pair("align-self", "justify-self", toks, dest)
  of "contain-intrinsic-size":
    pair("contain-intrinsic-width", "contain-intrinsic-height", toks, dest)
  of "border": border(toks, dest)
  of "border-top", "border-right", "border-bottom", "border-left",
     "border-block-start", "border-block-end", "border-inline-start", "border-inline-end":
    var side = ""
    var i = 7
    while i < prop.len:
      side.add prop[i]
      inc i
    logicalBorder(side, toks, dest)
  of "border-block", "border-inline":
    var one: seq[Longhand] = @[]
    if not logicalBorder(tail(prop, 7) & "-start", toks, one): return false
    var i = 0
    while i < one.len:
      dest.add one[i]
      inc i
    logicalBorder(tail(prop, 7) & "-end", toks, dest)
  of "outline": anyOrder(@["outline-width", "outline-style", "outline-color"], toks, dest)
  of "column-rule":
    anyOrder(@["column-rule-width", "column-rule-style", "column-rule-color"], toks, dest)
  of "text-decoration":
    anyOrder(@["text-decoration-line", "text-decoration-style",
               "text-decoration-color", "text-decoration-thickness"], toks, dest)
  of "list-style":
    # `none` may set type, image, or both; resolve the common single-token case
    if toks.len == 1 and lower(toks[0]) == "none":
      dest.add (name: "list-style-type", value: "none")
      dest.add (name: "list-style-position", value: "outside")
      dest.add (name: "list-style-image", value: "none")
      true
    else:
      anyOrder(@["list-style-type", "list-style-position", "list-style-image"], toks, dest)
  of "flex-flow": anyOrder(@["flex-direction", "flex-wrap"], toks, dest)
  of "columns": anyOrder(@["column-width", "column-count"], toks, dest)
  of "text-emphasis": anyOrder(@["text-emphasis-style", "text-emphasis-color"], toks, dest)
  of "caret": anyOrder(@["caret-color", "caret-shape"], toks, dest)
  of "flex": flex(toks, dest)
  of "font": font(toks, dest)
  of "grid-row": gridLines(@["grid-row-start", "grid-row-end"], toks, dest)
  of "grid-column": gridLines(@["grid-column-start", "grid-column-end"], toks, dest)
  of "grid-area":
    gridLines(@["grid-row-start", "grid-column-start", "grid-row-end", "grid-column-end"],
              toks, dest)
  of "transition":
    layered(@["transition-property", "transition-timing-function", "transition-behavior"],
            @["transition-duration", "transition-delay"], toks, dest)
  of "animation":
    layered(@["animation-timing-function", "animation-iteration-count",
              "animation-direction", "animation-fill-mode", "animation-play-state",
              "animation-name"],
            @["animation-duration", "animation-delay"], toks, dest)
  of "background": background(toks, dest)
  of "container":
    let parts = splitOn(toks, "/")
    if parts.len > 2 or parts[0].len == 0: return false
    dest.add (name: "container-name", value: joinRange(parts[0], 0, parts[0].len))
    dest.add (name: "container-type",
              value: (if parts.len == 2: joinRange(parts[1], 0, parts[1].len) else: "normal"))
    true
  else:
    # fallback: MDN's longhand list, any order
    let ls = longhandsOf(prop)
    if ls.len == 0: return false
    anyOrder(ls, toks, dest)

proc isCssWide(l: string): bool =
  l == "inherit" or l == "initial" or l == "unset" or l == "revert" or l == "revert-layer"

proc expandFully(prop: string, value: string, dest: var seq[Longhand], depth: int): bool =
  var one: seq[Longhand] = @[]
  if not expandInto(prop, components(value), one): return false
  var i = 0
  while i < one.len:
    let n = one[i].name
    if depth < 3 and isShorthand(n) and n != prop and n != "border-image":
      if not expandFully(n, one[i].value, dest, depth + 1):
        dest.add one[i]
    else:
      dest.add one[i]
    inc i
  true

proc shorthandLonghands*(prop: string): seq[string] =
  ## The longhands `prop` sets (after full expansion), in expansion order.
  result = @[]
  var probe: seq[Longhand] = @[]
  let p = lower(prop)
  # expand the property's own initial-ish value to learn the names
  var sample = "initial"
  case p
  of "margin", "padding", "inset", "scroll-margin", "scroll-padding": sample = "0"
  of "border-width", "border", "border-top", "border-right", "border-bottom",
     "border-left", "outline", "column-rule": sample = "medium"
  of "border-style": sample = "none"
  of "border-color", "text-decoration", "text-emphasis", "caret": sample = "currentcolor"
  of "border-radius": sample = "0"
  of "gap", "grid-gap": sample = "normal"
  of "overflow": sample = "visible"
  of "flex": sample = "none"
  of "font": sample = "16px serif"
  of "background": sample = "none"
  of "transition": sample = "all"
  of "animation": sample = "none"
  of "list-style": sample = "none"
  of "flex-flow": sample = "row"
  of "columns": sample = "auto"
  of "grid-row", "grid-column", "grid-area": sample = "auto"
  of "place-content", "place-items", "place-self": sample = "normal"
  else: discard
  if expandFully(p, sample, probe, 0):
    var i = 0
    while i < probe.len:
      result.add probe[i].name
      inc i
  else:
    result = longhandsOf(p)

proc expandShorthand*(prop, value: string): tuple[ok: bool, longhands: seq[Longhand]] =
  ## Expand `prop: value` into longhands. `ok` is false when the value is not
  ## valid for the shorthand, or its shape is one this module does not take
  ## apart (the `grid`/`grid-template` template forms, `mask-border`, …).
  ## A CSS-wide keyword is copied to every longhand.
  var dest: seq[Longhand] = @[]
  let p = lower(prop)
  let v = value
  let toks = components(v)
  if toks.len == 1 and isCssWide(lower(toks[0])):
    let names = shorthandLonghands(p)
    var i = 0
    while i < names.len:
      dest.add (name: names[i], value: lower(toks[0]))
      inc i
    return (names.len > 0, dest)
  if not validateValue(p, v).valid: return (false, dest)
  if not expandFully(p, v, dest, 0): return (false, @[])
  (true, dest)
