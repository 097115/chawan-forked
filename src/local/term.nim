import std/options
import std/os
import std/posix
import std/streams
import std/strutils
import std/tables
import std/termios
import std/unicode

import bindings/termcap
import config/config
import types/cell
import types/color
import types/opt
import types/winattrs
import utils/strwidth
import utils/twtstr

import chagashi/charset
import chagashi/encoder
import chagashi/validator

#TODO switch from termcap...

type
  TermcapCap = enum
    ce # clear till end of line
    cd # clear display
    cm # cursor move
    ti # terminal init (=smcup)
    te # terminal end (=rmcup)
    so # start standout mode
    md # start bold mode
    us # start underline mode
    mr # start reverse mode
    mb # start blink mode
    ZH # start italic mode
    ue # end underline mode
    se # end standout mode
    me # end all formatting modes
    vs # enhance cursor
    vi # make cursor invisible
    ve # reset cursor to normal

  Termcap = ref object
    bp: array[1024, uint8]
    funcstr: array[256, uint8]
    caps: array[TermcapCap, cstring]

  Terminal* = ref TerminalObj
  TerminalObj = object
    cs*: Charset
    config: Config
    infile*: File
    outfile: File
    cleared: bool
    canvas: FixedGrid
    pcanvas: FixedGrid
    attrs*: WindowAttributes
    colormode: ColorMode
    formatmode: FormatMode
    smcup: bool
    tc: Termcap
    tname: string
    set_title: bool
    stdin_unblocked: bool
    orig_flags: cint
    orig_flags2: cint
    orig_termios: Termios
    defaultBackground: RGBColor
    defaultForeground: RGBColor

# control sequence introducer
template CSI(s: varargs[string, `$`]): string =
  "\e[" & s.join(';')

# primary device attributes
const DA1 = CSI("c")

# report xterm text area size in pixels
const GEOMPIXEL = CSI(14, "t")

# report window size in chars
const GEOMCELL = CSI(18, "t")

# allow shift-key to override mouse protocol
const XTSHIFTESCAPE = CSI(">0s")

# device control string
template DCS(a, b: char, s: varargs[string]): string =
  "\eP" & a & b & s.join(';') & "\e\\"

template XTGETTCAP(s: varargs[string, `$`]): string =
  DCS('+', 'q', s)

# OS command
template OSC(s: varargs[string, `$`]): string =
  "\e]" & s.join(';') & '\a'

template XTERM_TITLE(s: string): string =
  OSC(0, s)

const XTGETFG = OSC(10, "?") # get foreground color
const XTGETBG = OSC(11, "?") # get background color

# DEC set
template DECSET(s: varargs[string, `$`]): string =
  "\e[?" & s.join(';') & 'h'

# DEC reset
template DECRST(s: varargs[string, `$`]): string =
  "\e[?" & s.join(';') & 'l'

# alt screen
const SMCUP = DECSET(1049)
const RMCUP = DECRST(1049)

# mouse tracking
const SGRMOUSEBTNON = DECSET(1002, 1006)
const SGRMOUSEBTNOFF = DECRST(1002, 1006)

when not termcap_found:
  const CNORM = DECSET(25)
  const CIVIS = DECRST(25)
  template HVP(s: varargs[string, `$`]): string =
    CSI(s) & "f"
  template EL(): string =
    CSI() & "K"
  template ED(): string =
    CSI() & "J"

  proc write(term: Terminal, s: string) =
    term.outfile.write(s)
else:
  func hascap(term: Terminal, c: TermcapCap): bool = term.tc.caps[c] != nil
  func cap(term: Terminal, c: TermcapCap): string = $term.tc.caps[c]
  func ccap(term: Terminal, c: TermcapCap): cstring = term.tc.caps[c]

  var goutfile: File
  proc putc(c: char): cint {.cdecl.} =
    goutfile.write(c)

  proc write(term: Terminal, s: cstring) =
    discard tputs(s, 1, putc)

  proc write(term: Terminal, s: string) =
    term.write(cstring(s))

template SGR*(s: varargs[string, `$`]): string =
  CSI(s) & "m"

