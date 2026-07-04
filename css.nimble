# Package
version     = "0.1.0"
author      = "aoughwl"
description = "MDN-typed CSS validator + stylesheet parser for nimony / Nim 3.0 — value, function, selector and cascade validation, plus a substrate-free `style X:` DSL."
license     = "MIT"
srcDir      = "."

# The `style X:` DSL is a compiler plugin; its plugin module imports `plugin`.
# Pure validation (import css) needs nothing but the standard library.
requires "https://github.com/aoughwl/plugin"
