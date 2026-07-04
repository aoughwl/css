## tbootstrap — parse the entire Bootstrap stylesheet, validate every
## declaration against its MDN grammar and every selector against Selectors-4,
## and benchmark the throughput.
##
## Path comes from the BOOTSTRAP_CSS env var (default /tmp/bootstrap.css).

import std/syncio
import std/envvars
import std/monotimes
import css
import css/parse

type Report = object
  rules, decls, custom, dOk, dBad, sels, sOk, sBad: int
  badDecls: seq[string]
  badSels: seq[string]

proc walk(rules: seq[Rule], inKeyframes: bool, decls: var seq[Declaration],
          sels: var seq[string]) =
  var i = 0
  while i < rules.len:
    let r = rules[i]
    var j = 0
    while j < r.decls.len:
      decls.add r.decls[j]
      inc j
    if not r.isAtRule and not inKeyframes and r.prelude.len > 0:
      sels.add r.prelude
    let kf = inKeyframes or r.atKeyword == "keyframes"
    walk(r.children, kf, decls, sels)
    inc i

proc runOnce(src: string, collect: bool): Report =
  var rep = Report(rules: 0, decls: 0, custom: 0, dOk: 0, dBad: 0,
                   sels: 0, sOk: 0, sBad: 0, badDecls: @[], badSels: @[])
  let sheet = parseStylesheet(src)
  rep.rules = sheet.rules.len
  var decls: seq[Declaration] = @[]
  var sels: seq[string] = @[]
  walk(sheet.rules, false, decls, sels)
  rep.decls = decls.len
  rep.sels = sels.len
  var i = 0
  while i < decls.len:
    let d = decls[i]
    if d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-':
      inc rep.custom
    else:
      let r = validateValue(d.prop, d.value)
      if r.valid: inc rep.dOk
      else:
        inc rep.dBad
        if collect and rep.badDecls.len < 40:
          rep.badDecls.add d.prop & ": " & d.value & "   [" & r.error & "]"
    inc i
  i = 0
  while i < sels.len:
    let r = validateSelector(sels[i])
    if r.valid: inc rep.sOk
    else:
      inc rep.sBad
      if collect and rep.badSels.len < 40:
        rep.badSels.add sels[i] & "   [" & r.error & "]"
    inc i
  rep

let path = getEnv("BOOTSTRAP_CSS", "/tmp/bootstrap.css")
var src = ""
try:
  src = readFile(path)
except:
  echo "could not read " & path
  quit(1)
if src.len == 0:
  echo "empty / missing " & path
  quit(1)

echo "parsing " & path & "  (" & $src.len & " bytes)"
let rep = runOnce(src, true)
echo "top-level rules:   " & $rep.rules
echo "declarations:      " & $rep.decls
echo "style selectors:   " & $rep.sels
echo ""
echo "declarations:  " & $rep.dOk & " valid, " & $rep.dBad & " invalid, " &
     $rep.custom & " custom-props (skipped)"
echo "selectors:     " & $rep.sOk & " valid, " & $rep.sBad & " invalid"

var i = 0
if rep.badDecls.len > 0:
  echo ""
  echo "--- invalid declarations ---"
  while i < rep.badDecls.len:
    echo "  " & rep.badDecls[i]
    inc i
i = 0
if rep.badSels.len > 0:
  echo ""
  echo "--- invalid selectors ---"
  while i < rep.badSels.len:
    echo "  " & rep.badSels[i]
    inc i

# --- benchmark: three tiers matched 1:1 with the other tools ---------------
#   parse    — CSS text -> rules + declarations         (vs lightningcss/postcss/csstree parse)
#   values   — parse + MDN value-grammar match, decls    (vs csstree matchProperty)
#   full     — parse + values + math + fn-args + selectors (our full offering)

proc benchParse(src: string, iters: int): int64 =
  var checksum = 0
  let t0 = getMonoTime()
  var k = 0
  while k < iters:
    let s = parseStylesheet(src)
    checksum = checksum + s.rules.len
    inc k
  ticks(getMonoTime()) - ticks(t0)

proc benchValidate(src: string, iters: int, doSelectors: bool): int64 =
  var checksum = 0
  let t0 = getMonoTime()
  var k = 0
  while k < iters:
    let sheet = parseStylesheet(src)
    var decls: seq[Declaration] = @[]
    var sels: seq[string] = @[]
    walk(sheet.rules, false, decls, sels)
    var j = 0
    while j < decls.len:
      let d = decls[j]
      if not (d.prop.len >= 2 and d.prop[0] == '-' and d.prop[1] == '-'):
        if validateValue(d.prop, d.value).valid: checksum = checksum + 1
      inc j
    if doSelectors:
      j = 0
      while j < sels.len:
        if validateSelector(sels[j]).valid: checksum = checksum + 1
        inc j
    inc k
  ticks(getMonoTime()) - ticks(t0)

let iters = 20
let bytes = int64(src.len)

let parseNs = benchParse(src, iters)
setLevel(lvValues)
let valuesNs = benchValidate(src, iters, false)
setLevel(lvFull)
let fullNs = benchValidate(src, iters, true)

proc usPer(ns: int64): int64 = (ns div int64(iters)) div 1000
proc mbps(ns: int64): int64 =
  let us = usPer(ns)
  if us > 0: (bytes * 1000000) div us div 1024 div 1024 else: 0

echo ""
echo "--- benchmark (" & $iters & " iterations, " & $bytes & " bytes) ---"
echo "  tier      us/run     MB/s"
echo "  parse     " & $usPer(parseNs) & "        " & $mbps(parseNs)
echo "  values    " & $usPer(valuesNs) & "        " & $mbps(valuesNs) & "   (decls only, grammar match)"
echo "  full      " & $usPer(fullNs) & "        " & $mbps(fullNs) & "   (+ math + fn-args + selectors)"
