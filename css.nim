## css — the CSS pack's public API: MDN-typed value + selector validation and
## specificity/cascade resolution.
##
## Pure logic — standard library only, **no aoughwl substrate** — so the
## published `.nim` package compiles and runs with plain nimony / Nim 3.0 with
## no extra dependency.
##
##   import css
##
##   validateValue("margin", "0 auto").valid          # true
##   validateValue("color", "10px").valid              # false
##   validateSelector("ul > li:nth-child(2n+1)").valid # true
##   $specificity("a.btn#go")                          # (1,1,1)
##   isPseudoClass("hover")                            # true
##
## The substrate-backed `style X:` DSL (component styles as aoughwl atoms, with
## provenance) lives in `css/style` and requires aoughwl — it is intentionally
## NOT part of this pure-validation surface.
import css/validator
import css/selectors
import css/cascade
import css/data_load
export validator, selectors, cascade, data_load
