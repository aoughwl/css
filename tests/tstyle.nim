## tstyle — the public, substrate-free `style X:` DSL.
## Requires the `plugin` package (github.com/aoughwl/plugin) on the import path.

import std/syncio
import css/style

style "card":
  color: red
  padding: 10.px 20.px

style "btn":
  color: blue
  cursor: pointer

echo "--- stylesheet ---"
echo renderStylesheet()

echo "--- errors ---"
let errs = styleErrors()
for e in errs:
  echo "  " & e

echo "--- why(card, color, red) ---"
echo whyStyle("card", "color", "red")