#TODO a) this should be customizable b) these defaults sucks
const ANSIColorMap = [
  rgb(0, 0, 0),
  rgb(205, 0, 0),
  rgb(0, 205, 0),
  rgb(205, 205, 0),
  rgb(0, 0, 238),
  rgb(205, 0, 205),
  rgb(0, 205, 205),
  rgb(229, 229, 229),
  rgb(127, 127, 127),
  rgb(255, 0, 0),
  rgb(0, 255, 0),
  rgb(255, 255, 0),
  rgb(92, 92, 255),
  rgb(255, 0, 255),
  rgb(0, 255, 255),
  rgb(255, 255, 255)
]

proc flush*(term: Terminal) =
  term.outfile.flushFile()

proc cursorGoto(term: Terminal, x, y: int): string =
  when termcap_found:
    return $tgoto(term.ccap cm, cint(x), cint(y))
  else:
    return HVP(y + 1, x + 1)

proc clearEnd(term: Terminal): string =
  when termcap_found:
    return term.cap ce
  else:
    return EL()

proc clearDisplay(term: Terminal): string =
  when termcap_found:
    return term.cap cd
  else:
    return ED()

proc isatty(fd: FileHandle): cint {.importc: "isatty", header: "<unistd.h>".}
proc isatty*(f: File): bool =
  return isatty(f.getFileHandle()) != 0

proc isatty*(term: Terminal): bool =
  term.infile != nil and term.infile.isatty() and term.outfile.isatty()

proc anyKey*(term: Terminal) =
  if term.isatty():
    term.outfile.write("[Hit any key]")
    discard term.infile.readChar()

proc resetFormat(term: Terminal): string =
  when termcap_found:
    if term.isatty():
      return term.cap me
  return SGR()

proc startFormat(term: Terminal, flag: FormatFlags): string =
  when termcap_found:
    if term.isatty():
      case flag
      of FLAG_BOLD: return term.cap md
      of FLAG_UNDERLINE: return term.cap us
      of FLAG_REVERSE: return term.cap mr
      of FLAG_BLINK: return term.cap mb
      of FLAG_ITALIC: return term.cap ZH
      else: discard
  return SGR(FormatCodes[flag].s)

proc endFormat(term: Terminal, flag: FormatFlags): string =
  when termcap_found:
    if flag == FLAG_UNDERLINE and term.isatty():
      return term.cap ue
  return SGR(FormatCodes[flag].e)

proc setCursor*(term: Terminal, x, y: int) =
  term.write(term.cursorGoto(x, y))

proc enableAltScreen(term: Terminal): string =
  when termcap_found:
    if term.hascap ti:
      return term.cap ti
  return SMCUP

proc disableAltScreen(term: Terminal): string =
  when termcap_found:
    if term.hascap te:
      return term.cap te
  return RMCUP

func mincontrast(term: Terminal): int32 =
  return term.config.display.minimum_contrast

proc getRGB(a: CellColor, termDefault: RGBColor): RGBColor =
  case a.t
  of ctNone:
    return termDefault
  of ctANSI:
    if a.color >= 16:
      return EightBitColor(a.color).toRGB()
    return ANSIColorMap[a.color]
  of ctRGB:
    return a.rgbcolor

# Use euclidian distance to quantize RGB colors.
proc approximateANSIColor(rgb, termDefault: RGBColor): CellColor =
  var a = 0i32
  var n = -1
  for i in -1 .. ANSIColorMap.high:
    let color = if i >= 0:
      ANSIColorMap[i]
    else:
      termDefault
    if color == rgb:
      return if i == -1: defaultColor else: ANSIColor(i).cellColor()
    let x = int32(color.r) - int32(rgb.r)
    let y = int32(color.g) - int32(rgb.g)
    let z = int32(color.b) - int32(rgb.b)
    let xx = x * x
    let yy = y * y
    let zz = z * z
    let b = xx + yy + zz
    if i == -1 or b < a:
      n = i
      a = b
  return if n == -1: defaultColor else: ANSIColor(n).cellColor()

