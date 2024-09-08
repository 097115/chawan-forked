import std/algorithm
import std/math
import std/options
import std/os
import std/strutils

when defined(posix):
  import std/posix

import types/opt
import utils/charcategory
import utils/map
import utils/twtuni

export charcategory

func onlyWhitespace*(s: string): bool =
  return AllChars - AsciiWhitespace notin s

func isControlChar*(u: uint32): bool =
  return u <= 0x1F or u == 0x7F

func getControlChar*(c: char): char =
  if c == '?':
    return char(127)
  return char(int(c) and 0x1F)

func getControlLetter*(c: char): char =
  if c == char(127):
    return '?'
  return char(int(c) or 0x40)

func toHeaderCase*(s: string): string =
  result = s
  var flip = true
  for c in result.mitems:
    if flip:
      c = c.toUpperAscii()
    else:
      c = c.toLowerAscii()
    flip = c == '-'

func snakeToKebabCase*(s: string): string =
  result = s
  for c in result.mitems:
    if c == '_':
      c = '-'

func kebabToCamelCase*(s: string): string =
  result = ""
  var flip = false
  for c in s:
    if c == '-':
      flip = true
    else:
      if flip:
        result &= c.toUpperAscii()
      else:
        result &= c
      flip = false

func camelToKebabCase*(s: string): string =
  result = ""
  for c in s:
    if c in AsciiUpperAlpha:
      result &= '-'
      result &= c.toLowerAscii()
    else:
      result &= c

func hexValue*(c: char): int =
  if c in AsciiDigit:
    return int(c) - int('0')
  if c in 'a'..'f':
    return int(c) - int('a') + 0xA
  if c in 'A'..'F':
    return int(c) - int('A') + 0xA
  return -1

func decValue*(c: char): int =
  if c in AsciiDigit:
    return int(c) - int('0')
  return -1

const HexCharsUpper = "0123456789ABCDEF"
const HexCharsLower = "0123456789abcdef"
func pushHex*(buf: var string; u: uint8) =
  buf &= HexCharsUpper[u shr 4]
  buf &= HexCharsUpper[u and 0xF]

func pushHex*(buf: var string; c: char) =
  buf.pushHex(uint8(c))

func toHexLower*(u: uint16): string =
  var x = u
  let len = if (u and 0xF000) != 0:
    4
  elif (u and 0x0F00) != 0:
    3
  elif (u and 0xF0) != 0:
    2
  else:
    1
  var s = newString(len)
  for i in countdown(len - 1, 0):
    s[i] = HexCharsLower[x and 0xF]
    x = x shr 4
  return s

func equalsIgnoreCase*(s1, s2: string): bool {.inline.} =
  return s1.cmpIgnoreCase(s2) == 0

func startsWithIgnoreCase*(s1, s2: openArray[char]): bool =
  if s1.len < s2.len: return false
  for i in 0 ..< s2.len:
    if s1[i].toLowerAscii() != s2[i].toLowerAscii():
      return false
  return true

func endsWithIgnoreCase*(s1, s2: string): bool =
  if s1.len < s2.len: return false
  for i in countdown(s2.high, 0):
    if s1[i].toLowerAscii() != s2[i].toLowerAscii():
      return false
  return true

func skipBlanks*(buf: openArray[char]; at: int): int =
  result = at
  while result < buf.len and buf[result] in AsciiWhitespace:
    inc result

func stripAndCollapse*(s: string): string =
  var space = false
  result = ""
  for i in s.skipBlanks(0) ..< s.len:
    if s[i] notin AsciiWhitespace:
      if space:
        result &= ' '
        space = false
      result &= s[i]
    elif not space:
      space = true
    else:
      result &= ' '

func until*(s: openArray[char]; c: set[char]; starti = 0): string =
  result = ""
  for i in starti ..< s.len:
    if s[i] in c:
      break
    result &= s[i]

func untilLower*(s: string; c: set[char]; starti = 0): string =
  result = ""
  for i in starti ..< s.len:
    if s[i] in c:
      break
    result.add(s[i].toLowerAscii())

func until*(s: string; c: char; starti = 0): string =
  return s.until({c}, starti)

