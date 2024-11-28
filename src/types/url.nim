# See https://url.spec.whatwg.org/#url-parsing.
import std/algorithm
import std/options
import std/strutils
import std/tables

import io/bufreader
import io/bufwriter
import lib/punycode
import monoucha/fromjs
import monoucha/javascript
import monoucha/jserror
import monoucha/libunicode
import monoucha/quickjs
import types/opt
import utils/luwrap
import utils/map
import utils/twtstr

include res/map/idna_gen

type
  URLState = enum
    usFail, usDone, usSchemeStart, usNoScheme, usFile, usFragment, usAuthority,
    usPath, usQuery, usHost, usHostname, usPort, usPathStart

  HostType = enum
    htNone, htDomain, htIpv4, htIpv6, htOpaque

  URLSearchParams* = ref object
    list*: seq[tuple[name, value: string]]
    url: URL

  URL* = ref object
    scheme*: string
    username* {.jsget.}: string
    password* {.jsget.}: string
    opaquePath: bool
    hostType: HostType
    port: Option[uint16]
    hostname* {.jsget.}: string
    pathname* {.jsget.}: string
    search* {.jsget.}: string
    hash* {.jsget.}: string
    searchParamsInternal: URLSearchParams

  OriginType* = enum
    otOpaque, otTuple

  TupleOrigin* = tuple
    scheme: string
    hostname: string
    port: Option[uint16]
    domain: Option[string]

  Origin* = ref object
    case t*: OriginType
    of otOpaque:
      s: string
    of otTuple:
      tup: TupleOrigin

jsDestructor(URL)
jsDestructor(URLSearchParams)

# Forward declarations
proc parseURL*(input: string; base = none(URL); override = none(URLState)):
    Option[URL]
func serialize*(url: URL; excludeHash = false; excludePassword = false):
    string
func serializeip(ipv4: uint32): string
func serializeip(ipv6: array[8, uint16]): string

proc swrite*(writer: var BufferedWriter; url: URL) =
  if url != nil:
    writer.swrite(url.serialize())
  else:
    writer.swrite("")

proc sread*(reader: var BufferedReader; url: var URL) =
  var s: string
  reader.sread(s)
  if s == "":
    url = nil
  else:
    let x = parseURL(s)
    if x.isSome:
      url = x.get
    else:
      url = nil

# -1 if not special
# 0 if file
# > 0 if special
func findSpecialPort(scheme: string): int32 =
  case scheme
  of "https": return 443
  of "http": return 80
  of "wss": return 443
  of "ws": return 80
  of "file": return 0
  of "ftp": 21
  else:
    {.linearScanEnd.}
    return -1

func parseIpv6(input: openArray[char]): Option[array[8, uint16]] =
  var pieceindex = 0
  var compress = -1
  var pointer = 0
  var address: array[8, uint16]

  template c(i = 0): char = input[pointer + i]
  template has(i = 0): bool = (pointer + i < input.len)
  template failure(): Option[array[8, uint16]] = none(array[8, uint16])
  if c == ':':
    if not has(1) or c(1) != ':':
      return failure
    pointer += 2
    inc pieceindex
    compress = pieceindex
  while has:
    if pieceindex == 8:
      return failure
    if c == ':':
      if compress != -1:
        return failure
      inc pointer
      inc pieceindex
      compress = pieceindex
      continue
    var value: uint16 = 0
    var length = 0
    while length < 4 and has and c in AsciiHexDigit:
      value = value * 0x10 + uint16(c.hexValue)
      inc pointer
      inc length
    if has and c == '.':
      if length == 0:
        return failure
      pointer -= length
      if pieceindex > 6:
        return failure
      var numbersseen = 0
      while has:
        var ipv4piece = -1
        if numbersseen > 0:
          if c == '.' and numbersseen < 4:
            inc pointer
          else:
            return failure
        if not has or c notin AsciiDigit:
          return failure
        while has and c in AsciiDigit:
          if ipv4piece == -1:
            ipv4piece = c.decValue
          elif ipv4piece == 0:
            return failure
          else:
            ipv4piece = ipv4piece * 10 + c.decValue
          if ipv4piece > 255:
            return failure
          inc pointer
        address[pieceindex] = address[pieceindex] * 0x100 + uint16(ipv4piece)
        inc numbersseen
        if numbersseen == 2 or numbersseen == 4:
          inc pieceindex
      if numbersseen != 4:
        return failure
      break
    elif has:
      if c == ':':
        inc pointer
        if not has:
          return failure
      else:
        return failure
    address[pieceindex] = value
    inc pieceindex
  if compress != -1:
    var swaps = pieceindex - compress
    pieceindex = 7
    while pieceindex != 0 and swaps > 0:
      let sp = address[pieceindex]
      address[pieceindex] = address[compress + swaps - 1]
      address[compress + swaps - 1] = sp
      dec pieceindex
      dec swaps
  elif pieceindex != 8:
    return failure
  return address.some

