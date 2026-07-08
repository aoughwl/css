# css

**A complete, MDN-typed CSS engine for nimony / Nim 3.0** — parse a whole
stylesheet, then validate every value against its official grammar, every function
against its own signature, and every selector against Selectors-4. Pure logic,
standard library only, **no dependencies**.

**📖 Full docs → [aoughwl.github.io/docs/css](https://aoughwl.github.io/docs/css)**

```nim
import css

validateValue("width", "clamp(1rem, 2vw, 3rem)").valid   # true
validateValue("width", "clamp(1rem, 2vw)").error         # "clamp() expects 3 arguments, got 2"
validateSelector("ul > li:nth-child(2n+1)").valid        # true
```

Driven entirely by the MDN data in `css/data/*.json` — track a spec change by
dropping in fresh JSON. Successor to the Nim-2
[thing-king/css](https://github.com/thing-king/css).
