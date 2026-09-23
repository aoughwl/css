# css

**A CSS engine for nimony / Nim 3.0** — parse a stylesheet, validate every value,
selector and at-rule against its official grammar, lint it in context, then run the
cascade over an element tree and get computed values (inheritance, `var()`, layers,
`@media`, nesting, logical properties, colours, absolute lengths). Standard library
only, **no dependencies**.

**📖 Full docs → [aoughwl.github.io/docs/css](https://aoughwl.github.io/docs/css)**

```nim
import css

validateValue("width", "clamp(1rem, 2vw)").error         # "clamp() expects 3 arguments, got 2"
validateMediaQueryList("(min-widht: 600px)").error       # "unknown media feature 'min-widht'"
for d in lintStylesheet(src): echo $d                    # "5: error: colr is not a known CSS property"

let eng = newStyleEngine()
eng.addStylesheet(src)
eng.computedStyle(querySelector(doc, "h1")).get("color") # "rgb(255, 0, 0)"
eng.why(h1, "color")                                     # which rule won, and what it beat
```

Driven by the MDN data in `css/data/*.json`. Tests: `tests/run.sh`. Successor to the
Nim-2 [thing-king/css](https://github.com/thing-king/css).
