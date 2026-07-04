## css/style — the `style X:` component-style DSL (public, substrate-free).
##
## Lowers each `style "component": prop: value` block into `styleOne` calls that
## validate the declaration against its MDN grammar and store it under a stable,
## content-derived class name. This is the public build of the DSL: it keeps the
## exact surface of the aoughwl version, but stores styles in a plain table
## instead of the aoughwl substrate, so it compiles with nim / nimony and nothing
## else. The compile-time rewrite lives in `deps/style_plugin`, which imports the
## published `plugin` package (github.com/aoughwl/plugin).
##
##   import css/style
##
##   style "card":
##     color: red
##     padding: 10.px 20.px
##   echo renderStylesheet()

import validator
import data_load
export validator, data_load

type StyleDecl = object
  prop: string
  value: string

var gDecls: seq[StyleDecl] = @[]                 ## unique declarations, first-seen order
var gErrors: seq[string] = @[]                   ## declarations that failed MDN validation
var gOwners: seq[seq[string]] = @[]              ## per-decl: the components that declared it

# --- content-derived class names (FNV-1a, stable & dedup-friendly) ----------

proc fnv1a(s: string): uint32 =
  var h: uint32 = 2166136261'u32
  var i = 0
  while i < s.len:
    h = h xor uint32(ord(s[i]))
    h = h * 16777619'u32
    inc i
  h

proc toHex8(x: uint32): string =
  const digits = "0123456789abcdef"
  result = ""
  var i = 7
  while i >= 0:
    let nib = int((x shr uint32(i * 4)) and 0xF'u32)
    result.add digits[nib]
    dec i

proc classFor(prop, value: string): string = "c" & toHex8(fnv1a(prop & ":" & value))

proc indexOf(prop, value: string): int =
  var i = 0
  while i < gDecls.len:
    if gDecls[i].prop == prop and gDecls[i].value == value: return i
    inc i
  -1

# --- the lowered target -----------------------------------------------------

proc styleOne*(component, prop, value: string) =
  ## Register one declaration for a component: validate against the MDN grammar,
  ## then store it (deduped by content). This is what the `style X:` DSL lowers to.
  let res = validateValue(prop, value)
  if not res.valid:
    gErrors.add prop & ": " & value & "  — " & res.error
  var idx = indexOf(prop, value)
  if idx < 0:
    idx = gDecls.len
    gDecls.add StyleDecl(prop: prop, value: value)
    gOwners.add @[]
  var owners = gOwners[idx]
  var seen = false
  var k = 0
  while k < owners.len:
    if owners[k] == component: seen = true
    inc k
  if not seen:
    owners.add component
    gOwners[idx] = owners

proc classOf*(prop, value: string): string = classFor(prop, value)

proc renderStylesheet*(): string =
  ## Emit every registered declaration as a single-declaration CSS rule, using
  ## the content-derived class name.
  result = ""
  var i = 0
  while i < gDecls.len:
    let d = gDecls[i]
    result.add "." & classFor(d.prop, d.value) & "{" & d.prop & ":" & d.value & "}\n"
    inc i

proc styleErrors*(): seq[string] = gErrors

proc whyStyle*(component, prop, value: string): string =
  ## Explain a component's style: which declaration it maps to and whether it is
  ## valid CSS. (The aoughwl build answers this from substrate provenance; the
  ## public build answers it from the declaration table.)
  let idx = indexOf(prop, value)
  if idx < 0:
    return component & " has no style " & prop & ": " & value
  var owned = false
  let owners = gOwners[idx]
  var k = 0
  while k < owners.len:
    if owners[k] == component: owned = true
    inc k
  let res = validateValue(prop, value)
  result = component & " has_style ." & classFor(prop, value) &
    "  { " & prop & ": " & value & " }"
  if not owned:
    result.add "\n  (not declared by " & component & ")"
  if res.valid:
    result.add "\n  <- valid per MDN grammar"
  else:
    result.add "\n  <- INVALID: " & res.error

# The `style X:` block DSL — a compiler plugin. It lowers each `prop: value` line
# to a `styleOne` call. The plugin logic lives in `deps/style_plugin`, which
# imports the published `plugin` package.
template style*(name: string, body: untyped) {.plugin: "deps/style_plugin".}
