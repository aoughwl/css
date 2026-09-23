import std/syncio
import css
import css/shorthand

var fails = 0
proc show(ls: seq[Longhand]): string =
  result = ""
  for l in ls:
    if result.len > 0: result.add "; "
    result.add l.name & ": " & l.value

proc has(prop, value: string, name, want: string) =
  let r = expandShorthand(prop, value)
  var got = "<missing>"
  for l in r.longhands:
    if l.name == name: got = l.value
  if r.ok and got == want: echo "  ok   " & prop & ": " & value & "  => " & name & ": " & got
  else:
    inc fails
    echo "  FAIL " & prop & ": " & value & "  => " & name & " = " & got & " (want " & want & ")  ok=" & $r.ok
    echo "         " & show(r.longhands)

proc rejects(prop, value: string) =
  let r = expandShorthand(prop, value)
  if not r.ok: echo "  ok   rejects " & prop & ": " & value
  else:
    inc fails
    echo "  FAIL accepted " & prop & ": " & value & " -> " & show(r.longhands)

echo "box:"
has("margin", "0 auto", "margin-top", "0")
has("margin", "0 auto", "margin-left", "auto")
has("margin", "1px 2px 3px", "margin-left", "2px")
has("padding", "1px 2px 3px 4px", "padding-left", "4px")
has("inset", "0", "right", "0")
has("border-width", "thin medium", "border-bottom-width", "thin")
has("margin-inline", "1px 2px", "margin-inline-end", "2px")
has("margin-block", "5px", "margin-block-end", "5px")
has("gap", "1em 2em", "column-gap", "2em")
has("gap", "1em", "column-gap", "1em")
has("overflow", "hidden auto", "overflow-y", "auto")
has("place-items", "center", "justify-items", "center")
has("border-radius", "10px 5%", "border-bottom-right-radius", "10px")
has("border-radius", "10px / 20px", "border-top-left-radius", "10px 20px")
has("border-radius", "1px 2px 3px 4px / 5px", "border-bottom-left-radius", "4px 5px")
rejects("margin", "1px 2px 3px 4px 5px")
rejects("margin", "red")

echo "any-order:"
has("border", "1px solid red", "border-left-color", "red")
has("border", "solid", "border-top-width", "medium")
has("border", "dashed 2px", "border-right-width", "2px")
has("border", "none", "border-image-source", "none")
has("border-top", "thick double #32a1ce", "border-top-style", "double")
has("outline", "red", "outline-style", "none")
has("text-decoration", "underline dotted red", "text-decoration-style", "dotted")
has("text-decoration", "underline overline", "text-decoration-line", "underline overline")
has("list-style", "square inside", "list-style-position", "inside")
has("list-style", "none", "list-style-type", "none")
has("flex-flow", "column wrap", "flex-wrap", "wrap")
has("columns", "3 200px", "column-width", "200px")
has("border-block-start", "1px solid", "border-block-start-style", "solid")
rejects("border", "1px 2px solid")

echo "flex:"
has("flex", "1", "flex-basis", "0%")
has("flex", "1", "flex-shrink", "1")
has("flex", "none", "flex-shrink", "0")
has("flex", "auto", "flex-basis", "auto")
has("flex", "2 3 10px", "flex-shrink", "3")
has("flex", "30%", "flex-grow", "0")
has("flex", "1 200px", "flex-basis", "200px")

echo "font:"
has("font", "12px serif", "font-size", "12px")
has("font", "italic bold 12px/30px Georgia, serif", "font-weight", "bold")
has("font", "italic bold 12px/30px Georgia, serif", "line-height", "30px")
has("font", "italic bold 12px/30px Georgia, serif", "font-family", "Georgia, serif")
has("font", "italic bold 12px/30px Georgia, serif", "font-style", "italic")
has("font", "small-caps 1.2em \"Fira Sans\", sans-serif", "font-variant-caps", "small-caps")
has("font", "600 1rem system-ui", "font-weight", "600")
has("font", "caption", "font-family", "caption")
has("font", "12px serif", "font-variant-ligatures", "normal")
rejects("font", "bold serif")

echo "grid lines:"
has("grid-row", "1 / 3", "grid-row-end", "3")
has("grid-column", "main", "grid-column-end", "main")
has("grid-column", "2", "grid-column-end", "auto")
has("grid-area", "a", "grid-column-end", "a")
has("grid-area", "1 / 2 / 3", "grid-column-end", "auto")

echo "layers:"
has("transition", "opacity 0.3s ease-in 1s", "transition-delay", "1s")
has("transition", "opacity 0.3s, transform 1s linear", "transition-property", "opacity, transform")
has("transition", "opacity 0.3s, transform 1s linear", "transition-timing-function", "ease, linear")
has("animation", "spin 2s linear infinite", "animation-name", "spin")
has("animation", "spin 2s linear infinite", "animation-iteration-count", "infinite")
has("animation", "3s ease-in 1s 2 reverse both paused slidein", "animation-fill-mode", "both")
has("background", "red", "background-color", "red")
has("background", "url(a.png) no-repeat center / cover", "background-size", "cover")
has("background", "url(a.png) no-repeat center / cover", "background-position", "center")
has("background", "url(a.png) no-repeat center / cover", "background-repeat", "no-repeat")
has("background", "url(a.png), linear-gradient(red, blue) #fff", "background-image", "url(a.png), linear-gradient(red, blue)")
has("background", "url(a.png), linear-gradient(red, blue) #fff", "background-color", "#fff")
has("background", "content-box padding-box url(x)", "background-clip", "padding-box")
has("container", "card / inline-size", "container-type", "inline-size")

echo "keywords:"
has("margin", "inherit", "margin-top", "inherit")
has("border", "initial", "border-left-style", "initial")

echo (if fails == 0: "shorthand: all ok" else: "shorthand: " & $fails & " FAIL")