func parseIpv4Number(s: string): uint32 =
  var input = s
  var R = 10
  if input.len >= 2 and input[0] == '0':
    if input[1] in {'x', 'X'}:
      input.delete(0..1)
      R = 16
    else:
      input.delete(0..0)
      R = 8
  if input == "":
    return 0
  case R
  of 8: return parseOctUInt32(input, allowSign = false).get(uint32.high)
  of 10: return parseUInt32(input, allowSign = false).get(uint32.high)
  of 16: return parseHexUInt32(input, allowSign = false).get(uint32.high)
  else: return 0

func parseIpv4(input: string): Option[uint32] =
  var numbers: seq[uint32] = @[]
  var prevEmpty = false
  var i = 0
  for part in input.split('.'):
    if i > 4 or prevEmpty:
      return none(uint32)
    inc i
    if part == "":
      prevEmpty = true
      continue
    let num = parseIpv4Number(part)
    if num notin 0u32..255u32:
      return none(uint32)
    numbers.add(num)
  if numbers[^1] >= 1u32 shl ((5 - numbers.len) * 8):
    return none(uint32)
  var ipv4 = uint32(numbers[^1])
  for i in 0 ..< numbers.high:
    let n = uint32(numbers[i])
    ipv4 += n * (1u32 shl ((3 - i) * 8))
  return some(ipv4)

const ForbiddenHostChars = {
  char(0x00), '\t', '\n', '\r', ' ', '#', '/', ':', '<', '>', '?', '@', '[',
  '\\', ']', '^', '|'
}
const ForbiddenDomainChars = ForbiddenHostChars + {'%'}
func opaqueParseHost(input: string): string =
  var o = ""
  for c in input:
    if c in ForbiddenHostChars:
      return ""
    o.percentEncode(c, ControlPercentEncodeSet)
  return o

func endsInNumber(input: string): bool =
  if input.len == 0:
    return false
  var i = input.high
  if input[i] == '.':
    dec i
  i = input.rfind('.', last = i)
  if i < 0:
    return false
  inc i
  if i + 1 < input.len and input[i] == '0' and input[i + 1] in {'x', 'X'}:
    # hex?
    i += 2
    while i < input.len and input[i] != '.':
      if input[i] notin AsciiHexDigit:
        return false
      inc i
  else:
    while i < input.len and input[i] != '.':
      if input[i] notin AsciiDigit:
        return false
      inc i
  return true

type
  IDNATableStatus = enum
    itsValid, itsIgnored, itsMapped, itsDeviation, itsDisallowed

func getIdnaTableStatus(u: uint32): IDNATableStatus =
  if u <= high(uint16):
    let u = uint16(u)
    if u in IgnoredLow:
      return itsIgnored
    if u in DisallowedLow or DisallowedRangesLow.isInRange(u):
      return itsDisallowed
    if MappedMapLow.isInMap(u):
      return itsMapped
  else:
    if u in IgnoredHigh:
      return itsIgnored
    if u in DisallowedHigh or DisallowedRangesHigh.isInRange(u):
      return itsDisallowed
    if MappedMapHigh.isInMap(u):
      return itsMapped
  return itsValid

func getIdnaMapped(u: uint32): string =
  if u <= high(uint16):
    let u = uint16(u)
    let n = MappedMapLow.searchInMap(u)
    let idx = MappedMapLow[n].idx
    let e = MappedMapData.find('\0', idx)
    return MappedMapData[idx ..< e]
  let n = MappedMapHigh.searchInMap(u)
  let idx = MappedMapHigh[n].idx
  let e = MappedMapData.find('\0', idx)
  return MappedMapData[idx ..< e]

proc processIdna(str: string; beStrict: bool): string =
  # CheckHyphens = false
  # CheckBidi = true
  # CheckJoiners = true
  # UseSTD3ASCIIRules = beStrict (but STD3 is not implemented)
  # Transitional_Processing = false
  # VerifyDnsLength = beStrict
  var mapped: seq[uint32] = @[]
  for u in str.points:
    let status = getIdnaTableStatus(u)
    case status
    of itsDisallowed: return "" #error
    of itsIgnored: discard
    of itsMapped: mapped &= getIdnaMapped(u).toPoints()
    of itsDeviation: mapped &= u
    of itsValid: mapped &= u
  if mapped.len == 0: return
  mapped = mapped.normalize()
  let luctx = LUContext()
  var labels = ""
  for label in mapped.toUTF8().split('.'):
    if label.startsWith("xn--"):
      try:
        let s = punycode.decode(label.substr("xn--".len))
        let x0 = s.toPoints()
        let x1 = x0.normalize()
        if x0 != x1:
          return "" #error
        # CheckHyphens is false
        if x0.len > 0 and luctx.isMark(x0[0]):
          return "" #error
        for u in x0:
          if u == uint32('.'):
            return "" #error
          let status = getIdnaTableStatus(u)
          if status in {itsDisallowed, itsIgnored, itsMapped}:
            return "" #error
          #TODO check joiners
          #TODO check bidi
        if labels.len > 0:
          labels &= '.'
        labels &= s
      except PunyError:
        return "" #error
    else:
      if labels.len > 0:
        labels &= '.'
      labels &= label
  return labels