func untilLower*(s: string; c: char; starti = 0): string =
  return s.untilLower({c}, starti)

func after*(s: string; c: set[char]): string =
  let i = s.find(c)
  if i != -1:
    return s.substr(i + 1)
  return ""

func after*(s: string; c: char): string = s.after({c})

func afterLast*(s: string; c: set[char]; n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(i + 1)
  return s

func afterLast*(s: string; c: char; n = 1): string = s.afterLast({c}, n)

func beforeLast*(s: string; c: set[char]; n = 1): string =
  var j = 0
  for i in countdown(s.high, 0):
    if s[i] in c:
      inc j
      if j == n:
        return s.substr(0, i)
  return s

func beforeLast*(s: string; c: char; n = 1): string = s.beforeLast({c}, n)

proc c_sprintf(buf, fm: cstring): cint
  {.header: "<stdio.h>", importc: "sprintf", varargs}

# From w3m
const SizeUnit = [
  cstring"b", cstring"kb", cstring"Mb", cstring"Gb", cstring"Tb", cstring"Pb",
  cstring"Eb", cstring"Zb", cstring"Bb", cstring"Yb"
]
func convertSize*(size: int): string =
  var sizepos = 0
  var csize = float32(size)
  while csize >= 999.495 and sizepos < SizeUnit.len:
    csize = csize / 1024.0
    inc sizepos
  result = newString(10)
  let f = floor(csize * 100 + 0.5) / 100
  discard c_sprintf(cstring(result), cstring("%.3g%s"), f, SizeUnit[sizepos])
  result.setLen(cstring(result).len)

# Implements https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#signed-integers
func parseIntImpl[T: SomeSignedInt](s: string; allowed: set[char]; radix: T):
    Option[T] =
  var sign: T = 1
  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1
    inc i
  elif i < s.len and s[i] == '+':
    inc i
  if i == s.len:
    return none(T)
  var integer: T = 0
  while i < s.len:
    if s[i] notin allowed:
      return none(T) # invalid
    let c = T(hexValue(s[i]))
    if unlikely((T.high - c) div radix < integer):
      return none(T) # overflow
    integer *= radix
    integer += c
    inc i
  return some(sign * integer)

func parseIntImpl[T: SomeSignedInt](s: string): Option[T] =
  return parseIntImpl[T](s, AsciiDigit, 10)

func parseInt32*(s: string): Option[int32] =
  return parseIntImpl[int32](s)

func parseInt64*(s: string): Option[int64] =
  return parseIntImpl[int64](s)

func parseOctInt64*(s: string): Option[int64] =
  return parseIntImpl[int64](s, AsciiOctDigit, 8)

func parseHexInt64*(s: string): Option[int64] =
  return parseIntImpl[int64](s, AsciiHexDigit, 16)

func parseUIntImpl[T: SomeUnsignedInt](s: string; allowSign: static bool;
    allowed: set[char]; radix: T): Option[T] =
  var i = 0
  when allowSign:
    if i < s.len and s[i] == '+':
      inc i
  if i == s.len:
    return none(T)
  var integer: T = 0
  while i < s.len:
    if s[i] notin allowed:
      return none(T) # invalid
    let c = T(hexValue(s[i]))
    if unlikely((T.high - c) div radix < integer):
      return none(T) # overflow
    integer *= radix
    integer += c
    inc i
  return some(integer)

func parseUIntImpl[T: SomeUnsignedInt](s: string; allowSign: static bool):
    Option[T] =
  return parseUIntImpl[T](s, allowSign, AsciiDigit, 10)

func parseUInt8*(s: string; allowSign: static bool): Option[uint8] =
  return parseUIntImpl[uint8](s, allowSign)

func parseUInt16*(s: string; allowSign: static bool): Option[uint16] =
  return parseUIntImpl[uint16](s, allowSign)

func parseUInt32*(s: string; allowSign: static bool): Option[uint32] =
  return parseUIntImpl[uint32](s, allowSign)

func parseOctUInt32*(s: string; allowSign: static bool): Option[uint32] =
  return parseUIntImpl[uint32](s, allowSign, AsciiOctDigit, 8)

func parseHexUInt32*(s: string; allowSign: static bool): Option[uint32] =
  return parseUIntImpl[uint32](s, allowSign, AsciiHexDigit, 16)

func parseUInt64*(s: string; allowSign: static bool): Option[uint64] =
  return parseUIntImpl[uint64](s, allowSign)

#TODO not sure where this algorithm is from...
# (probably from CSS)
func parseFloat64*(s: string): float64 =
  var sign = 1f64
  var t = 1
  var d = 0
  var integer: float64 = 0
  var f: float64 = 0
  var e: float64 = 0
  var i = 0
  if i < s.len and s[i] == '-':
    sign = -1f64
    inc i
  elif i < s.len and s[i] == '+':
    inc i
  while i < s.len and s[i] in AsciiDigit:
    integer *= 10
    integer += float64(decValue(s[i]))
    inc i
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] in AsciiDigit:
      f *= 10
      f += float64(decValue(s[i]))
      inc i
      inc d
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and s[i] == '-':
      t = -1
      inc i
    elif i < s.len and s[i] == '+':
      inc i
    while i < s.len and s[i] in AsciiDigit:
      e *= 10
      e += float64(decValue(s[i]))
      inc i
  return sign * (integer + f * pow(10, float64(-d))) * pow(10, (float64(t) * e))

