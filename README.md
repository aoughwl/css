# aoughwl/css

**The CSS pack for [aoughwl](https://github.com/aoughwl) — an MDN-typed CSS
validator and style DSL, expressed in aoughwl's own system, for nimony / Nim 3.0.**

Successor to the Nim-2 [thing-king/css](https://github.com/thing-king/css),
rebuilt as an aoughwl pack: it validates CSS *values* and *selectors* against the
official MDN data, and lowers a `style` block straight into aoughwl's substrate as
content-addressed style atoms.

```nim
import css

# --- value validation (against each property's MDN value-definition syntax) ---
validateValue("margin", "0 auto").valid                 # true
validateValue("width",  "clamp(1rem, 2vw, 3rem)").valid # true
validateValue("color",  "10px").valid                   # false

# --- selector validation (Selectors-4 grammar + MDN pseudo names) ---
validateSelector("ul > li:nth-child(2n+1)").valid       # true
validateSelector("a:notapseudo").valid                  # false

# --- the style DSL: declarations become substrate atoms + has_style facts ---
style "card":
  color: red
  padding: 10.px 20.px

echo renderStylesheet()      # .c…{color:red} .c…{padding:10px 20px}
```

## What's in the pack

| module | what it does |
| --- | --- |
| `css/validator` | single-pass, compiled-arena matcher for property values |
| `css/vds` | MDN value-definition-syntax parser (`<len> \| <pct>`, `? * + #`, `\|\| &&`, …) |
| `css/selectors` | Selectors-4 validator (type/class/id/attribute/pseudo + combinators) |
| `css/cascade` | selector specificity `(a,b,c)` + a source-order cascade resolver |
| `css/value_lex` | CSS value tokenizer |
| `css/data_load` + `css/data` | the baked MDN tables (properties, syntaxes, types, units, pseudos) |
| `css/deps/style_plugin` | the `style X:` block DSL — a compiler plugin authored in aoughwl |
| `css/tools/gen_data` | regenerates `css/data.aowl` from the MDN JSON |

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
| `style name: …` | declare a component's styles into the substrate |
| `styleOne` / `applyStyle` / `renderStylesheet` / `whyStyle` | style-atom operations + provenance |

## Install

Place the pack under `packs/aoughwl/` in your project (so you have
`packs/aoughwl/css.aowl` and `packs/aoughwl/css/`), build with `-p:packs`, and
`import css`.

## Scope

Value validation, selector validation, and specificity/cascade resolution are
complete and MDN-driven. Full computed-style inheritance, `@import` resolution,
and stylesheet parsing/serialization are on the roadmap.

## License

MIT.