proc unicodeToAscii(s: string; beStrict: bool): string =
  let processed = s.processIdna(beStrict)
  var labels = ""
  var all = 0
  for label in processed.split('.'):
    var s = ""
    if AllChars - Ascii in label:
      try:
        s = "xn--" & punycode.encode(label)
      except PunyError:
        return "" #error
    else:
      s = label
    if beStrict: # VerifyDnsLength
      let rl = s.pointLen()
      if rl notin 1..63:
        return ""
      all += rl
    if labels.len > 0:
      labels &= '.'
    labels &= s
  if beStrict: # VerifyDnsLength
    if all notin 1..253:
      return "" #error
  return labels

proc domainToAscii(domain: string; bestrict = false): string =
  var needsprocessing = false
  for s in domain.split('.'):
    if s.startsWith("xn--") or AllChars - Ascii in s:
      needsprocessing = true
      break
  if bestrict or needsprocessing:
    # Note: we don't implement STD3 separately, it's always true
    return domain.unicodeToAscii(bestrict)
  return domain.toLowerAscii()

proc parseHost(input: string; special: bool; hostType: var HostType): string =
  if input.len == 0:
    return ""
  if input[0] == '[':
    if input[^1] != ']' or input.len < 3:
      return ""
    let ipv6 = parseIpv6(input.toOpenArray(1, input.high - 1))
    if ipv6.isNone:
      hostType = htNone
      return ""
    hostType = htIpv6
    return ipv6.get.serializeip()
  if not special:
    hostType = htOpaque
    return opaqueParseHost(input)
  let domain = percentDecode(input)
  let asciiDomain = domain.domainToAscii()
  if asciiDomain == "" or ForbiddenDomainChars in asciiDomain:
    hostType = htNone
    return ""
  if asciiDomain.endsInNumber():
    let ipv4 = parseIpv4(asciiDomain)
    if ipv4.isNone:
      return ""
    hostType = htIpv4
    return ipv4.get.serializeip()
  hostType = htDomain
  return asciiDomain

proc shortenPath(url: URL) =
  if url.scheme == "file" and (url.pathname.len == 3 or
        url.pathname.len == 4 and url.pathname[2] == '/') and
      url.pathname[0] == '/' and url.pathname[1] in AsciiAlpha and
      url.pathname[2] == ':':
    return
  if url.pathname.len > 0:
    url.pathname.setLen(url.pathname.rfind('/'))

func includesCredentials(url: URL): bool =
  return url.username != "" or url.password != ""

func isWinDriveLetter(s: string): bool =
  return s.len == 2 and s[0] in AsciiAlpha and s[1] in {':', '|'}

proc parseOpaquePath(input: openArray[char]; pointer: var int; url: URL):
    URLState =
  while pointer < input.len:
    let c = input[pointer]
    if c == '?':
      url.search = "?"
      inc pointer
      return usQuery
    elif c == '#':
      url.hash = "#"
      inc pointer
      return usFragment
    else:
      url.pathname.percentEncode(c, ControlPercentEncodeSet)
    inc pointer
  return usDone

proc parseSpecialAuthorityIgnoreSlashes(input: openArray[char];
    pointer: var int): URLState =
  while pointer < input.len and input[pointer] in {'/', '\\'}:
    inc pointer
  return usAuthority

proc parseRelativeSlash(input: openArray[char]; pointer: var int;
    isSpecial: bool; base, url: URL): URLState =
  if isSpecial and pointer < input.len and input[pointer] in {'/', '\\'}:
    inc pointer
    return input.parseSpecialAuthorityIgnoreSlashes(pointer)
  if pointer < input.len and input[pointer] == '/':
    inc pointer
    return usAuthority
  url.username = base.username
  url.password = base.password
  url.hostname = base.hostname
  url.hostType = base.hostType
  url.port = base.port
  return usPath

proc parseRelative(input: openArray[char]; pointer: var int;
    specialPort: var int32; base, url: URL): URLState =
  assert base.scheme != "file"
  url.scheme = base.scheme
  specialPort = findSpecialPort(url.scheme)
  if pointer < input.len and input[pointer] == '/' or
      specialPort >= 0 and pointer < input.len and input[pointer] == '\\':
    inc pointer
    return input.parseRelativeSlash(pointer, specialPort >= 0, base, url)
  url.username = base.username
  url.password = base.password
  url.hostname = base.hostname
  url.hostType = base.hostType
  url.port = base.port
  url.pathname = base.pathname
  url.opaquePath = base.opaquePath
  url.search = base.search
  if pointer < input.len and input[pointer] == '?':
    url.search = "?"
    inc pointer
    return usQuery
  if pointer < input.len and input[pointer] == '#':
    url.hash = "#"
    inc pointer
    return usFragment
  url.search = ""
  url.shortenPath()
  return usPath