const ControlPercentEncodeSet* = Controls + NonAscii
const FragmentPercentEncodeSet* = ControlPercentEncodeSet +
  {' ', '"', '<', '>', '`'}
const QueryPercentEncodeSet* = FragmentPercentEncodeSet - {'`'} + {'#'}
const SpecialQueryPercentEncodeSet* = QueryPercentEncodeSet + {'\''}
const PathPercentEncodeSet* = QueryPercentEncodeSet + {'?', '`', '{', '}'}
const UserInfoPercentEncodeSet* = PathPercentEncodeSet +
  {'/', ':', ';', '=', '@', '['..'^', '|'}
const ComponentPercentEncodeSet* = UserInfoPercentEncodeSet +
  {'$'..'&', '+', ','}
const ApplicationXWWWFormUrlEncodedSet* = ComponentPercentEncodeSet +
  {'!', '\''..')', '~'}
# used by pager
when DirSep == '\\':
  const LocalPathPercentEncodeSet* = Ascii - AsciiAlpha - AsciiDigit -
    {'.', '\\', '/'}
else:
  const LocalPathPercentEncodeSet* = Ascii - AsciiAlpha - AsciiDigit -
    {'.', '/'}

proc percentEncode*(append: var string; c: char; set: set[char];
    spaceAsPlus = false) {.inline.} =
  if spaceAsPlus and c == ' ':
    append &= '+'
  elif c notin set:
    append &= c
  else:
    append &= '%'
    append.pushHex(c)

proc percentEncode*(append: var string; s: string; set: set[char];
    spaceAsPlus = false) =
  for c in s:
    append.percentEncode(c, set, spaceAsPlus)

func percentEncode*(s: string; set: set[char]; spaceAsPlus = false): string =
  result.percentEncode(s, set, spaceAsPlus)

func percentDecode*(input: string; si = 0): string =
  var i = si
  while i < input.len:
    let c = input[i]
    if c != '%' or i + 2 >= input.len:
      result &= c
    else:
      let h1 = input[i + 1].hexValue
      let h2 = input[i + 2].hexValue
      if h1 == -1 or h2 == -1:
        result &= c
      else:
        result &= char((h1 shl 4) or h2)
        i += 2
    inc i

func htmlEscape*(s: openArray[char]): string =
  result = ""
  for c in s:
    case c
    of '<': result &= "&lt;"
    of '>': result &= "&gt;"
    of '&': result &= "&amp;"
    of '"': result &= "&quot;"
    of '\'': result &= "&apos;"
    else: result &= c

func dqEscape*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c == '"':
      result &= '\\'
    result &= c

#basically std join but with char
func join*(ss: openArray[string]; sep: char): string =
  if ss.len == 0:
    return ""
  var s = ss[0]
  for i in 1 ..< ss.len:
    s &= sep
    s &= ss[i]
  return s

