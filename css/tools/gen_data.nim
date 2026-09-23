## gen_data.nim — build tool (runs under regular Nim, NOT nimony).
##
##   nim r tools/gen_data.nim
##
## Reads the MDN CSS data under data/*.json and emits src/css/data.nim as a set
## of compact, std/json-free string blobs. Downstream nimony code parses these
## blobs with a tiny hand-rolled splitter (see data_load.nim) — so no module in
## the shipped library depends on std/json, which keeps nimony compiles cheap.
##
## Blob format: entries separated by '\n', fields within an entry by '\t'.
## (CSS value-definition syntax never contains tab or newline, so this is safe.)
##
## To track a CSS-spec change: replace data/*.json and re-run this tool.

import std/[json, os, strutils, tables, algorithm]

const here = currentSourcePath().parentDir
const dataDir = here / ".." / "data"
const outFile = here / ".." / "data.nim"

proc load(name: string): JsonNode =
  parseFile(dataDir / name & ".json")

## unit dimension buckets, derived from the MDN "groups" tags.
proc unitDimension(name: string; groups: seq[string]): string =
  # `fr` is the <flex> unit, but MDN tags it only "CSS Units"/"CSS Grid Layout" —
  # there is no "CSS Flexible Lengths" group on it — so the group mapping below
  # bucketed it as "other" and every `<flex>` position in the grammar rejected
  # it. `grid-template-columns: 1fr` failed to validate as a result. Named here
  # because the dimension is a fact about the unit, not about MDN's tagging.
  if name == "fr": return "flex"
  for g in groups:
    case g
    of "CSS Lengths": return "length"
    of "CSS Angles": return "angle"
    of "CSS Times": return "time"
    of "CSS Frequencies": return "frequency"
    of "CSS Resolutions": return "resolution"
    of "CSS Flexible Lengths": return "flex"
    else: discard
  "other"

# --- spec facts the MDN data lacks --------------------------------------------
# Each patch names the spec it comes from. A syntax patch asserts that its
# `before` text is still present, so the day MDN fixes the data the generator
# fails loudly and the patch can be deleted instead of silently double-applying.

const extraLengthUnits = [
  # CSS Values 4: line-height, root-relative font, and the viewport variants
  "lh", "rlh", "rcap", "rch", "rex", "ric", "vi", "vb",
  "svw", "svh", "svi", "svb", "svmin", "svmax",
  "lvw", "lvh", "lvi", "lvb", "lvmin", "lvmax",
  "dvw", "dvh", "dvi", "dvb", "dvmin", "dvmax",
  # CSS Containment 3: container query lengths
  "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax"]

const syntaxPatches = [
  # CSS Generated Content 3: attr() is a <content-list> item
  ("content-list", "<leader()> ]+", "<leader()> | <attr()> ]+"),
]

proc patchSyntax(entries: var seq[(string, string)], key, before, after: string) =
  for e in entries.mitems:
    if e[0] == key:
      doAssert before in e[1], "stale patch: " & key & " no longer contains " & before
      e[1] = e[1].replace(before, after)
      return
  doAssert false, "patch target missing: " & key

proc emit(entries: seq[(string, string)]): string =
  ## Join (key,val) pairs into a "key\tval\n…" blob, sorted by key for
  ## deterministic output (so regenerating produces a clean diff).
  var e = entries
  e.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var parts: seq[string]
  for (k, v) in e:
    # VDS whitespace is insignificant — collapse tabs/newlines so they can't
    # collide with our field/record delimiters.
    let vv = v.replace('\t', ' ').replace('\n', ' ').replace("  ", " ").strip()
    doAssert '\t' notin k and '\n' notin k, "delimiter clash in key: " & k
    parts.add k & "\t" & vv
  parts.join("\n")