proc parseSpecialRelativeOrAuthority(input: openArray[char]; pointer: var int;
    specialPort: var int32; base, url: URL): URLState =
  if pointer + 1 < input.len and input[pointer] == '/' and
      input[pointer + 1] == '/':
    pointer += 2
    return input.parseSpecialAuthorityIgnoreSlashes(pointer)
  return input.parseRelative(pointer, specialPort, base, url)

proc parseScheme(input: openArray[char]; pointer: var int;
    specialPort: var int32; base: Option[URL]; url: URL; override: bool):
    URLState =
  var buffer = ""
  var i = pointer
  while i < input.len:
    let c = input[i]
    if c in AsciiAlphaNumeric + {'+', '-', '.'}:
      buffer &= c.toLowerAscii()
    elif c == ':':
      let port = findSpecialPort(buffer)
      if override:
        if (specialPort >= 0) != (port >= 0):
          return usNoScheme
        if (url.includesCredentials or url.port.isSome) and buffer == "file":
          return usNoScheme
        if url.hostType == htNone and url.scheme == "file":
          return usNoScheme
      url.scheme = buffer
      specialPort = port
      if override:
        if url.port.isSome and port != int32(url.port.get):
          url.port = none(uint16)
        return usDone
      pointer = i + 1
      if url.scheme == "file":
        return usFile
      if specialPort >= 0:
        if base.isSome and base.get.scheme == url.scheme:
          return input.parseSpecialRelativeOrAuthority(pointer, specialPort,
            base.get, url)
        # special authority slashes state
        if pointer + 1 < input.len and input[pointer] == '/' and
            input[pointer + 1] == '/':
          pointer += 2
        return input.parseSpecialAuthorityIgnoreSlashes(pointer)
      if i + 1 < input.len and input[i + 1] == '/':
        inc pointer
        # path or authority state
        if pointer < input.len and input[pointer] == '/':
          inc pointer
          return usAuthority
        return usPath
      url.opaquePath = true
      url.pathname = ""
      return input.parseOpaquePath(pointer, url)
    else:
      break
    inc i
  return usNoScheme

proc parseSchemeStart(input: openArray[char]; pointer: var int;
    specialPort: var int32; base: Option[URL]; url: URL; override: bool):
    URLState =
  var state = usNoScheme
  if pointer < input.len and input[pointer] in AsciiAlpha:
    # continue to scheme state
    state = input.parseScheme(pointer, specialPort, base, url, override)
  if state == usNoScheme:
    pointer = 0 # start over
  if override:
    return usDone
  if state == usNoScheme:
    if base.isNone:
      return usFail
    let base = base.get
    if base.opaquePath and (pointer >= input.len or input[pointer] != '#'):
      return usFail
    if base.opaquePath and pointer < input.len and input[pointer] == '#':
      url.scheme = base.scheme
      specialPort = findSpecialPort(url.scheme)
      url.pathname = base.pathname
      url.opaquePath = base.opaquePath
      url.search = base.search
      url.hash = "#"
      inc pointer
      return usFragment
    if base.scheme == "file":
      return usFile
    return input.parseRelative(pointer, specialPort, base, url)
  return state

proc parseAuthority(input: openArray[char]; pointer: var int; isSpecial: bool;
    url: URL): URLState =
  var atSignSeen = false
  var passwordSeen = false
  var buffer = ""
  var beforeBuffer = pointer
  while pointer < input.len:
    let c = input[pointer]
    if c in {'/', '?', '#'} or isSpecial and c == '\\':
      break
    if c == '@':
      if atSignSeen:
        buffer = "%40" & buffer
      atSignSeen = true
      for c in buffer:
        if c == ':' and not passwordSeen:
          passwordSeen = true
          continue
        if passwordSeen:
          url.password.percentEncode(c, UserInfoPercentEncodeSet)
        else:
          url.username.percentEncode(c, UserInfoPercentEncodeSet)
      buffer = ""
      beforeBuffer = pointer + 1
    else:
      buffer &= c
    inc pointer
  if atSignSeen and buffer == "":
    return usFail
  pointer = beforeBuffer
  return usHost

proc parseFileHost(input: openArray[char]; pointer: var int; isSpecial: bool;
    url: URL; override: bool): URLState =
  let buffer = input.until({'/', '\\', '?', '#'}, pointer)
  pointer += buffer.len
  if not override and buffer.isWinDriveLetter():
    return usPath
  if buffer == "":
    url.hostType = htDomain
    url.hostname = ""
  else:
    var t: HostType
    let hostname = parseHost(buffer, isSpecial, t)
    if hostname == "":
      return usFail
    url.hostType = t
    url.hostname = hostname
    if t == htDomain and hostname == "localhost":
      url.hostname = ""
  if override:
    return usFail
  return usPathStart

