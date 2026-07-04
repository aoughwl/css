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
```

> This package is generated from the [aoughwl](https://github.com/aoughwl) `css`
> pack. Inside aoughwl there is additionally a substrate-backed `style X:` DSL
> (component styles become content-addressed atoms with provenance); that half
> requires aoughwl and is not part of this standalone validator.

## What's in the pack

| module | what it does |
| --- | --- |
| `css/validator` | single-pass, compiled-arena matcher for property values |
| `css/vds` | MDN value-definition-syntax parser (`<len> \| <pct>`, `? * + #`, `\|\| &&`, …) |
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

## Scope

Value validation, selector validation, and specificity/cascade resolution are
complete and MDN-driven. Full computed-style inheritance, `@import` resolution,
and stylesheet parsing/serialization are on the roadmap.

## License

MIT.
