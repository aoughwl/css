# Package
version     = "0.2.0"
author      = "aoughwl"
description = "A CSS engine for nimony / Nim 3.0: MDN-typed validation of values, selectors and at-rules, a whole-stylesheet linter, selector matching, the cascade with computed values, @import resolution, colours, and a minifier."
license     = "MIT"
srcDir      = "."

# The `style X:` DSL is a compiler plugin; its plugin module imports `plugin`.
# Pure validation (import css) needs nothing but the standard library.
requires "https://github.com/aoughwl/plugin"