# Return a fgcolor contrasted to the background by term.mincontrast.
proc correctContrast(term: Terminal, bgcolor, fgcolor: CellColor): CellColor =
  let contrast = term.mincontrast
  let cfgcolor = fgcolor
  let bgcolor = getRGB(bgcolor, term.defaultBackground)
  let fgcolor = getRGB(fgcolor, term.defaultForeground)
  let bgY = int(bgcolor.Y)
  var fgY = int(fgcolor.Y)
  let diff = abs(bgY - fgY)
  if diff < contrast:
    if bgY > fgY:
      fgY = bgY - contrast
      if fgY < 0:
        fgY = bgY + contrast
        if fgY > 255:
          fgY = 0
    else:
      fgY = bgY + contrast
      if fgY > 255:
        fgY = bgY - contrast
        if fgY < 0:
          fgY = 255
    let newrgb = YUV(cast[uint8](fgY), fgcolor.U, fgcolor.V)
    case term.colormode
    of TRUE_COLOR:
      return cellColor(newrgb)
    of ANSI:
      return approximateANSIColor(newrgb, term.defaultForeground)
    of EIGHT_BIT:
      return cellColor(newrgb.toEightBit())
    of MONOCHROME:
      doAssert false
  return cfgcolor

template ansiSGR(n: uint8, bgmod: int): string =
  if n < 8:
    SGR(30 + bgmod + n)
  else:
    SGR(82 + bgmod + n)

template eightBitSGR(n: uint8, bgmod: int): string =
  if n < 16:
    ansiSGR(n, bgmod)
  else:
    SGR(38 + bgmod, 5, n)

template rgbSGR(rgb: RGBColor, bgmod: int): string =
  SGR(38 + bgmod, 2, rgb.r, rgb.g, rgb.b)

proc processFormat*(term: Terminal, format: var Format, cellf: Format): string =
  for flag in FormatFlags:
    if flag in term.formatmode:
      if flag in format.flags and flag notin cellf.flags:
        result &= term.endFormat(flag)
      if flag notin format.flags and flag in cellf.flags:
        result &= term.startFormat(flag)
  var cellf = cellf
  case term.colormode
  of ANSI:
    # quantize
    if cellf.bgcolor.t == ctANSI and cellf.bgcolor.color > 15:
      cellf.bgcolor = cellf.fgcolor.eightbit.toRGB().cellColor()
    if cellf.bgcolor.t == ctRGB:
      cellf.bgcolor = approximateANSIColor(cellf.bgcolor.rgbcolor,
        term.defaultBackground)
    if cellf.fgcolor.t == ctANSI and cellf.fgcolor.color > 15:
      cellf.fgcolor = cellf.fgcolor.eightbit.toRGB().cellColor()
    if cellf.fgcolor.t == ctRGB:
      if cellf.bgcolor.t == ctNone:
        cellf.fgcolor = approximateANSIColor(cellf.fgcolor.rgbcolor,
          term.defaultForeground)
      else:
        # ANSI fgcolor + bgcolor at the same time is broken
        cellf.fgcolor = defaultColor
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    # print
    case cellf.fgcolor.t
    of ctNone: result &= SGR(39)
    of ctANSI: result &= ansiSGR(cellf.fgcolor.color, 0)
    else: assert false
    case cellf.bgcolor.t
    of ctNone: result &= SGR(49)
    of ctANSI: result &= ansiSGR(cellf.bgcolor.color, 10)
    else: assert false
  of EIGHT_BIT:
    # quantize
    if cellf.bgcolor.t == ctRGB:
      cellf.bgcolor = cellf.bgcolor.rgbcolor.toEightBit().cellColor()
    if cellf.fgcolor.t == ctRGB:
      cellf.fgcolor = cellf.fgcolor.rgbcolor.toEightBit().cellColor()
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    # print
    case cellf.fgcolor.t
    of ctNone: result &= SGR(39)
    of ctANSI: result &= eightBitSGR(cellf.fgcolor.color, 0)
    of ctRGB: assert false
    case cellf.bgcolor.t
    of ctNone: result &= SGR(49)
    of ctANSI: result &= eightBitSGR(cellf.bgcolor.color, 10)
    of ctRGB: assert false
  of TRUE_COLOR:
    # correct
    cellf.fgcolor = term.correctContrast(cellf.bgcolor, cellf.fgcolor)
    # print
    if cellf.fgcolor != format.fgcolor:
      case cellf.fgcolor.t
      of ctNone: result &= SGR(39)
      of ctANSI: result &= eightBitSGR(cellf.fgcolor.color, 0)
      of ctRGB: result &= rgbSGR(cellf.fgcolor.rgbcolor, 0)
    if cellf.bgcolor != format.bgcolor:
      case cellf.bgcolor.t
      of ctNone: result &= SGR(49)
      of ctANSI: result &= eightBitSGR(cellf.bgcolor.color, 10)
      of ctRGB: result &= rgbSGR(cellf.bgcolor.rgbcolor, 10)
  of MONOCHROME:
    discard # nothing to do
  format = cellf

