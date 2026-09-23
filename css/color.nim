## color.nim — parse, convert and serialise CSS colours.
##
##   let c = parseColor("hsl(210 50% 40% / .5)")
##   c.ok; c.color.r; c.color.a       # sRGB 0..255, alpha 0..1
##   serializeColor(c.color)          # "rgba(51, 102, 153, 0.5)"
##   normalizeColor("rebeccapurple")  # "rgb(102, 51, 153)"
##   contrastRatio(parseColor("#777").color, parseColor("white").color)   # 4.48
##
## Understood: the 148 named colours, `transparent`, the system colours (light
## scheme), hex (3/4/6/8 digits), rgb()/rgba() and hsl()/hsla() in the legacy
## comma and the modern space syntax (percentages, `none`, `/ alpha`),
## hwb(), lab()/lch()/oklab()/oklch(), color(srgb|srgb-linear|display-p3|
## a98-rgb|prophoto-rgb|rec2020|xyz|xyz-d50|xyz-d65 …), and
## color-mix(in <space>, a p%, b q%) for the rectangular spaces and the
## polar ones (shorter hue). Everything converts to sRGB (gamut-clipped for
## serialisation). `currentcolor` is not a colour on its own — the caller
## resolves it.
##
## Serialisation follows CSSOM for the legacy sRGB forms: `rgb(r, g, b)` or
## `rgba(r, g, b, a)` with integer channels — what getComputedStyle reports.

import std/math

type
  Color* = object
    r*, g*, b*: float     ## sRGB, 0..255 (may exceed the gamut before clipping)
    a*: float             ## 0..1

