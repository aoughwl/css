## obf.nim — a small nimony source name-obfuscator.
##
## Given a set of nimony source files, it collects every identifier those files
## *define* (proc/func/template/iterator/converter/method names, type names, and
## enum-constant names), subtracts a keep-list, deterministically maps the rest to
## opaque names `o0, o1, o2, …`, and rewrites all the files with a single shared
## map so cross-file references stay consistent.
##
## It deliberately touches ONLY identifiers in normal code: a char-level scan skips
## string literals, char literals and comments, so runtime data and documentation
## are never rewritten. It injects NO control flow into real procs — the only thing
## it adds is a handful of never-called, side-effect-free decoy procs so the output
## looks busier. Execution STRUCTURE is preserved exactly; only NAMES change.
##
## This is why it is a useful test article: a tool that rides on execution structure
## rather than identifier names should behave identically before and after.

import std/[syncio, tables]

# ---------------------------------------------------------------------------
# Config — the files to obfuscate together (shared rename map), where to write
# the map, and which file receives the decoy procs. Edit these for another job.
# ---------------------------------------------------------------------------

const
  inFiles = ["/home/savant/aoughwl-css/obf/build/validator.nim",
             "/home/savant/aoughwl-css/obf/build/vds.nim"]
  mapPath  = "/home/savant/aoughwl-css/obf/map.txt"
  junkFile = "/home/savant/aoughwl-css/obf/build/validator.nim"

## Identifiers that must NEVER be renamed: nimony keywords / stdlib idents, the
## kept modules' exports (validator calls these by their real name), and the
## deliberate grounding anchors — validator's public API kept named on purpose.
const keepList = [
  # keywords / control flow / system idents
  "proc", "func", "template", "type", "var", "let", "const", "if", "elif",
  "else", "case", "of", "while", "for", "in", "result", "return", "discard",
  "echo", "add", "len", "high", "low", "inc", "dec", "seq", "string", "int",
  "bool", "char", "true", "false", "nil", "and", "or", "not", "import", "from",
  "export", "enum", "object", "tuple", "ref", "iterator", "converter", "method",
  "ord", "char", "when", "isMainModule", "tuple", "block", "break", "continue",
  # tables / sets ops
  "initTable", "getOrDefault", "hasKey", "contains", "incl", "excl",
  "initHashSet", "toOpenArray", "newSeq", "newSeqUninit", "clear", "keys",
  # kept-module exports (value_lex / data_load / data / math)
  "cssAtRuleBlob", "cssPropertyBlob", "cssPseudoClassBlob",
  "cssPseudoElementBlob", "cssSyntaxBlob", "cssTypeBlob", "cssUnitBlob",
  "isAtRule", "isFunctionalPseudoClass", "isFunctionalPseudoElement",
  "isMathFunc", "isProperty", "isPseudoClass", "isPseudoElement", "isSyntax",
  "isType", "isUnit", "lexValue", "propertySyntax", "syntaxOf", "unitDimension",
  "validateFunctionsIn", "validateMathFunc",
  # value_lex token kinds / fields (validator uses these by name)
  "VTok", "VTokKind", "vtIdent", "vtNumber", "vtDimension", "vtPercent",
  "vtFunc", "vtSlash", "vtComma", "vtHash", "vtString", "vtEof", "vtDelim",
  "kind", "text", "num", "args",
  # validator's PUBLIC API — the intentional grounding anchors, kept named
  "valueMatches", "validateValue", "setLevel", "level", "Level",
  "lvValues", "lvFull"]

# ---------------------------------------------------------------------------
# Tiny string helpers (implemented locally so the tool has no heavy deps)
# ---------------------------------------------------------------------------