proc setTitle*(term: Terminal, title: string) =
  if term.set_title:
    term.outfile.write(XTERM_TITLE(title.replaceControls()))

proc enableMouse*(term: Terminal) =
  term.write(XTSHIFTESCAPE & SGRMOUSEBTNON)

proc disableMouse*(term: Terminal) =
  term.write(SGRMOUSEBTNOFF)

proc processOutputString*(term: Terminal, str: string, w: var int): string =
  if str.validateUTF8Surr() != -1:
    return "?"
  # twidth wouldn't work here, the view may start at the nth character.
  # pager must ensure tabs are converted beforehand.
  w += str.notwidth()
  let str = if Controls in str:
    str.replaceControls()
  else:
    str
  if term.cs == CHARSET_UTF_8:
    # The output encoding matches the internal representation.
    return str
  else:
    # Output is not utf-8, so we must encode it first.
    var success = false
    return newTextEncoder(term.cs).encodeAll(str, success)

proc generateFullOutput(term: Terminal, grid: FixedGrid): string =
  var format = Format()
  result &= term.cursorGoto(0, 0)
  result &= term.resetFormat()
  result &= term.clearDisplay()
  for y in 0 ..< grid.height:
    if y != 0:
      result &= "\r\n"
    var w = 0
    for x in 0 ..< grid.width:
      while w < x:
        result &= " "
        inc w
      let cell = grid[y * grid.width + x]
      result &= term.processFormat(format, cell.format)
      result &= term.processOutputString(cell.str, w)

proc generateSwapOutput(term: Terminal, grid, prev: FixedGrid): string =
  var vy = -1
  for y in 0 ..< grid.height:
    var w = 0
    var change = false
    # scan for changes, and set cx to x of the first change
    var cx = 0
    # if there is a change, we have to start from the last x with
    # a string (otherwise we might overwrite a double-width char)
    var lastx = 0
    for x in 0 ..< grid.width:
      let i = y * grid.width + x
      if grid[i].str != "":
        lastx = x
      if grid[i] != prev[i]:
        change = true
        cx = lastx
        w = lastx
        break
    if change:
      if cx == 0 and vy != -1:
        while vy < y:
          result &= "\r\n"
          inc vy
      else:
        result &= term.cursorGoto(cx, y)
        vy = y
      result &= term.resetFormat()
      var format = Format()
      for x in cx ..< grid.width:
        while w < x: # if previous cell had no width, catch up with x
          result &= ' '
          inc w
        let cell = grid[y * grid.width + x]
        result &= term.processFormat(format, cell.format)
        result &= term.processOutputString(cell.str, w)
      if w < grid.width:
        result &= term.clearEnd()

proc hideCursor*(term: Terminal) =
  when termcap_found:
    term.write(term.ccap vi)
  else:
    term.write(CIVIS)

proc showCursor*(term: Terminal) =
  when termcap_found:
    term.write(term.ccap ve)
  else:
    term.write(CNORM)

func emulateOverline(term: Terminal): bool =
  term.config.display.emulate_overline and
    FLAG_OVERLINE notin term.formatmode and FLAG_UNDERLINE in term.formatmode

proc writeGrid*(term: Terminal, grid: FixedGrid, x = 0, y = 0) =
  for ly in y ..< y + grid.height:
    for lx in x ..< x + grid.width:
      let i = ly * term.canvas.width + lx
      term.canvas[i] = grid[(ly - y) * grid.width + (lx - x)]
      let isol = FLAG_OVERLINE in term.canvas[i].format.flags
      if i >= term.canvas.width and isol and term.emulateOverline:
        let w = grid[(ly - y) * grid.width + (lx - x)].width()
        let s = i - term.canvas.width
        var j = s
        while j < term.canvas.len and j < s + w:
          let cell = addr term.canvas[j]
          cell.format.flags.incl(FLAG_UNDERLINE)
          if cell.str == "":
            cell.str = " "
          if cell.str == " ":
            let i = (ly - y) * grid.width + (lx - x)
            cell.format.fgcolor = grid[i].format.fgcolor
          j += cell[].width()