when isMainModule:
  # properties: name -> value-definition syntax
  var props: seq[(string, string)]
  # ... and the cascade facts the computed-style resolver needs:
  #   inherited:  name -> "1" when the property inherits by default
  #   initial:    name -> MDN initial value (a longhand only; prose sentinels such
  #               as "seeProse" are dropped at load time by re-validating them)
  #   longhands:  shorthand name -> space-separated longhand names
  var inherited, initials, longhands: seq[(string, string)]
  for name, body in load("properties").pairs:
    if body.hasKey("syntax"):
      props.add (name, body["syntax"].getStr)
    if body.hasKey("inherited") and body["inherited"].getBool:
      inherited.add (name, "1")
    if body.hasKey("initial"):
      let ini = body["initial"]
      if ini.kind == JString:
        initials.add (name, ini.getStr)
      elif ini.kind == JArray:
        var parts: seq[string]
        for x in ini: parts.add x.getStr
        longhands.add (name, parts.join(" "))

  # syntaxes: <name> -> value-definition syntax
  var synt: seq[(string, string)]
  for name, body in load("syntaxes").pairs:
    if body.hasKey("syntax"):
      synt.add (name, body["syntax"].getStr)

  for (k, b, a) in syntaxPatches: patchSyntax(synt, k, b, a)

  # basic data types: just the set of names (angle, color, length, …)
  var types: seq[(string, string)]
  for name, _ in load("types").pairs:
    types.add (name, "")

  # units: unit -> dimension bucket
  var units: seq[(string, string)]
  for name, body in load("units").pairs:
    var groups: seq[string]
    if body.hasKey("groups"):
      for g in body["groups"]: groups.add g.getStr
    units.add (name, unitDimension(name, groups))
  for u in extraLengthUnits:
    for (k, _) in units: doAssert k != u, "stale unit patch: MDN now has " & u
    units.add (u, "length")

  # at-rules: @name -> syntax
  var atrules: seq[(string, string)]
  # descriptors: "@rule/descriptor" -> value-definition syntax
  var descs: seq[(string, string)]
  for name, body in load("at-rules").pairs:
    atrules.add (name, (if body.hasKey("syntax"): body["syntax"].getStr else: ""))
    if body.hasKey("descriptors"):
      for d, dbody in body["descriptors"].pairs:
        if dbody.hasKey("syntax"):
          descs.add (name & "/" & d, dbody["syntax"].getStr)

  # selectors: split the pseudo-classes / pseudo-elements out of the concept list.
  # Key = bare name (no leading colons, no trailing "()"); val = "1" if functional.
  proc pseudoName(k: string): (string, bool) =
    var s = k
    while s.len > 0 and s[0] == ':': s = s[1 .. ^1]
    var fn = false
    if s.endsWith("()"): s = s[0 .. ^3]; fn = true
    (s, fn)
  var pclasses: seq[(string, string)]
  var pelements: seq[(string, string)]
  for name, _ in load("selectors").pairs:
    if name.startsWith("::"):
      let (n, fn) = pseudoName(name)
      if n.len > 0: pelements.add (n, (if fn: "1" else: ""))
    elif name.startsWith(":"):
      let (n, fn) = pseudoName(name)
      if n.len > 0: pclasses.add (n, (if fn: "1" else: ""))

  var o = """## GENERATED by tools/gen_data.nim from mdn-data css. DO NOT EDIT.
## Regenerate after editing data/*.json:  nim r tools/gen_data.nim
##
## Compact, std/json-free tables. Entries are '\n'-separated, fields '\t'-separated.
## Parse them with the helpers in data_load.nim.

"""
  o.add "const cssPropertyBlob* = " & escape(emit(props)) & "\n\n"
  o.add "const cssSyntaxBlob* = " & escape(emit(synt)) & "\n\n"
  o.add "const cssTypeBlob* = " & escape(emit(types)) & "\n\n"
  o.add "const cssUnitBlob* = " & escape(emit(units)) & "\n\n"
  o.add "const cssAtRuleBlob* = " & escape(emit(atrules)) & "\n\n"
  o.add "const cssPseudoClassBlob* = " & escape(emit(pclasses)) & "\n\n"
  o.add "const cssPseudoElementBlob* = " & escape(emit(pelements)) & "\n\n"
  o.add "const cssDescriptorBlob* = " & escape(emit(descs)) & "\n\n"
  o.add "const cssInheritedBlob* = " & escape(emit(inherited)) & "\n\n"
  o.add "const cssInitialBlob* = " & escape(emit(initials)) & "\n\n"
  o.add "const cssLonghandBlob* = " & escape(emit(longhands)) & "\n"

  writeFile(outFile, o)
  echo "wrote ", outFile
  echo "  properties:      ", props.len
  echo "  syntaxes:        ", synt.len
  echo "  types:           ", types.len
  echo "  units:           ", units.len
  echo "  at-rules:        ", atrules.len
  echo "  pseudo-classes:  ", pclasses.len
  echo "  pseudo-elements: ", pelements.len
  echo "  descriptors:     ", descs.len
  echo "  inherited:       ", inherited.len
  echo "  initial values:  ", initials.len
  echo "  shorthands:      ", longhands.len