proc parseHostState(input: openArray[char]; pointer: var int; isSpecial: bool;
    url: URL; override: bool; state: URLState): URLState =
  if override and url.scheme == "file":
    return input.parseFileHost(pointer, isSpecial, url, override)
  var insideBrackets = false
  var buffer = ""
  while pointer < input.len:
    let c = input[pointer]
    if c == ':' and not insideBrackets:
      if override and state == usHostname:
        return usFail
      var t: HostType
      let hostname = parseHost(buffer, isSpecial, t)
      if hostname == "":
        return usFail
      url.hostname = hostname
      url.hostType = t
      inc pointer
      return usPort
    elif c in {'/', '?', '#'} or isSpecial and c == '\\':
      break
    else:
      if c == '[':
        insideBrackets = true
      elif c == ']':
        insideBrackets = false
      buffer &= c
    inc pointer
  if isSpecial and buffer == "":
    return usFail
  if override and buffer == "" and (url.includesCredentials or url.port.isSome):
    return usFail
  var t: HostType
  let hostname = parseHost(buffer, isSpecial, t)
  if hostname == "":
    return usFail
  url.hostname = hostname
  url.hostType = t
  if override:
    return usFail
  return usPathStart

proc parsePort(input: openArray[char]; pointer: var int; specialPort: int32;
    url: URL; override: bool): URLState =
  var buffer = ""
  var i = pointer
  while i < input.len:
    let c = input[i]
    if c in AsciiDigit:
      buffer &= c
    elif c in {'/', '?', '#'} or specialPort >= 0 and c == '\\' or override:
      break
    else:
      return usFail
    inc i
  pointer = i
  if buffer != "":
    let i = parseInt32(buffer).get(int32.high)
    # can't be negative, buffer only includes AsciiDigit
    if i > 65535:
      return usFail
    if specialPort == i:
      url.port = none(uint16)
    else:
      url.port = some(uint16(i))
  if override:
    return usFail
  return usPathStart

func startsWithWinDriveLetter(input: openArray[char]; i: int): bool =
  if i + 1 >= input.len:
    return false
  return input[i] in AsciiAlpha and input[i + 1] in {':', '|'}

proc parseFileSlash(input: openArray[char]; pointer: var int; base: Option[URL];
    url: URL; override: bool): URLState =
  if pointer < input.len and input[pointer] in {'/', '\\'}:
    inc pointer
    return input.parseFileHost(pointer, isSpecial = true, url, override)
  if base.isSome and base.get.scheme == "file":
    let base = base.get
    url.hostname = base.hostname
    url.hostType = base.hostType
    if not input.startsWithWinDriveLetter(pointer) and
        base.pathname.len > 3 and base.pathname[0] in AsciiAlpha and
        base.pathname[1] == ':' and base.pathname[2] == '/':
      url.pathname &= base.pathname.until('/') & '/'
  return usPath

proc parseFile(input: openArray[char]; pointer: var int; base: Option[URL];
    url: URL; override: bool): URLState =
  url.scheme = "file"
  url.hostname = ""
  url.hostType = htNone
  if pointer < input.len and input[pointer] in {'/', '\\'}:
    inc pointer
    return input.parseFileSlash(pointer, base, url, override)
  if base.isSome and base.get.scheme == "file":
    let base = base.get
    url.hostname = base.hostname
    url.hostType = base.hostType
    url.pathname = base.pathname
    url.opaquePath = base.opaquePath
    url.search = base.search
    if pointer < input.len:
      let c = input[pointer]
      if c == '?':
        url.search = "?"
        inc pointer
        return usQuery
      elif c == '#':
        url.hash = "#"
        inc pointer
        return usFragment
      else:
        url.search = ""
        if not input.startsWithWinDriveLetter(pointer):
          url.shortenPath()
        else:
          url.pathname = ""
  return usPath

proc parsePathStart(input: openArray[char]; pointer: var int; isSpecial: bool;
    url: URL; override: bool): URLState =
  if isSpecial:
    if pointer < input.len and input[pointer] in {'/', '\\'}:
      inc pointer
    return usPath
  if pointer < input.len:
    let c = input[pointer]
    if not override:
      if c == '?':
        url.search = "?"
        inc pointer
        return usQuery
      if c == '#':
        url.hash = "#"
        inc pointer
        return usFragment
    if c == '/':
      inc pointer
    return usPath
  if override and url.hostType == htNone:
    url.pathname &= '/'
    inc pointer
  return usDone