proc applyConfigDimensions(term: Terminal) =
  # screen dimensions
  if term.attrs.width == 0 or term.config.display.force_columns:
    term.attrs.width = int(term.config.display.columns)
  if term.attrs.height == 0 or term.config.display.force_lines:
    term.attrs.height = int(term.config.display.lines)
  if term.attrs.ppc == 0 or term.config.display.force_pixels_per_column:
    term.attrs.ppc = int(term.config.display.pixels_per_column)
  if term.attrs.ppl == 0 or term.config.display.force_pixels_per_line:
    term.attrs.ppl = int(term.config.display.pixels_per_line)
  term.attrs.width_px = term.attrs.ppc * term.attrs.width
  term.attrs.height_px = term.attrs.ppl * term.attrs.height

proc applyConfig(term: Terminal) =
  # colors, formatting
  if term.config.display.color_mode.isSome:
    term.colormode = term.config.display.color_mode.get
  elif term.isatty():
    let colorterm = getEnv("COLORTERM")
    if colorterm in ["24bit", "truecolor"]:
      term.colormode = TRUE_COLOR
  if term.config.display.format_mode.isSome:
    term.formatmode = term.config.display.format_mode.get
  for fm in FormatFlags:
    if fm in term.config.display.no_format_mode:
      term.formatmode.excl(fm)
  if term.isatty():
    if term.config.display.alt_screen.isSome:
      term.smcup = term.config.display.alt_screen.get
    term.set_title = term.config.display.set_title
  if term.config.display.default_background_color.isSome:
    term.defaultBackground = term.config.display.default_background_color.get
  if term.config.display.default_foreground_color.isSome:
    term.defaultForeground = term.config.display.default_foreground_color.get
  # charsets
  if term.config.encoding.display_charset.isSome:
    term.cs = term.config.encoding.display_charset.get
  else:
    term.cs = DefaultCharset
    for s in ["LC_ALL", "LC_CTYPE", "LANG"]:
      let env = getEnv(s)
      if env == "":
        continue
      let cs = getLocaleCharset(env)
      if cs != CHARSET_UNKNOWN:
        term.cs = cs
        break
  term.applyConfigDimensions()

proc outputGrid*(term: Terminal) =
  term.outfile.write(term.resetFormat())
  let samesize = term.canvas.width == term.pcanvas.width and
    term.canvas.height == term.pcanvas.height
  if term.config.display.force_clear or not term.cleared or not samesize:
    term.outfile.write(term.generateFullOutput(term.canvas))
    term.cleared = true
  else:
    term.outfile.write(term.generateSwapOutput(term.canvas, term.pcanvas))
  if not samesize:
    term.pcanvas.width = term.canvas.width
    term.pcanvas.height = term.canvas.height
    term.pcanvas.cells.setLen(term.canvas.cells.len)
  for i in 0 ..< term.canvas.cells.len:
    term.pcanvas[i] = term.canvas[i]

proc clearCanvas*(term: Terminal) =
  term.cleared = false

# see https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
proc disableRawMode(term: Terminal) =
  let fd = term.infile.getFileHandle()
  discard tcSetAttr(fd, TCSAFLUSH, addr term.orig_termios)

proc enableRawMode(term: Terminal) =
  let fd = term.infile.getFileHandle()
  discard tcGetAttr(fd, addr term.orig_termios)
  var raw = term.orig_termios
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not (OPOST)
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
  discard tcSetAttr(fd, TCSAFLUSH, addr raw)

proc unblockStdin*(term: Terminal) =
  if term.isatty():
    let fd = term.infile.getFileHandle()
    term.orig_flags = fcntl(fd, F_GETFL, 0)
    let flags = term.orig_flags or O_NONBLOCK
    discard fcntl(fd, F_SETFL, flags)
    term.stdin_unblocked = true

proc restoreStdin*(term: Terminal) =
  if term.stdin_unblocked:
    let fd = term.infile.getFileHandle()
    discard fcntl(fd, F_SETFL, term.orig_flags)
    term.stdin_unblocked = false

proc quit*(term: Terminal) =
  if term.isatty():
    term.disableRawMode()
    if term.smcup:
      term.write(term.disableAltScreen())
    else:
      term.write(term.cursorGoto(0, term.attrs.height - 1) &
        term.resetFormat() & "\n")
    if term.config.input.use_mouse:
      term.disableMouse()
    term.showCursor()
    term.cleared = false
    if term.stdin_unblocked:
      let fd = term.infile.getFileHandle()
      term.orig_flags2 = fcntl(fd, F_GETFL, 0)
      discard fcntl(fd, F_SETFL, term.orig_flags2 and (not O_NONBLOCK))
      term.stdin_unblocked = false
    else:
      term.orig_flags2 = -1
  term.flush()