func isIdentStart(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

func isIdentCont(c: char): bool =
  isIdentStart(c) or (c >= '0' and c <= '9')

proc indentOf(s: string): int =
  result = 0
  while result < s.len and s[result] == ' ': inc result

proc strip(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t'): inc a
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\r'): dec b
  result = ""
  var i = a
  while i < b:
    result.add s[i]; inc i

proc startsWith(s, p: string): bool =
  if s.len < p.len: return false
  var i = 0
  while i < p.len:
    if s[i] != p[i]: return false
    inc i
  true

proc containsSub(s, sub: string): bool =
  if sub.len == 0: return true
  if s.len < sub.len: return false
  var i = 0
  while i <= s.len - sub.len:
    var j = 0
    while j < sub.len and s[i+j] == sub[j]: inc j
    if j == sub.len: return true
    inc i
  false

## Read the identifier that begins `s` (assumes `s[0]` is an ident start).
proc leadingIdent(s: string): string =
  result = ""
  if s.len == 0 or not isIdentStart(s[0]): return
  var i = 0
  while i < s.len and isIdentCont(s[i]):
    result.add s[i]; inc i

## Skip spaces from `start`, then read the identifier there (e.g. name after a
## `proc ` / `type ` keyword).
proc identAfter(s: string, start: int): string =
  var i = start
  while i < s.len and s[i] == ' ': inc i
  result = ""
  while i < s.len and isIdentCont(s[i]):
    result.add s[i]; inc i

## If the (stripped) line looks like a type declaration `Name*  = …`, return the
## declared type name, else "". Field lines (`x*: T`) and `of`/`case` lines use
## `:` rather than `=`, so they correctly return "".
proc typeDeclName(s: string): string =
  if s.len == 0 or not isIdentStart(s[0]): return ""
  var i = 0
  var nm = ""
  while i < s.len and isIdentCont(s[i]):
    nm.add s[i]; inc i
  while i < s.len and s[i] == ' ': inc i
  if i < s.len and s[i] == '*': inc i
  while i < s.len and s[i] == ' ': inc i
  if i < s.len and s[i] == '=': return nm
  ""

proc lessStr(a, b: string): bool =
  var i = 0
  while i < a.len and i < b.len:
    if a[i] != b[i]: return a[i] < b[i]
    inc i
  a.len < b.len

proc splitLines(s: string): seq[string] =
  result = @[]
  var cur = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\n':
      result.add cur; cur = ""
    elif c == '\r':
      discard
    else:
      cur.add c
    inc i
  result.add cur

# ---------------------------------------------------------------------------
# Collection: gather the identifiers DEFINED across all input files.
# ---------------------------------------------------------------------------

var collected: seq[string] = @[]
var seen = initTable[string, bool]()

proc addDef(name: string) =
  if name.len == 0 or not isIdentStart(name[0]): return
  if seen.hasKey(name): return
  seen[name] = true
  collected.add name

const procKws = ["proc ", "func ", "template ", "iterator ", "converter ",
                 "method "]

## Add every enum constant on a (stripped) enum-member line: cut a trailing
## `#`/`##` comment, then split on commas and take the leading identifier of each.
proc collectEnumLine(s: string) =
  var body = ""
  var i = 0
  while i < s.len and s[i] != '#':
    body.add s[i]; inc i
  var piece = ""
  var j = 0
  while j <= body.len:
    if j == body.len or body[j] == ',':
      addDef(leadingIdent(strip(piece)))
      piece = ""
    else:
      piece.add body[j]
    inc j

## Line-oriented scanner. Tracks whether we are inside a `type` section and,
## within it, inside an `= enum` body, so type names and enum constants are
## collected while ordinary fields / case branches are skipped.
proc collectFile(src: string) =
  let lines = splitLines(src)
  var inType = false
  var typeIndent = 0
  var inEnum = false
  var enumIndent = 0
  var li = 0
  while li < lines.len:
    let line = lines[li]
    inc li
    let indent = indentOf(line)
    let s = strip(line)
    if s.len == 0: continue
    # leave enum / type scope on dedent
    if inEnum and indent <= enumIndent: inEnum = false
    if inType and indent <= typeIndent: inType = false
    if inEnum and indent > enumIndent:
      collectEnumLine(s)
      continue
    if inType and indent > typeIndent:
      let tn = typeDeclName(s)
      if tn.len > 0:
        addDef(tn)
        if containsSub(s, "enum"):
          inEnum = true; enumIndent = indent
      continue
    if s == "type":
      inType = true; typeIndent = indent; inEnum = false
      continue
    if startsWith(s, "type "):
      addDef(identAfter(s, 5))
      inType = true; typeIndent = indent
      if containsSub(s, "enum"):
        inEnum = true; enumIndent = indent
      continue
    var k = 0
    while k < procKws.len:
      if startsWith(s, procKws[k]):
        addDef(identAfter(s, procKws[k].len))
        break
      inc k

# ---------------------------------------------------------------------------
# Rewrite: whole-word identifier substitution that skips strings/chars/comments.
# ---------------------------------------------------------------------------

proc rewrite(src: string, rename: Table[string, string]): string =
  result = ""
  var i = 0
  let n = src.len
  while i < n:
    let c = src[i]
    if c == '#':
      # comment (covers `#` and `##`) to end of line
      while i < n and src[i] != '\n':
        result.add src[i]; inc i
    elif c == '"':
      # string literal (with \-escapes)
      result.add c; inc i
      while i < n and src[i] != '"':
        if src[i] == '\\' and i+1 < n:
          result.add src[i]; result.add src[i+1]; i += 2
        else:
          result.add src[i]; inc i
      if i < n:
        result.add src[i]; inc i          # closing quote
    elif c == '\'':
      # char literal (with \-escapes)
      result.add c; inc i
      while i < n and src[i] != '\'':
        if src[i] == '\\' and i+1 < n:
          result.add src[i]; result.add src[i+1]; i += 2
        else:
          result.add src[i]; inc i
      if i < n:
        result.add src[i]; inc i          # closing quote
    elif isIdentStart(c):
      var w = ""
      while i < n and isIdentCont(src[i]):
        w.add src[i]; inc i
      if rename.hasKey(w):
        result.add rename.getOrDefault(w, w)
      else:
        result.add w
    else:
      result.add c; inc i

# ---------------------------------------------------------------------------
# Decoy procs — never called, side-effect free, opaque names. They add textual
# bulk without touching the behaviour of any real proc (no injected control flow).
# ---------------------------------------------------------------------------

proc withJunk(src: string): string =
  result = src
  result.add "\n# --- decoy procs (never called, side-effect-free) ---\n"
  var i = 0
  while i < 5:
    result.add "proc oZ" & $i & "(): int =\n  result = " & $(42 + i) & "\n"
    inc i

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

proc run() {.raises.} =
  # 1. read all sources
  var sources: seq[string] = @[]
  var f = 0
  while f < inFiles.len:
    sources.add readFile(inFiles[f])
    inc f
  # 2. collect defined identifiers from every file (shared pool)
  f = 0
  while f < sources.len:
    collectFile(sources[f])
    inc f
  # 3. subtract the keep-list
  var keep = initTable[string, bool]()
  var ki = 0
  while ki < keepList.len:
    keep[keepList[ki]] = true
    inc ki
  var names: seq[string] = @[]
  var ci = 0
  while ci < collected.len:
    if not keep.hasKey(collected[ci]): names.add collected[ci]
    inc ci
  # 4. deterministic order: selection-sort into a fresh seq (avoids in-place
  #    element swaps), then map to o0, o1, o2, …
  var ordered: seq[string] = @[]
  var remaining = names
  while remaining.len > 0:
    var mi = 0
    var j = 1
    while j < remaining.len:
      if lessStr(remaining[j], remaining[mi]): mi = j
      inc j
    ordered.add remaining[mi]
    var nr: seq[string] = @[]
    var t = 0
    while t < remaining.len:
      if t != mi: nr.add remaining[t]
      inc t
    remaining = nr
  var rename = initTable[string, string]()
  var mapText = ""
  var idx = 0
  while idx < ordered.len:
    let opaque = "o" & $idx
    rename[ordered[idx]] = opaque
    mapText.add ordered[idx] & " -> " & opaque & "\n"
    inc idx
  writeFile(mapPath, mapText)
  # 5. rewrite every file with the shared map; append decoys to junkFile
  f = 0
  while f < inFiles.len:
    var outText = rewrite(sources[f], rename)
    if inFiles[f] == junkFile:
      outText = withJunk(outText)
    writeFile(inFiles[f], outText)
    inc f
  echo "obfuscated ", inFiles.len, " files, renamed ", names.len, " identifiers"

try:
  run()
except:
  echo "obf failed"