proc parsePath(input: openArray[char]; pointer: var int; isSpecial: bool;
    url: URL; override: bool): URLState =
  var state = usPath
  var buffer = ""
  template is_single_dot_path_segment(s: string): bool =
    s == "." or s.equalsIgnoreCase("%2e")
  template is_double_dot_path_segment(s: string): bool =
    s == ".." or s.equalsIgnoreCase(".%2e") or s.equalsIgnoreCase("%2e.") or
      s.equalsIgnoreCase("%2e%2e")
  while pointer < input.len:
    let c = input[pointer]
    if c == '/' or isSpecial and c == '\\' or not override and c in {'?', '#'}:
      if c == '?':
        url.search = "?"
        state = usQuery
        inc pointer
        break
      elif c == '#':
        url.hash = "#"
        state = usFragment
        inc pointer
        break
      let slashCond = c != '/' and (not isSpecial or c != '\\')
      if buffer.is_double_dot_path_segment:
        url.shortenPath()
        if slashCond:
          url.pathname &= '/'
      elif buffer.is_single_dot_path_segment and slashCond:
        url.pathname &= '/'
      elif not buffer.is_single_dot_path_segment:
        if url.scheme == "file" and url.pathname == "" and
            buffer.isWinDriveLetter():
          buffer[1] = ':'
        url.pathname &= '/'
        url.pathname &= buffer
      buffer = ""
    else:
      buffer.percentEncode(c, PathPercentEncodeSet)
    inc pointer
  let slashCond = pointer >= input.len or input[pointer] != '/' and
    (not isSpecial or input[pointer] != '\\')
  if buffer.is_double_dot_path_segment:
    url.shortenPath()
    if slashCond:
      url.pathname &= '/'
  elif buffer.is_single_dot_path_segment and slashCond:
    url.pathname &= '/'
  elif not buffer.is_single_dot_path_segment:
    if url.scheme == "file" and url.pathname == "" and
        buffer.isWinDriveLetter():
      buffer[1] = ':'
    url.pathname &= '/'
    url.pathname &= buffer
  return state

proc parseQuery(input: openArray[char]; pointer: var int; isSpecial: bool;
    url: URL; override: bool): URLState =
  #TODO encoding
  var buffer = ""
  var i = pointer
  while i < input.len:
    let c = input[i]
    if not override and c == '#':
      break
    buffer &= c
    inc i
  pointer = i
  let set = if isSpecial:
    SpecialQueryPercentEncodeSet
  else:
    QueryPercentEncodeSet
  url.search.percentEncode(buffer, set)
  if pointer < input.len:
    url.hash = "#"
    inc pointer
    return usFragment
  return usDone

proc basicParseURL0(input: openArray[char]; base: Option[URL]; url: URL;
    stateOverride: Option[URLState]): Option[URL] =
  var pointer = 0
  # The URL is special if this is >= 0.
  # A special port of "0" means "no port" (i.e. file scheme).
  var specialPort = findSpecialPort(url.scheme)
  let input = input.deleteChars({'\n', '\t'})
  let override = stateOverride.isSome
  var state = stateOverride.get(usSchemeStart)
  if state == usSchemeStart:
    state = input.parseSchemeStart(pointer, specialPort, base, url, override)
  if state == usAuthority:
    state = input.parseAuthority(pointer, specialPort >= 0, url)
  if state in {usHost, usHostname}:
    state = input.parseHostState(pointer, specialPort >= 0, url, override,
      state)
  if state == usPort:
    state = input.parsePort(pointer, specialPort, url, override)
  if state == usFile:
    specialPort = 0 #TODO not sure why this is needed...
    state = input.parseFile(pointer, base, url, override)
  if state == usPathStart:
    state = input.parsePathStart(pointer, specialPort >= 0, url, override)
  if state == usPath:
    state = input.parsePath(pointer, specialPort >= 0, url, override)
  if state == usQuery:
    state = input.parseQuery(pointer, specialPort >= 0, url, override)
  if state == usFragment:
    while pointer < input.len:
      url.hash.percentEncode(input[pointer], FragmentPercentEncodeSet)
      inc pointer
  if state == usFail:
    return none(URL)
  return some(url)

#TODO encoding
proc basicParseURL(input: string; base = none(URL); url: URL = nil;
    stateOverride = none(URLState)): Option[URL] =
  if url != nil:
    return input.basicParseURL0(base, url, stateOverride)
  let url = URL()
  const NoStrip = AllChars - C0Controls - {' '}
  let starti0 = input.find(NoStrip)
  let starti = if starti0 == -1: 0 else: starti0
  let endi0 = input.rfind(NoStrip)
  let endi = if endi0 == -1: input.high else: endi0
  return input.toOpenArray(starti, endi).basicParseURL0(base, url,
    stateOverride)

proc parseURL*(input: string; base = none(URL); override = none(URLState)):
    Option[URL] =
  let url = basicParseURL(input, base, stateOverride = override)
  if url.isNone:
    return url
  if url.get.scheme == "blob":
    #TODO blob urls
    discard
  return url

proc parseJSURL*(s: string; base = none(URL)): JSResult[URL] =
  let url = parseURL(s, base)
  if url.isNone:
    return errTypeError(s & " is not a valid URL")
  return ok(url.get)

func serializeip(ipv4: uint32): string =
  result = ""
  var n = ipv4
  for i in 1..4:
    result = $(n mod 256) & result
    if i != 4:
      result = '.' & result
    n = n div 256
  assert n == 0

func findZeroSeq(ipv6: array[8, uint16]): int =
  var maxi = -1
  var maxn = 0
  var newi = -1
  var newn = 1
  for i, n in ipv6:
    if n == 0:
      inc newn
      if newi == -1:
        newi = i
    else:
      if newn > maxn:
        maxn = newn
        maxi = newi
      newn = 0
      newi = -1
  if newn > maxn:
    return newi
  return maxi