when termcap_found:
  proc loadTermcap(term: Terminal) =
    assert goutfile == nil
    goutfile = term.outfile
    let tc = new Termcap
    if tgetent(cast[cstring](addr tc.bp), cstring(term.tname)) == 1:
      term.tc = tc
      for id in TermcapCap:
        tc.caps[id] = tgetstr(cstring($id), cast[ptr cstring](addr tc.funcstr))
    else:
      raise newException(Defect, "Failed to load termcap description for terminal " & term.tname)

type
  QueryAttrs = enum
    qaAnsiColor, qaRGB, qaSixel

  QueryResult = object
    success: bool
    attrs: set[QueryAttrs]
    fgcolor: Option[RGBColor]
    bgcolor: Option[RGBColor]
    widthPx: int
    heightPx: int
    width: int
    height: int

proc queryAttrs(term: Terminal, windowOnly: bool): QueryResult =
  const tcapRGB = 0x524742 # RGB supported?
  if not windowOnly:
    const outs =
      XTGETFG &
      XTGETBG &
      GEOMPIXEL &
      GEOMCELL &
      XTGETTCAP("524742") &
      DA1
    term.outfile.write(outs)
  else:
    const outs =
      GEOMPIXEL &
      GEOMCELL &
      DA1
    term.outfile.write(outs)
  result = QueryResult(success: false, attrs: {})
  while true:
    template consume(term: Terminal): char = term.infile.readChar()
    template fail = return
    template expect(term: Terminal, c: char) =
      if term.consume != c:
        fail
    template expect(term: Terminal, s: string) =
      for c in s:
        term.expect c
    template skip_until(term: Terminal, c: char) =
      while (let cc = term.consume; cc != c):
        discard
    term.expect '\e'
    case term.consume
    of '[':
      # CSI
      case (let c = term.consume; c)
      of '?': # DA1
        var n = 0
        while (let c = term.consume; c != 'c'):
          if c == ';':
            case n
            of 4: result.attrs.incl(qaSixel)
            of 22: result.attrs.incl(qaAnsiColor)
            else: discard
            n = 0
          else:
            n *= 10
            n += decValue(c)
        result.success = true
        break # DA1 returned; done
      of '4', '8': # GEOMPIXEL, GEOMCELL
        term.expect ';'
        var height = 0
        var width = 0
        while (let c = term.consume; c != ';'):
          if (let x = decValue(c); x != -1):
            height *= 10
            height += x
          else:
            fail
        while (let c = term.consume; c != 't'):
          if (let x = decValue(c); x != -1):
            width *= 10
            width += x
          else:
            fail
        if c == '4': # GEOMSIZE
          result.widthPx = width
          result.heightPx = height
        if c == '8': # GEOMCELL
          result.width = width
          result.height = height
      else: fail
    of ']':
      # OSC
      term.expect '1'
      let c = term.consume
      if c notin {'0', '1'}: fail
      term.expect ';'
      if term.consume == 'r' and term.consume == 'g' and term.consume == 'b':
        term.expect ':'
        template eat_color(tc: char): uint8 =
          var val = 0u8
          var i = 0
          while (let c = term.consume; c != tc):
            let v0 = hexValue(c)
            if i > 4 or v0 == -1: fail # wat
            let v = uint8(v0)
            if i == 0: # 1st place
              val = (v shl 4) or v
            elif i == 1: # 2nd place
              val = (val xor 0xF) or v
            # all other places are irrelevant
            inc i
          val
        let r = eat_color '/'
        let g = eat_color '/'
        let b = eat_color '\a'
        if c == '0':
          result.fgcolor = some(rgb(r, g, b))
        else:
          result.bgcolor = some(rgb(r, g, b))
      else:
        # not RGB, give up
        term.skip_until '\a'
    of 'P':
      # DCS
      let c = term.consume
      if c notin {'0', '1'}:
        fail
      term.expect "+r"
      if c == '1':
        var id = 0
        while (let c = term.consume; c != '='):
          if c notin AsciiHexDigit:
            fail
          id *= 0x10
          id += hexValue(c)
        term.skip_until '\e' # ST (1)
        if id == tcapRGB:
          result.attrs.incl(qaRGB)
      else: # 0
        term.expect '\e' # ST (1)
      term.expect '\\' # ST (2)
    else:
      fail

