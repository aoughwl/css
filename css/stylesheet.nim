## css/stylesheet — an authored stylesheet as a VALUE.
##
## The other half of `styleval`. A `Style` is a set of declarations with no name;
## a `Stylesheet` maps SELECTORS to styles — the classic authored form, where a
## rule is written once under `.btn` and elements refer to it by class name:
##
##   var sheet = initStylesheet()
##   sheet.rule ".btn", declare("color", "white") & declare("padding", "6px 12px")
##   sheet.rule ".btn:hover", declare("color", "yellow")
##   render(sheet)
##   # .btn{color:white;padding:6px 12px}
##   # .btn:hover{color:yellow}
##
## Both selectors and declarations are validated — selectors against the selector
## grammar, declarations against the MDN value grammar — so an authored sheet is
## checked, not just concatenated.
##
## A sheet can also be installed as the process-wide sheet with `useStylesheet`,
## which is what lets a renderer emit authored rules alongside the scoped classes
## a DSL generates, from one call.

import styleval
import selectors

type
  Rule* = object
    selector*: string
    style*: Style

  Stylesheet* = object
    rules*: seq[Rule]

proc initStylesheet*(): Stylesheet =
  result = Stylesheet(rules: @[])

proc len*(sheet: Stylesheet): int = sheet.rules.len

proc find(sheet: Stylesheet, selector: string): int =
  result = -1
  var i = 0
  while i < sheet.rules.len:
    if sheet.rules[i].selector == selector:
      result = i
      i = sheet.rules.len
    else:
      inc i

proc has*(sheet: Stylesheet, selector: string): bool = find(sheet, selector) >= 0

proc rule*(sheet: var Stylesheet; selector: string; s: Style) =
  ## Declare `selector`. Declaring it twice MERGES right-wins into the existing
  ## rule rather than shadowing it, so a later `rule ".btn", …` refines the
  ## button instead of silently replacing it.
  let idx = find(sheet, selector)
  if idx < 0:
    sheet.rules.add Rule(selector: selector, style: s)
  else:
    sheet.rules[idx] = Rule(selector: selector, style: sheet.rules[idx].style & s)

proc `[]`*(sheet: Stylesheet; selector: string): Style =
  ## The style declared for `selector`, or the empty style. Returning a `Style`
  ## is the point: an authored rule can be reused as a value —
  ## `@style sheet[".btn"] & declare("color", "red")`.
  let idx = find(sheet, selector)
  if idx < 0: initStyle() else: sheet.rules[idx].style

proc `&`*(a, b: Stylesheet): Stylesheet =
  ## Merge two sheets; a selector declared in both merges right-wins.
  result = initStylesheet()
  var i = 0
  while i < a.rules.len:
    result.rules.add a.rules[i]
    inc i
  var j = 0
  while j < b.rules.len:
    result.rule(b.rules[j].selector, b.rules[j].style)
    inc j

proc render*(sheet: Stylesheet): string =
  ## The sheet as CSS text, one rule per line, in declaration order. A rule whose
  ## style is empty is skipped — an empty `.btn{}` is noise, not a rule.
  result = ""
  var i = 0
  while i < sheet.rules.len:
    let r = sheet.rules[i]
    if r.style.len > 0:
      result.add r.selector
      result.add "{"
      result.add cssText(r.style)
      result.add "}\n"
    inc i

proc errors*(sheet: Stylesheet): seq[string] =
  ## Every invalid selector and every declaration that fails its MDN grammar.
  result = @[]
  var i = 0
  while i < sheet.rules.len:
    let r = sheet.rules[i]
    let sel = validateSelector(r.selector)
    if not sel.valid:
      result.add r.selector & "  — " & sel.error
    let errs = errors(r.style)
    var j = 0
    while j < errs.len:
      result.add r.selector & " { " & errs[j] & " }"
      inc j
    inc i

# --- the installed sheet -----------------------------------------------------

var gSheet: Stylesheet = Stylesheet(rules: @[])

proc useStylesheet*(sheet: Stylesheet) =
  ## Install `sheet` as the process-wide authored stylesheet, replacing any
  ## previous one.
  gSheet = sheet

proc addStylesheet*(sheet: Stylesheet) =
  ## Merge `sheet` into the installed one (right-wins per selector).
  gSheet = gSheet & sheet

proc installedStylesheet*(): Stylesheet =
  ## The installed sheet — what a renderer emits alongside its scoped classes.
  gSheet

proc installedStyle*(selector: string): Style =
  ## The installed sheet's style for `selector`, or the empty style. Named apart
  ## from `styleval`'s `styleOf`, which parses DECLARATIONS — both take a string
  ## and return a `Style`, so sharing a name made every call ambiguous.
  gSheet[selector]