func serializeip(ipv6: array[8, uint16]): string =
  let compress = findZeroSeq(ipv6)
  var ignore0 = false
  result = "["
  for i, n in ipv6:
    if ignore0:
      if n == 0:
        continue
      else:
        ignore0 = false
    if i == compress:
      if i == 0:
        result &= "::"
      else:
        result &= ':'
      ignore0 = true
      continue
    result &= toHexLower(n)
    if i != ipv6.high:
      result &= ':'
  result &= ']'

func serialize*(url: URL; excludeHash = false; excludePassword = false):
    string =
  result = url.scheme & ':'
  if url.hostType != htNone:
    result &= "//"
    if url.includesCredentials:
      result &= url.username
      if not excludePassword and url.password != "":
        result &= ':' & url.password
      result &= '@'
    result &= url.hostname
    if url.port.isSome:
      result &= ':' & $url.port.get
  elif not url.opaquePath and url.pathname.len >= 2 and url.pathname[1] == '/':
    result &= "/."
  result &= url.pathname
  result &= url.search
  if not excludeHash:
    result &= url.hash

func serialize*(url: Option[URL]): string =
  if url.isNone:
    return ""
  return url.get.serialize()

func equals*(a, b: URL; excludeHash = false): bool =
  return a.serialize(excludeHash) == b.serialize(excludeHash)

func `$`*(url: URL): string {.jsfunc.} = url.serialize()

func href(url: URL): string {.jsfget.} =
  return $url

func toJSON(url: URL): string {.jsfget.} =
  return $url

# from a to b
proc cloneInto(a, b: URL) =
  b[] = a[]
  b.searchParamsInternal = nil

proc newURL*(url: URL): URL =
  result = URL()
  url.cloneInto(result)

proc setHref(ctx: JSContext; url: URL; s: string) {.jsfset: "href".} =
  let purl = basicParseURL(s)
  if purl.isSome:
    purl.get.cloneInto(url)
  else:
    JS_ThrowTypeError(ctx, "%s is not a valid URL", s)

func isIP*(url: URL): bool =
  return url.hostType in {htIpv4, htIpv6}

# https://url.spec.whatwg.org/#urlencoded-parsing
proc parseFromURLEncoded(input: string): seq[(string, string)] =
  result = @[]
  for s in input.split('&'):
    if s == "":
      continue
    var name = s.until('=')
    var value = s.after('=')
    for c in name.mitems:
      if c == '+':
        c = ' '
    for c in value.mitems:
      if c == '+':
        c = ' '
    result.add((name.percentDecode(), value.percentDecode()))

# https://url.spec.whatwg.org/#urlencoded-serializing
proc serializeFormURLEncoded*(kvs: seq[(string, string)]; spaceAsPlus = true):
    string =
  result = ""
  for (name, value) in kvs:
    if result.len > 0:
      result &= '&'
    result.percentEncode(name, ApplicationXWWWFormUrlEncodedSet, spaceAsPlus)
    result &= '='
    result.percentEncode(value, ApplicationXWWWFormUrlEncodedSet, spaceAsPlus)

proc newURLSearchParams(ctx: JSContext; init: varargs[JSValue]):
    Opt[URLSearchParams] {.jsctor.} =
  let params = URLSearchParams()
  if init.len > 0:
    let val = init[0]
    if ctx.fromJS(val, params.list).isSome:
      discard
    elif (var t: Table[string, string]; ctx.fromJS(val, t).isSome):
      for k, v in t:
        params.list.add((k, v))
    else:
      var res: string
      ?ctx.fromJS(val, res)
      if res.len > 0 and res[0] == '?':
        res.delete(0..0)
      params.list = parseFromURLEncoded(res)
  return ok(params)

proc searchParams(url: URL): URLSearchParams {.jsfget.} =
  if url.searchParamsInternal == nil:
    url.searchParamsInternal = URLSearchParams(
      list: parseFromURLEncoded(url.search.substr(1)),
      url: url
    )
  return url.searchParamsInternal

proc `$`*(params: URLSearchParams): string {.jsfunc.} =
  return serializeFormURLEncoded(params.list)

proc update(params: URLSearchParams) =
  if params.url == nil:
    return
  let serializedQuery = $params
  if serializedQuery == "":
    params.url.search = ""
  else:
    params.url.search = "?" & serializedQuery

proc append(params: URLSearchParams; name, value: string) {.jsfunc.} =
  params.list.add((name, value))
  params.update()

proc delete(params: URLSearchParams; name: string) {.jsfunc.} =
  for i in countdown(params.list.high, 0):
    if params.list[i][0] == name:
      params.list.delete(i)
  params.update()

proc get(params: URLSearchParams; name: string): Option[string] {.jsfunc.} =
  for it in params.list:
    if it.name == name:
      return some(it.value)
  return none(string)

proc getAll(params: URLSearchParams; name: string): seq[string] {.jsfunc.} =
  result = @[]
  for it in params.list:
    if it.name == name:
      result.add(it.value)