proc passRealloc*(opaque, p: pointer; size: csize_t): pointer {.cdecl.} =
  return realloc(p, size)

# https://www.w3.org/TR/xml/#NT-Name
const NameStartCharRanges = [
  (0xC0u32, 0xD6u32),
  (0xD8u32, 0xF6u32),
  (0xF8u32, 0x2FFu32),
  (0x370u32, 0x37Du32),
  (0x37Fu32, 0x1FFFu32),
  (0x200Cu32, 0x200Du32),
  (0x2070u32, 0x218Fu32),
  (0x2C00u32, 0x2FEFu32),
  (0x3001u32, 0xD7FFu32),
  (0xF900u32, 0xFDCFu32),
  (0xFDF0u32, 0xFFFDu32),
  (0x10000u32, 0xEFFFFu32)
]
const NameCharRanges = [ # + NameStartCharRanges
  (0xB7u32, 0xB7u32),
  (0x0300u32, 0x036Fu32),
  (0x203Fu32, 0x2040u32)
]
const NameStartCharAscii = {':', '_'} + AsciiAlpha
const NameCharAscii = NameStartCharAscii + {'-', '.'} + AsciiDigit
func matchNameProduction*(s: string): bool =
  if s.len == 0:
    return false
  # NameStartChar
  var i = 0
  if s[i] in Ascii:
    if s[i] notin NameStartCharAscii:
      return false
    inc i
  else:
    let u = s.nextUTF8(i)
    if not NameStartCharRanges.isInRange(u):
      return false
  # NameChar
  while i < s.len:
    if s[i] in Ascii:
      if s[i] notin NameCharAscii:
        return false
      inc i
    else:
      let u = s.nextUTF8(i)
      if not NameStartCharRanges.isInRange(u) and not NameCharRanges.isInMap(u):
        return false
  return true

func matchQNameProduction*(s: string): bool =
  if s.len == 0:
    return false
  if s[0] == ':':
    return false
  if s[^1] == ':':
    return false
  var colon = false
  for i in 1 ..< s.len - 1:
    if s[i] == ':':
      if colon:
        return false
      colon = true
  return s.matchNameProduction()

func utf16Len*(s: string): int =
  result = 0
  for u in s.points:
    if u < 0x10000: # ucs-2
      result += 1
    else: # surrogate
      result += 2

proc expandPath*(path: string): string =
  if path.len == 0 or path[0] != '~':
    return path
  if path.len == 1:
    return getHomeDir()
  elif path[1] == '/':
    return getHomeDir() / path.substr(2)
  else:
    when defined(posix):
      let usr = path.until({'/'}, 1)
      let p = getpwnam(cstring(usr))
      if p != nil:
        return $p.pw_dir / path.substr(usr.len)
    return path

func deleteChars*(s: openArray[char]; todel: set[char]): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c notin todel:
      result &= c

func replaceControls*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c in Controls:
      result &= '^'
      result &= c.getControlLetter()
    else:
      result &= c

#https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#multipart/form-data-encoding-algorithm
proc makeCRLF*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len - 1:
    if s[i] == '\r' and s[i + 1] != '\n':
      result &= '\r'
      result &= '\n'
    elif s[i] != '\r' and s[i + 1] == '\n':
      result &= s[i]
      result &= '\r'
      result &= '\n'
      inc i
    else:
      result &= s[i]
    inc i
  if i < s.len:
    if s[i] == '\r':
      result &= '\r'
      result &= '\n'
    else:
      result &= s[i]

type IdentMapItem* = tuple[s: string; n: int]

func getIdentMap*[T: enum](e: typedesc[T]): seq[IdentMapItem] =
  result = @[]
  for e in T.low .. T.high:
    result.add(($e, int(e)))
  result.sort(proc(x, y: IdentMapItem): int = cmp(x.s, y.s))

func cmpItem(x: IdentMapItem; y: string): int =
  return x.s.cmp(y)

func strictParseEnum0(map: openArray[IdentMapItem]; s: string): int =
  let i = map.binarySearch(s, cmpItem)
  if i != -1:
    return map[i].n
  return -1

