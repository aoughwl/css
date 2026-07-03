## css.nim — the CSS domain, as an aoughwl **pack**.
##
## This is not part of aoughwl's core. It is authored *in* aoughwl's system: it
## opens a pack, declares the CSS domain's vocabulary into the substrate with the
## DSL, and exposes style operations for other packs to use. Importing it runs
## the pack — exactly like the old `code.core` / `idea.core` domain packs.
##
##   import aoughwl
##   import css
##
##   var s = newStyleSet()
##   s.styleDecl("color", "red")
##   discard style("card", s)      #  →  card has_style <atom> , in the substrate
##
## The MDN-typed validator (css/validator) is the pack's own helper — the pack
## brings its domain knowledge *and* its tools, all built on `import aoughwl`.

import aoughwl
import css/validator
import css/selectors
import css/cascade
import css/data_load
export validator, selectors, cascade, data_load   # value/selector validation, specificity/cascade, MDN tables

# --- the pack: declare the CSS domain into the substrate --------------------
pack "css.core"
context "CSS"

let hasStyle* = relation("has_style", inward)    ## component → a style atom
let styledBy* = relation("styled_by", outward)   ## (mirror direction)

const StyleContext* = "CSS"

# --- style atoms & sets -----------------------------------------------------

var gStyleOrder*: seq[AtomId] = @[]    ## style atoms, first-seen order
var gStyleErrors*: seq[string] = @[]   ## declarations that failed MDN validation

proc classOf*(id: AtomId): string = "c" & take(id, 8)

type StyleSet* = object
  atoms*: seq[AtomId]

proc newStyleSet*(): StyleSet = StyleSet(atoms: @[])

proc isKnown(id: AtomId): bool =
  var i = 0
  while i < gStyleOrder.len:
    if gStyleOrder[i] == id: return true
    inc i
  false

proc styleDecl*(s: var StyleSet, prop, value: string) =
  ## Validate against the MDN grammar, then store the declaration as a
  ## content-addressed atom in the substrate (deduped by aoughwl core).
  let res = validateValue(prop, value)
  if not res.valid:
    gStyleErrors.add prop & ": " & value & "  — " & res.error
  let id = aw.storeAtom(akData, prop & ":" & value)
  if not isKnown(id): gStyleOrder.add id
  s.atoms.add id

proc classes*(s: StyleSet): string =
  result = ""
  var i = 0
  while i < s.atoms.len:
    if i > 0: result.add " "
    result.add classOf(s.atoms[i])
    inc i

proc applyStyle*(component: string, s: StyleSet): string =
  ## Attach a style set to a component unit as `has_style` assertions in `aw`.
  aw.ensureUnit component
  var i = 0
  while i < s.atoms.len:
    discard aw.addAssertion(refUnit(component), "has_style", refAtom(s.atoms[i]),
      StyleContext, 1.0, false, Trace(kind: tkPack, pack: "css.core"))
    inc i
  classes(s)

proc styleOne*(component, prop, value: string) =
  ## Register a single declaration for a component: validate → content-addressed
  ## atom in `aw` → `has_style` assertion. This is what the `style X:` DSL lowers to.
  let res = validateValue(prop, value)
  if not res.valid:
    gStyleErrors.add prop & ": " & value & "  — " & res.error
  let id = aw.storeAtom(akData, prop & ":" & value)
  if not isKnown(id): gStyleOrder.add id
  aw.ensureUnit component
  discard aw.addAssertion(refUnit(component), "has_style", refAtom(id),
    StyleContext, 1.0, false, Trace(kind: tkPack, pack: "css.core"))

# The `style X:` block DSL — a compiler plugin, authored within aoughwl. It lowers
# each `prop: value` line to a `styleOne` call, so a component's styles are
# declared straight into the substrate.
template style*(name: string, body: untyped) {.plugin: "css/deps/style_plugin".}

proc renderStylesheet*(): string =
  ## Emit every style atom currently in the substrate as a CSS rule.
  result = ""
  var i = 0
  while i < gStyleOrder.len:
    let id = gStyleOrder[i]
    let at = aw.atoms.getOrDefault(id, Atom(id: id, kind: akData, body: ""))
    result.add "." & classOf(id) & "{" & at.body & "}\n"
    inc i

proc styleErrors*(): seq[string] = gStyleErrors

proc whyStyle*(component, prop, value: string): string =
  ## Provenance of a component's style, straight from the substrate — styles are
  ## first-class aoughwl assertions, so `why` explains them like any other fact.
  let id = aw.storeAtom(akData, prop & ":" & value)   # same content ⇒ same atom
  why(aw, refUnit(component), "has_style", refAtom(id))
