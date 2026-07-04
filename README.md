# css

**A complete, MDN-typed CSS engine for nimony / Nim 3.0** — parse a whole
stylesheet, then validate every value against its official grammar, every
function against its own signature, and every selector against Selectors-4.
Pure logic, standard library only, **no dependencies**.

Successor to the Nim-2 [thing-king/css](https://github.com/thing-king/css).

```nim
import css

validateValue("margin", "0 auto").valid                     # true
validateValue("width",  "clamp(1rem, 2vw, 3rem)").valid     # true
validateValue("color",  "rgb(255 0 0 / 50%)").valid         # true

validateValue("width",  "clamp(1rem, 2vw)").error   # "clamp() expects 3 arguments, got 2"
validateValue("color",  "rgb(1, 2)").error          # "invalid arguments to rgb(): …"
validateValue("color",  "10px").error               # "at token 1: expected <color>, got '10px'"

validateSelector("ul > li:nth-child(2n+1)").valid           # true
$specificity("a.btn#go")                                    # (1,1,1)
```

---

## Why this exists

Most CSS tools **parse** but do not **validate against the grammar**. The few
that do (css-tree, the W3C validator) stop at flat value matching. This engine
goes the whole way:

- ✅ **Every property value** matched against its MDN value-definition syntax
  (`<length-percentage>{1,4} | auto`, `<'border-radius'>`, `||`, `&&`, `#{n}`, …)
- ✅ **Math functions checked recursively** — the self-nesting
  `clamp(calc(…), min(…), max(…))` grammar, exact arity, precise errors
- ✅ **Every function** (`rgb`/`hsl`/gradients/transforms/…) matched against its
  own signature — wrong arity, wrong argument types, unknown functions
- ✅ **Selectors** validated against Selectors-4 (specificity + cascade too)
- ✅ **Real-world CSS**: `var()`/`env()` substitution, vendor prefixes,
  `url(data:…)`, comments, `!important` — handled the way browsers do

Everything is **driven by the MDN data** in `css/data/*.json`: track a spec
change by dropping in fresh JSON and re-running `css/tools/gen_data`; trim the
data to constrain which CSS a project is allowed to use.

---

## Benchmark

The whole of **Bootstrap 5.3.3** (281 KB, 5 542 declarations, 2 556 selectors)
is parsed and validated with **zero false positives**. Timed against the
state-of-the-art, **on the same machine, at matched tiers of work** (each tool
doing the same job). `css` is compiled with nimony (ahead-of-time, no JIT); the
JS tools run on V8; lightningcss is Rust.

**Parse** — CSS text → structured rules + declarations:

| tool | time | throughput |
|---|--:|--:|
| lightningcss (Rust, parse + analyze) | 7.6 ms | 35 MB/s |
| **`css` (this)** | **9.8 ms** | **28 MB/s** |
| postcss (JS) | 9.1 ms | 30 MB/s |
| css-tree (JS) | 18.8 ms | 14 MB/s |

**Validate** — parse **+ match every declaration value against its MDN grammar**:

| tool | time | declarations validated |
|---|--:|--:|
| **`css` (this)** | **53.6 ms** | **4 368** |
| css-tree `matchProperty` (JS) | 62.1 ms | 3 493 |

**Full** — parse + values **+ recursive math + strict function args + Selectors-4**:

| tool | time | work |
|---|--:|--:|
| **`css` (this)** | **56.3 ms** | 4 368 decls + 2 556 selectors + math + fn-args |
| *anything else* | — | *no other tool computes this* |

So: our **parser rivals Rust** and beats every JS parser; our **validator is
faster per-declaration than css-tree** (≈12 µs vs ≈18 µs) *while checking more*
— and nothing else does the full tier at all. Reproduce with `tests/tbootstrap`
(ours) and the harness in the repo (theirs).

### Configuration — pay only for the checking you want

`setLevel` trades coverage for speed; the tiers above map straight onto it:

```nim
setLevel(lvValues)   # whole-value grammar match only  (fast path)
setLevel(lvFull)     # + recursive math + strict function-argument grammars  (default)
```

Function/math checking is also skipped automatically for any value that contains
no functions, and error-message bookkeeping is skipped on the success path — so
you never pay for work a value doesn't need.

---

## The `style X:` DSL

On top of validation, `css/style` gives you a component-style DSL — a nimony
compiler plugin that lowers each declaration to a validated, content-addressed
rule:

```nim
import css/style

style "card":
  color: red
  padding: 10.px 20.px

style "btn":
  color: blue
  cursor: pointer

echo renderStylesheet()
# .c3de3878d{color:red}
# .c5731cd7d{padding:10px 20px}
# .c1b85debe{color:blue}
# .cc4e1b13c{cursor:pointer}

echo whyStyle("card", "color", "red")
# card has_style .c3de3878d  { color: red }
#   <- valid per MDN grammar
```

Every declaration is validated against the MDN grammar as it is registered
(`styleErrors()` lists any that fail), deduped by content, and given a stable
class name. The DSL is powered by the [`plugin`](https://github.com/aoughwl/plugin)
package (nimony plugin-authoring runtime) — the only dependency, and only for the
DSL; plain `import css` validation needs nothing but the standard library.

---

## Modules

| module | what it does |
| --- | --- |
| `css/parse` | full stylesheet parser → rules + declarations (comments, strings, `url(data:…;…)`, `!important`, custom props, nested `@media`/`@keyframes`) |
| `css/validator` | compiled-grammar value matcher + strict function-argument validation + config levels |
| `css/vds` | MDN value-definition-syntax parser (`? * + # #{n}`, `\|\| &&`, ranges, functions) |
| `css/math` | recursive validator for math functions (`calc`/`min`/`max`/`clamp`/…) — the self-nesting `<calc-sum>` grammar, arity, precise errors |
| `css/selectors` | Selectors-4 validator (type/class/id/attribute/pseudo + combinators) |
| `css/cascade` | selector specificity `(a,b,c)` + a source-order cascade resolver |
| `css/value_lex` | CSS value tokenizer |
| `css/data_load` + `css/data` | the baked MDN tables (properties, syntaxes, types, units, pseudos) |
| `css/style` | the `style X:` component-style DSL (compiler plugin) |
| `css/tools/gen_data` | regenerates `css/data.nim` from the MDN JSON |

## Public API

| proc | result |
| --- | --- |
| `validateValue(prop, value): tuple[valid, error]` | validate a value, with a readable error |
| `valueMatches(prop, value): bool` | value validity, boolean |
| `validateSelector(sel): tuple[valid, error]` | validate a selector / selector list |
| `specificity(sel): Specificity` | selector specificity `(a,b,c)`, comparable with `<` |
| `cascade(decls): seq[Winner]` | resolve declarations to the winning value per property |
| `parseStylesheet(src): Stylesheet` | parse a whole stylesheet into rules + declarations |
| `setLevel(lvValues \| lvFull)` | choose the validation tier |
| `isProperty` / `propertySyntax` | known-property check / its MDN syntax |
| `isPseudoClass` / `isPseudoElement` | known pseudo-class / -element check |

## Install

Put this repo on your import path and `import css`. It compiles with plain
nimony / Nim 3.0 — no build steps, standard library only. The `style X:` DSL
additionally needs [`plugin`](https://github.com/aoughwl/plugin) on the path
(declared in `css.nimble`).

## Scope

Value validation, function-argument validation, selector validation, full
stylesheet parsing, and specificity/cascade resolution are complete and
MDN-driven. Computed-style inheritance and `@import` resolution are next.

## License

MIT.