proc lower(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add char(ord(c) + 32) else: result.add c
    inc i

proc trimS(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r'): inc a
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\n' or s[b-1] == '\r'): dec b
  result = ""
  var i = a
  while i < b:
    result.add s[i]
    inc i

proc hexV(c: char): int =
  if c >= '0' and c <= '9': ord(c) - ord('0')
  elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
  elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
  else: -1

const namedColorBlob =
  "aliceblue=f0f8ff antiquewhite=faebd7 aqua=00ffff aquamarine=7fffd4 " &
  "azure=f0ffff beige=f5f5dc bisque=ffe4c4 black=000000 " &
  "blanchedalmond=ffebcd blue=0000ff blueviolet=8a2be2 brown=a52a2a " &
  "burlywood=deb887 cadetblue=5f9ea0 chartreuse=7fff00 chocolate=d2691e " &
  "coral=ff7f50 cornflowerblue=6495ed cornsilk=fff8dc crimson=dc143c " &
  "cyan=00ffff darkblue=00008b darkcyan=008b8b darkgoldenrod=b8860b " &
  "darkgray=a9a9a9 darkgreen=006400 darkgrey=a9a9a9 darkkhaki=bdb76b " &
  "darkmagenta=8b008b darkolivegreen=556b2f darkorange=ff8c00 " &
  "darkorchid=9932cc darkred=8b0000 darksalmon=e9967a " &
  "darkseagreen=8fbc8f darkslateblue=483d8b darkslategray=2f4f4f " &
  "darkslategrey=2f4f4f darkturquoise=00ced1 darkviolet=9400d3 " &
  "deeppink=ff1493 deepskyblue=00bfff dimgray=696969 dimgrey=696969 " &
  "dodgerblue=1e90ff firebrick=b22222 floralwhite=fffaf0 " &
  "forestgreen=228b22 fuchsia=ff00ff gainsboro=dcdcdc ghostwhite=f8f8ff " &
  "gold=ffd700 goldenrod=daa520 gray=808080 green=008000 " &
  "greenyellow=adff2f grey=808080 honeydew=f0fff0 hotpink=ff69b4 " &
  "indianred=cd5c5c indigo=4b0082 ivory=fffff0 khaki=f0e68c " &
  "lavender=e6e6fa lavenderblush=fff0f5 lawngreen=7cfc00 " &
  "lemonchiffon=fffacd lightblue=add8e6 lightcoral=f08080 " &
  "lightcyan=e0ffff lightgoldenrodyellow=fafad2 lightgray=d3d3d3 " &
  "lightgreen=90ee90 lightgrey=d3d3d3 lightpink=ffb6c1 " &
  "lightsalmon=ffa07a lightseagreen=20b2aa lightskyblue=87cefa " &
  "lightslategray=778899 lightslategrey=778899 lightsteelblue=b0c4de " &
  "lightyellow=ffffe0 lime=00ff00 limegreen=32cd32 linen=faf0e6 " &
  "magenta=ff00ff maroon=800000 mediumaquamarine=66cdaa " &
  "mediumblue=0000cd mediumorchid=ba55d3 mediumpurple=9370db " &
  "mediumseagreen=3cb371 mediumslateblue=7b68ee mediumspringgreen=00fa9a " &
  "mediumturquoise=48d1cc mediumvioletred=c71585 midnightblue=191970 " &
  "mintcream=f5fffa mistyrose=ffe4e1 moccasin=ffe4b5 navajowhite=ffdead " &
  "navy=000080 oldlace=fdf5e6 olive=808000 olivedrab=6b8e23 " &
  "orange=ffa500 orangered=ff4500 orchid=da70d6 palegoldenrod=eee8aa " &
  "palegreen=98fb98 paleturquoise=afeeee palevioletred=db7093 " &
  "papayawhip=ffefd5 peachpuff=ffdab9 peru=cd853f pink=ffc0cb " &
  "plum=dda0dd powderblue=b0e0e6 purple=800080 rebeccapurple=663399 " &
  "red=ff0000 rosybrown=bc8f8f royalblue=4169e1 saddlebrown=8b4513 " &
  "salmon=fa8072 sandybrown=f4a460 seagreen=2e8b57 seashell=fff5ee " &
  "sienna=a0522d silver=c0c0c0 skyblue=87ceeb slateblue=6a5acd " &
  "slategray=708090 slategrey=708090 snow=fffafa springgreen=00ff7f " &
  "steelblue=4682b4 tan=d2b48c teal=008080 thistle=d8bfd8 tomato=ff6347 " &
  "turquoise=40e0d0 violet=ee82ee wheat=f5deb3 white=ffffff " &
  "whitesmoke=f5f5f5 yellow=ffff00 yellowgreen=9acd32 "


proc lookupNamed(name: string, hex: var string): bool =
  let key = name & "="
  var i = 0
  while i + key.len <= namedColorBlob.len:
    if (i == 0 or namedColorBlob[i-1] == ' '):
      var j = 0
      while j < key.len and namedColorBlob[i+j] == key[j]: inc j
      if j == key.len:
        hex = ""
        var k = i + key.len
        while k < namedColorBlob.len and namedColorBlob[k] != ' ':
          hex.add namedColorBlob[k]
          inc k
        return true
    inc i
  false

proc systemColor(name: string, hex: var string): bool =
  ## The light-scheme values browsers use for the CSS system colours.
  hex = ""
  case name
  of "canvas", "field", "buttonhighlight", "window": hex = "ffffff"
  of "canvastext", "fieldtext", "buttontext", "highlighttext", "marktext",
     "windowtext", "captiontext", "infotext", "menutext": hex = "000000"
  of "linktext": hex = "0000ee"
  of "visitedtext": hex = "551a8b"
  of "activetext": hex = "ff0000"
  of "buttonface", "buttonshadow", "threedface": hex = "f0f0f0"
  of "buttonborder": hex = "767676"
  of "graytext": hex = "6d6d6d"
  of "highlight": hex = "b5d5ff"
  of "selecteditem", "accentcolor": hex = "0075ff"
  of "selecteditemtext", "accentcolortext": hex = "ffffff"
  of "mark": hex = "ffff00"
  else: discard
  hex.len > 0

proc fromHex(h: string, c: var Color): bool =
  var d: seq[int] = @[]
  var i = 0
  while i < h.len:
    let v = hexV(h[i])
    if v < 0: return false
    d.add v
    inc i
  case d.len
  of 3, 4:
    c.r = float(d[0] * 17)
    c.g = float(d[1] * 17)
    c.b = float(d[2] * 17)
    c.a = (if d.len == 4: float(d[3] * 17) / 255.0 else: 1.0)
  of 6, 8:
    c.r = float(d[0] * 16 + d[1])
    c.g = float(d[2] * 16 + d[3])
    c.b = float(d[4] * 16 + d[5])
    c.a = (if d.len == 8: float(d[6] * 16 + d[7]) / 255.0 else: 1.0)
  else:
    return false
  true

# --- component parsing --------------------------------------------------------

type Comp = object
  v: float
  pct: bool
  none: bool
  unit: string      ## "", "deg", "rad", "grad", "turn"
  ok: bool

proc parseComp(t: string): Comp =
  let s = lower(trimS(t))
  if s == "none": return Comp(v: 0.0, none: true, ok: true)
  var i = 0
  var neg = false
  if i < s.len and (s[i] == '-' or s[i] == '+'):
    neg = s[i] == '-'
    inc i
  var r = 0.0
  var digits = 0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    r = r * 10.0 + float(ord(s[i]) - ord('0'))
    inc i
    inc digits
  if i < s.len and s[i] == '.':
    inc i
    var sc = 0.1
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      r = r + float(ord(s[i]) - ord('0')) * sc
      sc = sc * 0.1
      inc i
      inc digits
  if digits == 0: return Comp(ok: false)
  if i < s.len and s[i] == 'e':
    var j = i + 1
    var eneg = false
    if j < s.len and (s[j] == '-' or s[j] == '+'):
      eneg = s[j] == '-'
      inc j
    var e = 0
    var ed = 0
    while j < s.len and s[j] >= '0' and s[j] <= '9':
      e = e * 10 + (ord(s[j]) - ord('0'))
      inc j
      inc ed
    if ed > 0:
      r = r * pow(10.0, float(if eneg: -e else: e))
      i = j
  if neg: r = -r
  var unit = ""
  while i < s.len:
    unit.add s[i]
    inc i
  if unit == "%": return Comp(v: r, pct: true, ok: true)
  if unit == "" or unit == "deg" or unit == "rad" or unit == "grad" or unit == "turn":
    return Comp(v: r, unit: unit, ok: true)
  Comp(ok: false)

proc hueDeg(c: Comp): float =
  case c.unit
  of "rad": c.v * 180.0 / PI
  of "grad": c.v * 0.9
  of "turn": c.v * 360.0
  else: c.v

proc splitArgs(args: string, parts: var seq[string], alpha: var string, legacy: var bool): bool =
  ## "r g b / a" or "r, g, b, a" → components and alpha.
  parts = @[]
  alpha = ""
  legacy = false
  var cur = ""
  var depth = 0
  var sawSlash = false
  var i = 0
  var hasComma = false
  while i < args.len:
    if args[i] == ',' and depth == 0: hasComma = true
    if args[i] == '(': inc depth
    elif args[i] == ')': dec depth
    inc i
  depth = 0
  i = 0
  while i <= args.len:
    let c = (if i < args.len: args[i] else: ' ')
    let atEnd = i == args.len
    if c == '(':
      inc depth
      cur.add c
    elif c == ')':
      dec depth
      cur.add c
    elif depth == 0 and (atEnd or (hasComma and c == ',') or
                         (not hasComma and (c == ' ' or c == '\t' or c == '\n' or c == '/'))):
      let t = trimS(cur)
      if t.len > 0:
        if sawSlash: alpha = t
        else: parts.add t
      elif hasComma and not atEnd:
        return false
      cur = ""
      if c == '/':
        if sawSlash: return false
        sawSlash = true
    else:
      cur.add c
    inc i
  legacy = hasComma
  if hasComma and parts.len == 4:
    alpha = parts[3]
    parts = @[parts[0], parts[1], parts[2]]
  parts.len == 3

proc alphaOf(s: string, a: var float): bool =
  if s.len == 0:
    a = 1.0
    return true
  let c = parseComp(s)
  if not c.ok or c.unit.len > 0: return false
  a = (if c.none: 0.0 elif c.pct: c.v / 100.0 else: c.v)
  if a < 0.0: a = 0.0
  if a > 1.0: a = 1.0
  true

proc clamp01(x: float): float = (if x < 0.0: 0.0 elif x > 1.0: 1.0 else: x)

proc hslF(n: float, hh, ss, ll: float): float =
  let k = (n + hh / 30.0) mod 12.0
  let a = ss * min(ll, 1.0 - ll)
  ll - a * max(-1.0, min(min(k - 3.0, 9.0 - k), 1.0))

proc hslToRgb(h, s, l: float): tuple[r, g, b: float] =
  var hh = h mod 360.0
  if hh < 0.0: hh = hh + 360.0
  let ss = clamp01(s)
  let ll = clamp01(l)
  (hslF(0.0, hh, ss, ll) * 255.0, hslF(8.0, hh, ss, ll) * 255.0, hslF(4.0, hh, ss, ll) * 255.0)

proc hwbToRgb(h, w, bl: float): tuple[r, g, b: float] =
  var ww = clamp01(w)
  var bb = clamp01(bl)
  if ww + bb >= 1.0:
    let gray = ww / (ww + bb) * 255.0
    return (gray, gray, gray)
  let base = hslToRgb(h, 1.0, 0.5)
  let k = 1.0 - ww - bb
  (base.r * k + ww * 255.0, base.g * k + ww * 255.0, base.b * k + ww * 255.0)

# --- colour spaces ----------------------------------------------------------------

proc srgbToLinear(c: float): float =
  let a = abs(c)
  let s = (if c < 0.0: -1.0 else: 1.0)
  if a <= 0.04045: c / 12.92 else: s * pow((a + 0.055) / 1.055, 2.4)

proc linearToSrgb(c: float): float =
  let a = abs(c)
  let s = (if c < 0.0: -1.0 else: 1.0)
  if a <= 0.0031308: c * 12.92 else: s * (1.055 * pow(a, 1.0 / 2.4) - 0.055)

type V3 = tuple[x, y, z: float]

proc mul(m: array[9, float], v: V3): V3 =
  (m[0]*v.x + m[1]*v.y + m[2]*v.z, m[3]*v.x + m[4]*v.y + m[5]*v.z,
   m[6]*v.x + m[7]*v.y + m[8]*v.z)

const
  lrgbToXyz65 = [0.41239079926595934, 0.357584339383878, 0.1804807884018343,
                 0.21263900587151027, 0.715168678767756, 0.07219231536073371,
                 0.01933081871559182, 0.11919477979462598, 0.9505321522496607]
  xyz65ToLrgb = [3.2409699419045226, -1.537383177570094, -0.4986107602930034,
                 -0.9692436362808796, 1.8759675015077202, 0.04155505740717559,
                 0.05563007969699366, -0.20397695888897652, 1.0569715142428786]
  d50ToD65 = [0.955473421488075, -0.02309845494876471, 0.06325924320057072,
              -0.0283697093338637, 1.0099953980813041, 0.021041441191917323,
              0.012314014864481998, -0.020507649298898964, 1.330365926242124]
  d65ToD50 = [1.0479297925449969, 0.022946870601609652, -0.05019226628920524,
              0.02962780877005599, 0.9904344267538799, -0.017073799063418826,
              -0.009243040646204504, 0.015055191490298152, 0.7518742814281371]
  oklabToLms = [1.0, 0.3963377773761749, 0.2158037573099136,
                1.0, -0.1055613458156586, -0.0638541728258133,
                1.0, -0.0894841775298119, -1.2914855480194092]
  lmsToXyz65 = [1.2268798758459243, -0.5578149944602171, 0.2813910456659647,
                -0.0405757452148008, 1.1122868032803170, -0.0717110580655164,
                -0.0763729366746601, -0.4214933324022432, 1.5869240198367816]
  xyz65ToLms = [0.8190224379967030, 0.3619062600528904, -0.1288737815209879,
                0.0329836539323885, 0.9292868615863434, 0.0361446663506424,
                0.0481771893596242, 0.2642395317527308, 0.6335478284694309]
  lmsToOklab = [0.2104542683093140, 0.7936177747023054, -0.0040720430116193,
                1.9779985324311684, -2.4285922420485799, 0.4505937096174110,
                0.0259040424655478, 0.7827717124575296, -0.8086757549230774]
  p3ToXyz65 = [0.4865709486482162, 0.26566769316909306, 0.1982172852343625,
               0.2289745640697488, 0.6917385218365064, 0.079286914093745,
               0.0, 0.04511338185890264, 1.043944368900976]
  a98ToXyz65 = [0.5766690429101305, 0.1855582379065463, 0.1882286462349947,
                0.29734497525053605, 0.6273635662554661, 0.07529145849399788,
                0.02703136138641234, 0.07068885253582723, 0.9913375368376388]
  rec2020ToXyz65 = [0.6369580483012914, 0.14461690358620832, 0.1688809751641721,
                    0.2627002120112671, 0.6779980715188708, 0.05930171646986196,
                    0.0, 0.028072693049087428, 1.060985057710791]
  prophotoToXyz50 = [0.7977666449006423, 0.13518129740053308, 0.0313477341283922,
                     0.2880748288194013, 0.711835234241873, 0.00008993693872564,
                     0.0, 0.0, 0.8251046025104602]

proc xyz65ToSrgb(v: V3): Color =
  let l = mul(xyz65ToLrgb, v)
  Color(r: linearToSrgb(l.x) * 255.0, g: linearToSrgb(l.y) * 255.0,
        b: linearToSrgb(l.z) * 255.0, a: 1.0)

proc srgbToXyz65(c: Color): V3 =
  mul(lrgbToXyz65, (srgbToLinear(c.r / 255.0), srgbToLinear(c.g / 255.0),
                    srgbToLinear(c.b / 255.0)))

proc labToXyz50(l, a, b: float): V3 =
  const k = 24389.0 / 27.0
  const e = 216.0 / 24389.0
  let fy = (l + 16.0) / 116.0
  let fx = a / 500.0 + fy
  let fz = fy - b / 200.0
  let x = (if fx * fx * fx > e: fx * fx * fx else: (116.0 * fx - 16.0) / k)
  let y = (if l > k * e: pow((l + 16.0) / 116.0, 3.0) else: l / k)
  let z = (if fz * fz * fz > e: fz * fz * fz else: (116.0 * fz - 16.0) / k)
  (x * 0.3457 / 0.3585, y, z * (1.0 - 0.3457 - 0.3585) / 0.3585)

proc labF(t: float): float =
  const k = 24389.0 / 27.0
  const e = 216.0 / 24389.0
  if t > e: cbrt(t) else: (k * t + 16.0) / 116.0

proc xyz50ToLab(v: V3): V3 =
  const k = 24389.0 / 27.0
  const e = 216.0 / 24389.0
  let xr = v.x / (0.3457 / 0.3585)
  let yr = v.y
  let zr = v.z / ((1.0 - 0.3457 - 0.3585) / 0.3585)
  let fx = labF(xr)
  let fy = labF(yr)
  let fz = labF(zr)
  (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))

proc oklabToXyz65(l, a, b: float): V3 =
  let lms = mul(oklabToLms, (l, a, b))
  mul(lmsToXyz65, (lms.x * lms.x * lms.x, lms.y * lms.y * lms.y, lms.z * lms.z * lms.z))

proc xyz65ToOklab(v: V3): V3 =
  let lms = mul(xyz65ToLms, v)
  mul(lmsToOklab, (cbrt(lms.x), cbrt(lms.y), cbrt(lms.z)))

proc gammaA98(c: float): float =
  let s = (if c < 0.0: -1.0 else: 1.0)
  s * pow(abs(c), 563.0 / 256.0)

proc gammaProphoto(c: float): float =
  let a = abs(c)
  let s = (if c < 0.0: -1.0 else: 1.0)
  if a <= 16.0 / 512.0: c / 16.0 else: s * pow(a, 1.8)

proc gammaRec2020(c: float): float =
  const alpha = 1.09929682680944
  const beta = 0.018053968510807
  let a = abs(c)
  let s = (if c < 0.0: -1.0 else: 1.0)
  if a < beta * 4.5: c / 4.5 else: s * pow((a + alpha - 1.0) / alpha, 1.0 / 0.45)

proc predefined(space: string, r, g, b: float, ok: var bool): V3 =
  ## color(<space> r g b) → XYZ D65.
  ok = true
  case space
  of "srgb": srgbToXyz65(Color(r: r * 255.0, g: g * 255.0, b: b * 255.0, a: 1.0))
  of "srgb-linear": mul(lrgbToXyz65, (r, g, b))
  of "display-p3":
    mul(p3ToXyz65, (srgbToLinear(r), srgbToLinear(g), srgbToLinear(b)))
  of "a98-rgb": mul(a98ToXyz65, (gammaA98(r), gammaA98(g), gammaA98(b)))
  of "prophoto-rgb":
    mul(d50ToD65, mul(prophotoToXyz50, (gammaProphoto(r), gammaProphoto(g), gammaProphoto(b))))
  of "rec2020": mul(rec2020ToXyz65, (gammaRec2020(r), gammaRec2020(g), gammaRec2020(b)))
  of "xyz", "xyz-d65": (r, g, b)
  of "xyz-d50": mul(d50ToD65, (r, g, b))
  else:
    ok = false
    (0.0, 0.0, 0.0)

# --- the parser ----------------------------------------------------------------------

proc parseColor*(s: string): tuple[ok: bool, color: Color]

proc funcParts(s: string, name, args: var string): bool =
  var i = 0
  name = ""
  while i < s.len and s[i] != '(':
    name.add s[i]
    inc i
  if i >= s.len or s[s.len-1] != ')': return false
  args = ""
  var k = i + 1
  while k < s.len - 1:
    args.add s[k]
    inc k
  name = lower(trimS(name))
  true

proc channel(c: Comp, pctScale: float): float =
  if c.none: 0.0 elif c.pct: c.v * pctScale / 100.0 else: c.v

proc mixSpace(space: string, c1, c2: Color, p1, p2: float, ok: var bool): Color

proc parseColor*(s: string): tuple[ok: bool, color: Color] =
  ## Any CSS <color> except `currentcolor` → sRGB (+ alpha). Channels are not
  ## clipped here: out-of-gamut colours stay out of gamut until serialised.
  var c = Color(r: 0.0, g: 0.0, b: 0.0, a: 1.0)
  let t = trimS(s)
  let l = lower(t)
  if l.len == 0: return (false, c)
  if l == "transparent": return (true, Color(r: 0.0, g: 0.0, b: 0.0, a: 0.0))
  var hex = ""
  if l[0] == '#':
    var h = ""
    var i = 1
    while i < l.len:
      h.add l[i]
      inc i
    if fromHex(h, c): return (true, c)
    return (false, c)
  if lookupNamed(l, hex) or systemColor(l, hex):
    discard fromHex(hex, c)
    return (true, c)
  var name = ""
  var args = ""
  if not funcParts(t, name, args): return (false, c)
  var parts: seq[string] = @[]
  var alpha = ""
  var legacy = false
  case name
  of "rgb", "rgba":
    if not splitArgs(args, parts, alpha, legacy): return (false, c)
    let a0 = parseComp(parts[0])
    let a1 = parseComp(parts[1])
    let a2 = parseComp(parts[2])
    if not (a0.ok and a1.ok and a2.ok): return (false, c)
    if legacy and (a0.none or a1.none or a2.none): return (false, c)
    if legacy and not (a0.pct == a1.pct and a1.pct == a2.pct): return (false, c)
    c.r = channel(a0, 255.0)
    c.g = channel(a1, 255.0)
    c.b = channel(a2, 255.0)
    if not alphaOf(alpha, c.a): return (false, c)
    c.r = min(max(c.r, 0.0), 255.0)
    c.g = min(max(c.g, 0.0), 255.0)
    c.b = min(max(c.b, 0.0), 255.0)
    (true, c)
  of "hsl", "hsla":
    if not splitArgs(args, parts, alpha, legacy): return (false, c)
    let h = parseComp(parts[0])
    let sp = parseComp(parts[1])
    let lp = parseComp(parts[2])
    if not (h.ok and sp.ok and lp.ok): return (false, c)
    if legacy and (not sp.pct or not lp.pct): return (false, c)
    let rgb = hslToRgb(hueDeg(h), channel(sp, 100.0) / 100.0, channel(lp, 100.0) / 100.0)
    c.r = rgb.r
    c.g = rgb.g
    c.b = rgb.b
    if not alphaOf(alpha, c.a): return (false, c)
    (true, c)
  of "hwb":
    if not splitArgs(args, parts, alpha, legacy) or legacy: return (false, c)
    let h = parseComp(parts[0])
    let w = parseComp(parts[1])
    let b = parseComp(parts[2])
    if not (h.ok and w.ok and b.ok): return (false, c)
    let rgb = hwbToRgb(hueDeg(h), channel(w, 100.0) / 100.0, channel(b, 100.0) / 100.0)
    c.r = rgb.r
    c.g = rgb.g
    c.b = rgb.b
    if not alphaOf(alpha, c.a): return (false, c)
    (true, c)
  of "lab", "lch", "oklab", "oklch":
    if not splitArgs(args, parts, alpha, legacy) or legacy: return (false, c)
    let p0 = parseComp(parts[0])
    let p1 = parseComp(parts[1])
    let p2 = parseComp(parts[2])
    if not (p0.ok and p1.ok and p2.ok): return (false, c)
    var xyz: V3
    if name == "lab" or name == "lch":
      let L = channel(p0, 100.0)
      var a = 0.0
      var b = 0.0
      if name == "lab":
        a = channel(p1, 125.0)
        b = channel(p2, 125.0)
      else:
        let ch = channel(p1, 150.0)
        let hr = hueDeg(p2) * PI / 180.0
        a = ch * cos(hr)
        b = ch * sin(hr)
      xyz = mul(d50ToD65, labToXyz50(L, a, b))
    else:
      let L = channel(p0, 1.0)
      var a = 0.0
      var b = 0.0
      if name == "oklab":
        a = channel(p1, 0.4)
        b = channel(p2, 0.4)
      else:
        let ch = channel(p1, 0.4)
        let hr = hueDeg(p2) * PI / 180.0
        a = ch * cos(hr)
        b = ch * sin(hr)
      xyz = oklabToXyz65(L, a, b)
    c = xyz65ToSrgb(xyz)
    if not alphaOf(alpha, c.a): return (false, c)
    (true, c)
  of "color":
    var a2 = trimS(args)
    var sp = ""
    var i = 0
    while i < a2.len and a2[i] != ' ' and a2[i] != '\t':
      sp.add a2[i]
      inc i
    var rest = ""
    while i < a2.len:
      rest.add a2[i]
      inc i
    if not splitArgs(trimS(rest), parts, alpha, legacy) or legacy: return (false, c)
    let p0 = parseComp(parts[0])
    let p1 = parseComp(parts[1])
    let p2 = parseComp(parts[2])
    if not (p0.ok and p1.ok and p2.ok): return (false, c)
    var ok = false
    let xyz = predefined(lower(sp), channel(p0, 1.0), channel(p1, 1.0), channel(p2, 1.0), ok)
    if not ok: return (false, c)
    c = xyz65ToSrgb(xyz)
    if not alphaOf(alpha, c.a): return (false, c)
    (true, c)
  of "color-mix":
    # color-mix(in <space> [<hue-method> hue]?, <color> [<pct>]?, <color> [<pct>]?)
    var items: seq[string] = @[]
    var cur = ""
    var depth = 0
    var i = 0
    while i <= args.len:
      let ch = (if i < args.len: args[i] else: ',')
      if ch == '(': inc depth
      elif ch == ')': dec depth
      if ch == ',' and depth == 0:
        items.add trimS(cur)
        cur = ""
      else:
        cur.add ch
      inc i
    if items.len != 3: return (false, c)
    let head = lower(items[0])
    if head.len < 4 or head[0] != 'i' or head[1] != 'n' or head[2] != ' ': return (false, c)
    var space = ""
    var k = 3
    while k < head.len and head[k] == ' ': inc k
    while k < head.len and head[k] != ' ':
      space.add head[k]
      inc k
    var cols: seq[Color] = @[]
    var pcts: seq[float] = @[]
    var hasP: seq[bool] = @[]
    var j = 1
    while j <= 2:
      # split off a trailing/leading percentage
      let it = items[j]
      var pctTok = ""
      var colTok = it
      var sp2 = -1
      var dd = 0
      var m = 0
      while m < it.len:
        if it[m] == '(': inc dd
        elif it[m] == ')': dec dd
        elif it[m] == ' ' and dd == 0: sp2 = m
        inc m
      if sp2 >= 0:
        var a = ""
        var b = ""
        m = 0
        while m < it.len:
          if m < sp2: a.add it[m]
          elif m > sp2: b.add it[m]
          inc m
        if b.len > 0 and b[b.len-1] == '%':
          colTok = a
          pctTok = b
        elif a.len > 0 and a[a.len-1] == '%':
          colTok = b
          pctTok = a
      let pc = parseColor(colTok)
      if not pc.ok: return (false, c)
      cols.add pc.color
      if pctTok.len > 0:
        let pp = parseComp(pctTok)
        if not pp.ok or not pp.pct: return (false, c)
        pcts.add pp.v
        hasP.add true
      else:
        pcts.add 0.0
        hasP.add false
      inc j
    var p1 = pcts[0]
    var p2 = pcts[1]
    if not hasP[0] and not hasP[1]:
      p1 = 50.0
      p2 = 50.0
    elif not hasP[0]: p1 = 100.0 - p2
    elif not hasP[1]: p2 = 100.0 - p1
    let total = p1 + p2
    if total <= 0.0: return (false, c)
    var ok = true
    var mixed = mixSpace(space, cols[0], cols[1], p1 / total, p2 / total, ok)
    if not ok: return (false, c)
    if total < 100.0: mixed.a = mixed.a * total / 100.0
    (true, mixed)
  else:
    (false, c)

proc lerp(a, b, t: float): float = a + (b - a) * t

proc hueLerp(h1, h2, t: float): float =
  var d = h2 - h1
  if d > 180.0: d = d - 360.0
  elif d < -180.0: d = d + 360.0
  h1 + d * t

proc toHsl(c: Color): V3 =
  let r = c.r / 255.0
  let g = c.g / 255.0
  let b = c.b / 255.0
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let L = (mx + mn) / 2.0
  var H = 0.0
  var S = 0.0
  let d = mx - mn
  if d > 0.0:
    S = (if L == 0.0 or L == 1.0: 0.0 else: (mx - L) / min(L, 1.0 - L))
    if mx == r: H = (g - b) / d + (if g < b: 6.0 else: 0.0)
    elif mx == g: H = (b - r) / d + 2.0
    else: H = (r - g) / d + 4.0
    H = H * 60.0
  (H, S, L)

proc mixSpace(space: string, c1, c2: Color, p1, p2: float, ok: var bool): Color =
  ## Premultiplied interpolation in `space`; p1 + p2 = 1.
  ok = true
  let a = c1.a * p1 + c2.a * p2
  if a <= 0.0: return Color(r: 0.0, g: 0.0, b: 0.0, a: 0.0)
  case space
  of "srgb":
    Color(r: (c1.r * c1.a * p1 + c2.r * c2.a * p2) / a,
          g: (c1.g * c1.a * p1 + c2.g * c2.a * p2) / a,
          b: (c1.b * c1.a * p1 + c2.b * c2.a * p2) / a, a: a)
  of "srgb-linear", "xyz", "xyz-d65", "xyz-d50", "lab", "oklab":
    var v1: V3
    var v2: V3
    if space == "srgb-linear":
      v1 = (srgbToLinear(c1.r / 255.0), srgbToLinear(c1.g / 255.0), srgbToLinear(c1.b / 255.0))
      v2 = (srgbToLinear(c2.r / 255.0), srgbToLinear(c2.g / 255.0), srgbToLinear(c2.b / 255.0))
    elif space == "lab":
      v1 = xyz50ToLab(mul(d65ToD50, srgbToXyz65(c1)))
      v2 = xyz50ToLab(mul(d65ToD50, srgbToXyz65(c2)))
    elif space == "oklab":
      v1 = xyz65ToOklab(srgbToXyz65(c1))
      v2 = xyz65ToOklab(srgbToXyz65(c2))
    else:
      v1 = srgbToXyz65(c1)
      v2 = srgbToXyz65(c2)
    let m: V3 = ((v1.x * c1.a * p1 + v2.x * c2.a * p2) / a,
                 (v1.y * c1.a * p1 + v2.y * c2.a * p2) / a,
                 (v1.z * c1.a * p1 + v2.z * c2.a * p2) / a)
    var res: Color
    if space == "srgb-linear":
      res = Color(r: linearToSrgb(m.x) * 255.0, g: linearToSrgb(m.y) * 255.0,
                  b: linearToSrgb(m.z) * 255.0, a: 1.0)
    elif space == "lab": res = xyz65ToSrgb(mul(d50ToD65, labToXyz50(m.x, m.y, m.z)))
    elif space == "oklab": res = xyz65ToSrgb(oklabToXyz65(m.x, m.y, m.z))
    else: res = xyz65ToSrgb(m)
    res.a = a
    res
  of "oklch", "lch", "hsl":
    # polar: interpolate the hue the shorter way round
    var l1, c1v, h1, l2, c2v, h2: float
    if space == "oklch" or space == "lch":
      var v1: V3
      var v2: V3
      if space == "oklch":
        v1 = xyz65ToOklab(srgbToXyz65(c1))
        v2 = xyz65ToOklab(srgbToXyz65(c2))
      else:
        v1 = xyz50ToLab(mul(d65ToD50, srgbToXyz65(c1)))
        v2 = xyz50ToLab(mul(d65ToD50, srgbToXyz65(c2)))
      l1 = v1.x
      c1v = sqrt(v1.y * v1.y + v1.z * v1.z)
      h1 = arctan2(v1.z, v1.y) * 180.0 / PI
      l2 = v2.x
      c2v = sqrt(v2.y * v2.y + v2.z * v2.z)
      h2 = arctan2(v2.z, v2.y) * 180.0 / PI
      let L = lerp(l1, l2, p2)
      let C = lerp(c1v, c2v, p2)
      let H = hueLerp(h1, h2, p2) * PI / 180.0
      var res: Color
      if space == "oklch": res = xyz65ToSrgb(oklabToXyz65(L, C * cos(H), C * sin(H)))
      else: res = xyz65ToSrgb(mul(d50ToD65, labToXyz50(L, C * cos(H), C * sin(H))))
      res.a = a
      return res
    # hsl
    let a1 = toHsl(c1)
    let a2 = toHsl(c2)
    let rgb = hslToRgb(hueLerp(a1.x, a2.x, p2), lerp(a1.y, a2.y, p2), lerp(a1.z, a2.z, p2))
    Color(r: rgb.r, g: rgb.g, b: rgb.b, a: a)
  else:
    ok = false
    c1

# --- serialisation and helpers --------------------------------------------------------

proc clampByte(x: float): int =
  let r = int(floor(x + 0.5))
  if r < 0: 0 elif r > 255: 255 else: r

proc fmtAlpha(a: float): string =
  ## Shortest of up to 3 decimals: 0.5, 0.25, 0.333.
  let n = int(floor(a * 1000.0 + 0.5))
  if n >= 1000: return "1"
  if n <= 0: return "0"
  var s = $n
  while s.len < 3: s = "0" & s
  while s.len > 0 and s[s.len-1] == '0':
    var t = ""
    var i = 0
    while i < s.len - 1:
      t.add s[i]
      inc i
    s = t
  "0." & s

proc serializeColor*(c: Color): string =
  ## CSSOM serialisation of an sRGB colour: `rgb(r, g, b)` when opaque, else
  ## `rgba(r, g, b, a)`; channels are gamut-clipped and rounded.
  let r = clampByte(c.r)
  let g = clampByte(c.g)
  let b = clampByte(c.b)
  if c.a >= 0.9995: "rgb(" & $r & ", " & $g & ", " & $b & ")"
  else: "rgba(" & $r & ", " & $g & ", " & $b & ", " & fmtAlpha(c.a) & ")"

proc toHex*(c: Color): string =
  ## `#rrggbb` (or `#rrggbbaa` when not opaque).
  const d = "0123456789abcdef"
  result = "#"
  for v in [clampByte(c.r), clampByte(c.g), clampByte(c.b)]:
    result.add d[v div 16]
    result.add d[v mod 16]
  if c.a < 0.9995:
    let av = clampByte(c.a * 255.0)
    result.add d[av div 16]
    result.add d[av mod 16]

proc normalizeColor*(s: string): string =
  ## The computed-value spelling of a colour, or `s` unchanged when it is not
  ## one this module resolves (`currentcolor`, a var(), a relative colour…).
  let l = lower(trimS(s))
  if l == "currentcolor": return "currentcolor"
  let p = parseColor(s)
  if not p.ok: return s
  # lab/lch/oklab/oklch/color()/color-mix() keep their own space in CSSOM;
  # only the legacy sRGB forms (named, hex, rgb, hsl, hwb, system) become rgb()
  var fname = ""
  var i = 0
  while i < l.len and l[i] != '(':
    fname.add l[i]
    inc i
  if i < l.len and fname != "rgb" and fname != "rgba" and fname != "hsl" and
     fname != "hsla" and fname != "hwb":
    return s
  serializeColor(p.color)

proc relativeLuminance*(c: Color): float =
  ## WCAG 2 relative luminance of an (opaque) sRGB colour.
  let r = srgbToLinear(min(max(c.r, 0.0), 255.0) / 255.0)
  let g = srgbToLinear(min(max(c.g, 0.0), 255.0) / 255.0)
  let b = srgbToLinear(min(max(c.b, 0.0), 255.0) / 255.0)
  0.2126 * r + 0.7152 * g + 0.0722 * b

proc contrastRatio*(fg, bg: Color): float =
  ## WCAG 2 contrast ratio (1..21). `fg` is composited over `bg` when it is
  ## translucent.
  var f = fg
  if f.a < 1.0:
    f = Color(r: fg.r * fg.a + bg.r * (1.0 - fg.a), g: fg.g * fg.a + bg.g * (1.0 - fg.a),
              b: fg.b * fg.a + bg.b * (1.0 - fg.a), a: 1.0)
  let l1 = relativeLuminance(f)
  let l2 = relativeLuminance(bg)
  (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)

proc mixColors*(a, b: Color, weightB = 0.5, space = "oklab"): Color =
  ## `color-mix(in <space>, a, b weightB*100%)` as a value.
  var ok = true
  result = mixSpace(space, a, b, 1.0 - weightB, weightB, ok)

proc namedColors*(): seq[string] =
  ## The 148 CSS named colours.
  result = @[]
  var cur = ""
  var inName = true
  var i = 0
  while i < namedColorBlob.len:
    let c = namedColorBlob[i]
    if c == '=':
      result.add cur
      cur = ""
      inName = false
    elif c == ' ':
      inName = true
    elif inName:
      cur.add c
    inc i