proc has(params: URLSearchParams; name: string; value = none(string)): bool
    {.jsfunc.} =
  for it in params.list:
    if it.name == name:
      if value.isNone or value.get == it.value:
        return true
  return false

proc set(params: URLSearchParams; name, value: string) {.jsfunc.} =
  for param in params.list.mitems:
    if param.name == name:
      param.value = value
      break

proc parseAPIURL(s: string; base: Option[string]): JSResult[URL] =
  let baseURL = if base.isSome:
    let x = parseURL(base.get)
    if x.isNone:
      return errTypeError(base.get & " is not a valid URL")
    x
  else:
    none(URL)
  return parseJSURL(s, baseURL)

proc newURL*(s: string; base: Option[string] = none(string)):
    JSResult[URL] {.jsctor.} =
  return parseAPIURL(s, base)

proc origin*(url: URL): Origin =
  case url.scheme
  of "blob":
    #TODO
    let pathURL = parseURL(url.pathname)
    if pathURL.isNone:
      return Origin(t: otOpaque, s: $url)
    return pathURL.get.origin
  of "ftp", "http", "https", "ws", "wss":
    return Origin(
      t: otTuple,
      tup: (url.scheme, url.hostname, url.port, none(string))
    )
  else:
    return Origin(t: otOpaque, s: $url)

proc `==`*(a, b: Origin): bool {.error.} =
  discard

proc isSameOrigin*(a, b: Origin): bool =
  if a.t != b.t:
    return false
  case a.t
  of otOpaque:
    return a.s == b.s
  of otTuple:
    return a.tup == b.tup

proc `$`*(origin: Origin): string =
  if origin.t == otOpaque:
    return "null"
  var s = origin.tup.scheme
  s &= "://"
  s &= origin.tup.hostname
  if origin.tup.port.isSome:
    s &= ':'
    s &= $origin.tup.port.get
  return s

proc jsOrigin*(url: URL): string {.jsfget: "origin".} =
  return $url.origin

proc protocol*(url: URL): string {.jsfget.} =
  return url.scheme & ':'

proc setProtocol*(url: URL; s: string) {.jsfset: "protocol".} =
  discard basicParseURL(s & ':', url = url,
    stateOverride = some(usSchemeStart))

proc setUsername*(url: URL; username: string) {.jsfset: "username".} =
  if url.hostType != htNone and url.scheme != "file":
    url.username = username.percentEncode(UserInfoPercentEncodeSet)

proc setPassword*(url: URL; password: string) {.jsfset: "password".} =
  if url.hostType != htNone and url.scheme != "file":
    url.password = password.percentEncode(UserInfoPercentEncodeSet)

proc host*(url: URL): string {.jsfget.} =
  if url.hostType == htNone:
    return ""
  if url.port.isNone:
    return url.hostname
  return url.hostname & ':' & $url.port.get

proc setHost*(url: URL; s: string) {.jsfset: "host".} =
  if not url.opaquePath:
    discard basicParseURL(s, url = url, stateOverride = some(usHost))

proc setHostname*(url: URL; s: string) {.jsfset: "hostname".} =
  if not url.opaquePath:
    discard basicParseURL(s, url = url, stateOverride = some(usHostname))

proc port*(url: URL): string {.jsfget.} =
  if url.port.isSome:
    return $url.port.get
  return ""

proc setPort*(url: URL; s: string) {.jsfset: "port".} =
  if url.hostType != htNone and url.scheme != "file":
    if s == "":
      url.port = none(uint16)
    else:
      discard basicParseURL(s, url = url, stateOverride = some(usPort))

proc setPathname*(url: URL; s: string) {.jsfset: "pathname".} =
  if not url.opaquePath:
    url.pathname = ""
    discard basicParseURL(s, url = url, stateOverride = some(usPathStart))

proc setSearch*(url: URL; s: string) {.jsfset: "search".} =
  if s == "":
    url.search = ""
    if url.searchParamsInternal != nil:
      url.searchParamsInternal.list.setLen(0)
    return
  let s = if s[0] == '?': s.substr(1) else: s
  url.search = "?"
  discard basicParseURL(s, url = url, stateOverride = some(usQuery))
  if url.searchParamsInternal != nil:
    url.searchParamsInternal.list = parseFromURLEncoded(s)

proc setHash*(url: URL; s: string) {.jsfset: "hash".} =
  if s == "":
    url.hash = ""
  else:
    let s = if s[0] == '#': s.substr(1) else: s
    url.hash = "#"
    discard basicParseURL(s, url = url, stateOverride = some(usFragment))

proc jsParse(url: string; base = none(string)): URL {.jsstfunc: "URL.parse".} =
  return parseAPIURL(url, base).get(nil)

proc canParse(url: string; base = none(string)): bool {.jsstfunc: "URL".} =
  return parseAPIURL(url, base).isSome

proc addURLModule*(ctx: JSContext) =
  ctx.registerType(URL)
  ctx.registerType(URLSearchParams)
