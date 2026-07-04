# css

**An MDN-typed CSS validator for nimony / Nim 3.0** — validates CSS *values* and
*selectors* against the official MDN data, and computes selector specificity /
the cascade. Pure logic, **no dependencies** beyond the standard library.

Successor to the Nim-2 [thing-king/css](https://github.com/thing-king/css).

```nim
import css

# --- value validation (against each property's MDN value-definition syntax) ---
validateValue("margin", "0 auto").valid                 # true
validateValue("width",  "clamp(1rem, 2vw, 3rem)").valid # true
validateValue("color",  "10px").valid                   # false

# --- selector validation (Selectors-4 grammar + MDN pseudo names) ---
validateSelector("ul > li:nth-child(2n+1)").valid       # true
validateSelector("a:notapseudo").valid                  # false

# --- specificity + cascade ---
$specificity("a.btn#go")                                # (1,1,1)

# --- math functions are validated recursively, with precise errors ---
validateValue("width", "clamp(1rem, calc(2vw + 10px), 3rem)").valid  # true
validateValue("width", "clamp(1rem, 2vw)").error   # "clamp() expects 3 arguments, got 2"
validateValue("width", "calc(100% - )").error      # "calc(): unexpected end of expression"
```

> This package is generated from the [aoughwl](https://github.com/aoughwl) `css`
> pack. Inside aoughwl there is additionally a substrate-backed `style X:` DSL
> (component styles become content-addressed atoms with provenance); that half
> requires aoughwl and is not part of this standalone validator.

## What's in the pack

| module | what it does |
| --- | --- |
| `css/parse` | full stylesheet parser → rules + declarations (comments, strings, `url(data:…;…)`, `!important`, custom props, nested `@media`/`@keyframes`) |
| `css/validator` | single-pass, compiled-arena matcher for property values + strict function-argument validation |
| `css/vds` | MDN value-definition-syntax parser (`<len> \| <pct>`, `? * + # #{n}`, `\|\| &&`, …) |
| `css/math` | recursive validator for the math functions (`calc`/`min`/`max`/`clamp`/…) — arity, the self-nesting `<calc-sum>` grammar, precise errors |
| `css/selectors` | Selectors-4 validator (type/class/id/attribute/pseudo + combinators) |
| `css/cascade` | selector specificity `(a,b,c)` + a source-order cascade resolver |
| `css/value_lex` | CSS value tokenizer |
| `css/data_load` + `css/data` | the baked MDN tables (properties, syntaxes, types, units, pseudos) |
| `css/tools/gen_data` | regenerates `css/data.nim` from the MDN JSON |

Everything is **driven by the MDN data** in `css/data/*.json` — track a spec change
by dropping in fresh JSON and re-running `css/tools/gen_data`. Trim the data to
constrain which CSS a project is allowed to use.

## Public API

| proc | result |
| --- | --- |
| `validateValue(prop, value): tuple[valid, error]` | validate a value, with a readable error |
| `valueMatches(prop, value): bool` | value validity, boolean |
| `validateSelector(sel): tuple[valid, error]` | validate a selector / selector list |
| `specificity(sel): Specificity` | selector specificity `(a,b,c)`, comparable with `<` |
| `cascade(decls): seq[Winner]` | resolve declarations to the winning value per property |
| `isProperty` / `propertySyntax` | known-property check / its MDN syntax |
| `isPseudoClass` / `isPseudoElement` | known pseudo-class / -element check |

## Install

Put this repo on your import path and `import css`. It compiles with plain
nimony / Nim 3.0 — no substrate, no build steps, standard library only.

## Proven on Bootstrap

The parser + validators run over the whole of **Bootstrap 5.3.3** (281 KB) with
**zero false positives**:

```
declarations:  4368 valid, 0 invalid, 1174 custom-props (skipped)
selectors:     2556 valid, 0 invalid
```

Every one of the 5 542 declarations is matched against its MDN value-definition
grammar (math functions checked recursively; `rgb()`/`hsl()`/gradients/transforms
checked against their own grammar; `var()`/`env()`, vendor prefixes and comment
noise handled as real browsers do), and every selector against Selectors-4. See
`tests/tbootstrap.nim`.

## Scope

Value validation, selector validation, function-argument validation, full
stylesheet parsing, and specificity/cascade resolution are complete and
MDN-driven. Computed-style inheritance and `@import` resolution are next.

## License

MIT.