type TermStartResult* = enum
  tsrSuccess, tsrDA1Fail

# when windowOnly, only refresh window size.
proc detectTermAttributes(term: Terminal, windowOnly: bool): TermStartResult =
  result = tsrSuccess
  term.tname = getEnv("TERM")
  if term.tname == "":
    term.tname = "dosansi"
  if not term.isatty():
    return
  let fd = term.infile.getFileHandle()
  var win: IOctl_WinSize
  if ioctl(cint(fd), TIOCGWINSZ, addr win) != -1:
    term.attrs.width = int(win.ws_col)
    term.attrs.height = int(win.ws_row)
    term.attrs.ppc = int(win.ws_xpixel) div term.attrs.width
    term.attrs.ppl = int(win.ws_ypixel) div term.attrs.height
  if term.config.display.query_da1:
    let r = term.queryAttrs(windowOnly)
    if r.success: # DA1 success
      if r.width != 0:
        term.attrs.width = r.width
        if r.widthPx != 0:
          term.attrs.ppc = r.widthPx div r.width
      if r.height != 0:
        term.attrs.height = r.height
        if r.heightPx != 0:
          term.attrs.ppl = r.heightPx div r.height
      if windowOnly:
        return
      if qaAnsiColor in r.attrs:
        term.colormode = ANSI
      if qaRGB in r.attrs:
        term.colormode = TRUE_COLOR
      # just assume the terminal doesn't choke on these.
      term.formatmode = {FLAG_STRIKE, FLAG_OVERLINE}
      if r.bgcolor.isSome:
        term.defaultBackground = r.bgcolor.get
      if r.fgcolor.isSome:
        term.defaultForeground = r.fgcolor.get
    else:
      # something went horribly wrong. set result to DA1 fail, pager will
      # alert the user
      result = tsrDA1Fail
  if windowOnly:
    return
  if term.colormode != TRUE_COLOR:
    let colorterm = getEnv("COLORTERM")
    if colorterm in ["24bit", "truecolor"]:
      term.colormode = TRUE_COLOR
  when termcap_found:
    term.loadTermcap()
    if term.tc != nil:
      term.smcup = term.hascap ti
      if term.hascap(ZH):
        term.formatmode.incl(FLAG_ITALIC)
      if term.hascap(us):
        term.formatmode.incl(FLAG_UNDERLINE)
      if term.hascap(md):
        term.formatmode.incl(FLAG_BOLD)
      if term.hascap(mr):
        term.formatmode.incl(FLAG_REVERSE)
      if term.hascap(mb):
        term.formatmode.incl(FLAG_BLINK)
  else:
    term.smcup = true
    term.formatmode = {low(FormatFlags)..high(FormatFlags)}

proc windowChange*(term: Terminal) =
  discard term.detectTermAttributes(windowOnly = true)
  term.applyConfigDimensions()
  term.canvas = newFixedGrid(term.attrs.width, term.attrs.height)
  term.cleared = false

proc start*(term: Terminal, infile: File): TermStartResult =
  term.infile = infile
  if term.isatty():
    term.enableRawMode()
  result = term.detectTermAttributes(windowOnly = false)
  if result == tsrDA1Fail:
    term.config.display.query_da1 = false
  if term.isatty() and term.config.input.use_mouse:
    term.enableMouse()
  term.applyConfig()
  term.canvas = newFixedGrid(term.attrs.width, term.attrs.height)
  if term.smcup:
    term.write(term.enableAltScreen())

proc restart*(term: Terminal) =
  if term.isatty():
    term.enableRawMode()
    if term.orig_flags2 != -1:
      let fd = term.infile.getFileHandle()
      discard fcntl(fd, F_SETFL, term.orig_flags2)
      term.orig_flags2 = 0
      term.stdin_unblocked = true
    if term.config.input.use_mouse:
      term.enableMouse()
  if term.smcup:
    term.write(term.enableAltScreen())

proc newTerminal*(outfile: File, config: Config): Terminal =
  return Terminal(
    outfile: outfile,
    config: config,
    defaultBackground: ColorsRGB["black"],
    defaultForeground: ColorsRGB["white"]
  )