func strictParseEnum*[T: enum](s: string): Option[T] =
  const IdentMap = getIdentMap(T)
  let n = IdentMap.strictParseEnum0(s)
  if n != -1:
    return some(T(n))
  return none(T)

func parseEnumNoCase0*(map: openArray[IdentMapItem]; s: string): int =
  let i = map.binarySearch(s, proc(x: IdentMapItem; y: string): int =
    return x[0].cmpIgnoreCase(y)
  )
  if i != -1:
    return map[i].n
  return -1

func parseEnumNoCase*[T: enum](s: string): Opt[T] =
  const IdentMap = getIdentMap(T)
  let n = IdentMap.parseEnumNoCase0(s)
  if n != -1:
    return ok(T(n))
  return err()

proc getContentTypeAttr*(contentType, attrname: string): string =
  var i = contentType.find(';')
  if i == -1:
    return ""
  i = contentType.find(attrname, i)
  if i == -1:
    return ""
  i = contentType.skipBlanks(i + attrname.len)
  if i >= contentType.len or contentType[i] != '=':
    return ""
  i = contentType.skipBlanks(i + 1)
  var q = false
  var s = ""
  for c in contentType.toOpenArray(i, contentType.high):
    if q:
      s &= c
      q = false
    elif c == '\\':
      q = true
    elif c in AsciiWhitespace + {';'}:
      break
    else:
      s &= c
  return s

proc setContentTypeAttr*(contentType: var string; attrname, value: string) =
  var i = contentType.find(';')
  if i == -1:
    contentType &= ';' & attrname & '=' & value
    return
  i = contentType.find(attrname, i)
  if i == -1:
    contentType &= ';' & attrname & '=' & value
    return
  i = contentType.skipBlanks(i + attrname.len)
  if i >= contentType.len or contentType[i] != '=':
    contentType &= ';' & attrname & '=' & value
    return
  i = contentType.skipBlanks(i + 1)
  var q = false
  var j = i
  while j < contentType.len:
    let c = contentType[j]
    if q:
      q = false
    elif c == '\\':
      q = true
    elif c in AsciiWhitespace + {';'}:
      break
    inc j
  contentType[i..<j] = value

func atob(c: char): uint8 {.inline.} =
  # see RFC 4648 table
  if c in AsciiUpperAlpha:
    return uint8(c) - uint8('A')
  if c in AsciiLowerAlpha:
    return uint8(c) - uint8('a') + 26
  if c in AsciiDigit:
    return uint8(c) - uint8('0') + 52
  if c == '+':
    return 62
  if c == '/':
    return 63
  return uint8.high

func atob0*(data: string): Result[string, string] =
  var outs = newStringOfCap(data.len div 4 * 3)
  var buf: array[4, uint8]
  var i = 0
  var j = 0
  var pad = 0
  while true:
    i = data.skipBlanks(i)
    if i >= data.len:
      break
    if data[i] == '=':
      i = data.skipBlanks(i + 1)
      inc pad
      break
    buf[j] = atob(data[i])
    if buf[j] == uint8.high:
      return err("Invalid character in encoded string")
    if j == 3:
      let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
      let ob2 = (buf[1] shl 4) or (buf[2] shr 2) # 4 bits of b1 | 4 bits of b2
      let ob3 = (buf[2] shl 6) or buf[3]         # 2 bits of b2 | 6 bits of b3
      outs &= char(ob1)
      outs &= char(ob2)
      outs &= char(ob3)
      j = 0
    else:
      inc j
    inc i
  if i < data.len:
    if i < data.len and data[i] == '=':
      inc pad
      inc i
    i = data.skipBlanks(i)
  if pad > 0 and j + pad != 4:
    return err("Too much padding")
  if i < data.len:
    return err("Invalid character after encoded string")
  if j == 3:
    let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
    let ob2 = (buf[1] shl 4) or (buf[2] shr 2) # 4 bits of b1 | 4 bits of b2
    outs &= char(ob1)
    outs &= char(ob2)
  elif j == 2:
    let ob1 = (buf[0] shl 2) or (buf[1] shr 4) # 6 bits of b0 | 2 bits of b1
    outs &= char(ob1)
  elif j != 0:
    return err("Incorrect number of characters in encoded string")
  return ok(outs)
