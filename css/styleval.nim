## css/styleval — `Style`, a first-class CSS value.
##
## A `Style` is an ordered set of declarations that can be built, passed around,
## merged and overridden like any other value:
##
##   let base = declare("color", "red") & declare("padding", "10px")
##   let warm = base & declare("color", "orange")  # right wins: color is orange
##   cssText(warm)                                 # "color:orange;padding:10px"
##
## This is the value the `web` DSL's `@style` directive consumes, which is what
## makes themes ordinary data — `defaultTheme()` is just a proc returning a
## `Style`, and overriding it is `&`, not string surgery.
##
## Declarations are validated against the MDN value grammar on demand
## (`errors`), not on construction, so a `Style` can be assembled freely and
## checked once at the point it is attached to an element.

import validator

type
  StyleDecl* = object
    prop*: string
    value*: string

  Style* = object
    decls*: seq[StyleDecl]

proc initStyle*(): Style =
  ## The empty style.
  result = Style(decls: @[])

proc len*(s: Style): int = s.decls.len

proc find(s: Style, prop: string): int =
  result = -1
  var i = 0
  while i < s.decls.len:
    if s.decls[i].prop == prop:
      result = i
      i = s.decls.len
    else:
      inc i

proc set*(s: var Style; prop, value: string) =
  ## Set `prop`, replacing any existing declaration of it **in place** — so a
  ## later override keeps the original declaration order rather than appending.
  let idx = find(s, prop)
  if idx < 0:
    s.decls.add StyleDecl(prop: prop, value: value)
  else:
    s.decls[idx] = StyleDecl(prop: prop, value: value)

proc get*(s: Style, prop: string): string =
  ## The declared value of `prop`, or `""` if this style does not set it.
  let idx = find(s, prop)
  if idx < 0: "" else: s.decls[idx].value

proc has*(s: Style, prop: string): bool = find(s, prop) >= 0

proc declare*(prop, value: string): Style =
  ## A one-declaration style.
  result = Style(decls: @[StyleDecl(prop: prop, value: value)])

proc styleOf*(decls: string): Style =
  ## Parse a `"prop:value;prop:value"` block into a `Style`.
  ##
  ## The point is authoring density: a design-system rule is a handful of
  ## declarations, and spelling each as a separate `declare(…)` call buries the
  ## rule in ceremony. The result is an ordinary `Style`, so it still merges with
  ## `&` and still reports through `errors`. Values may contain `:` (a `url(…)`,
  ## a `calc()` with a nested function), so only the FIRST colon separates.
  result = Style(decls: @[])
  var prop = ""
  var value = ""
  var inProp = true
  var depth = 0
  var i = 0
  while i <= decls.len:
    if i == decls.len or (decls[i] == ';' and depth == 0):
      var p = ""
      var j = 0
      while j < prop.len:
        if prop[j] != ' ' and prop[j] != '\n' and prop[j] != '\t' and prop[j] != '\r':
          p.add prop[j]
        inc j
      # trim the value's outer whitespace but keep it internally intact
      var a = 0
      var b = value.len
      while a < b and (value[a] == ' ' or value[a] == '\n' or value[a] == '\t' or value[a] == '\r'):
        inc a
      while b > a and (value[b-1] == ' ' or value[b-1] == '\n' or value[b-1] == '\t' or value[b-1] == '\r'):
        dec b
      var v = ""
      var k = a
      while k < b:
        v.add value[k]
        inc k
      if p.len > 0: result.set(p, v)
      prop = ""
      value = ""
      inProp = true
    elif decls[i] == '(':
      inc depth
      if inProp: prop.add decls[i] else: value.add decls[i]
    elif decls[i] == ')':
      if depth > 0: dec depth
      if inProp: prop.add decls[i] else: value.add decls[i]
    elif decls[i] == ':' and inProp:
      inProp = false
    else:
      if inProp: prop.add decls[i] else: value.add decls[i]
    inc i

proc `&`*(a, b: Style): Style =
  ## Merge two styles, **right wins** per property. This is the override
  ## operator: `theme & style(color = "red")` is the theme with its colour
  ## replaced, and every other declaration of the theme intact.
  result = Style(decls: @[])
  var i = 0
  while i < a.decls.len:
    result.decls.add a.decls[i]
    inc i
  var j = 0
  while j < b.decls.len:
    result.set(b.decls[j].prop, b.decls[j].value)
    inc j

proc cssText*(s: Style): string =
  ## The declarations as a `;`-separated block: `"color:red;padding:10px"`.
  result = ""
  var i = 0
  while i < s.decls.len:
    if i > 0: result.add ";"
    result.add s.decls[i].prop
    result.add ":"
    result.add s.decls[i].value
    inc i

proc errors*(s: Style): seq[string] =
  ## Every declaration that fails its MDN value grammar, as readable text.
  result = @[]
  var i = 0
  while i < s.decls.len:
    let d = s.decls[i]
    let r = validateValue(d.prop, d.value)
    if not r.valid:
      result.add d.prop & ": " & d.value & "  — " & r.error
    inc i

proc valid*(s: Style): bool = errors(s).len == 0
