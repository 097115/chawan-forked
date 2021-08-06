import options
import terminal
import uri
import tables
import strutils
import unicode

import ../types/color

import ../utils/twtstr
import ../utils/eprint

import ../html/dom

import ../config

import ./term
import ./lineedit

type
  Cell = object of RootObj
    fgcolor*: CellColor
    bgcolor*: CellColor
    italic: bool
    bold: bool
    underline: bool

  BufferCell = object of Cell
    rune*: Rune

  BufferRow = seq[BufferCell]

  DisplayCell = object of Cell
    runes*: seq[Rune]

  DisplayRow = seq[DisplayCell]

  Buffer* = ref BufferObj
  BufferObj = object
    title*: string
    lines*: seq[BufferRow]
    display*: DisplayRow
    prevdisplay*: DisplayRow
    statusmsg*: DisplayRow
    hovertext*: string
    width*: int
    height*: int
    cursorx*: int
    cursory*: int
    xend*: int
    fromx*: int
    fromy*: int
    nodes*: seq[Node]
    links*: seq[Node]
    elements*: seq[Element]
    idelements*: Table[string, Element]
    selectedlink*: Node
    attrs*: TermAttributes
    document*: Document
    displaycontrols*: bool
    redraw*: bool
    location*: Uri

func newBuffer*(attrs: TermAttributes): Buffer =
  new(result)
  result.width = attrs.termWidth
  result.height = attrs.termHeight - 1
  result.attrs = attrs

  result.display = newSeq[DisplayCell](result.width * result.height)
  result.statusmsg = newSeq[DisplayCell](result.width)

func generateFullOutput*(buffer: Buffer): string =
  var x = 0
  var y = 0
  for cell in buffer.display:
    if x >= buffer.width:
      inc y
      result &= '\n'
      x = 0

    for r in cell.runes:
      if r != Rune(0):
        result &= $r

    inc x

func generateStatusMessage*(buffer: Buffer): string =
  for cell in buffer.statusmsg:
    for r in cell.runes:
      if r != Rune(0):
        result &= $r

func numLines*(buffer: Buffer): int = buffer.lines.len

func lastVisibleLine*(buffer: Buffer): int = min(buffer.fromy + buffer.height, buffer.numLines - 1)

func width(line: seq[BufferCell]): int =
  for c in line:
    result += c.rune.width()

func cellWidthOverlap*(buffer: Buffer, x: int, y: int): int =
  let row = y * buffer.width
  var ox = x
  while buffer.display[row + ox].runes.len == 0 and ox > 0:
    dec ox
  return buffer.display[row + ox].runes.width()

func currentCellWidth*(buffer: Buffer): int = buffer.cellWidthOverlap(buffer.cursorx - buffer.fromx, buffer.cursory - buffer.fromy)

func currentLineWidth*(buffer: Buffer): int =
  return buffer.lines[buffer.cursory].width()

func maxScreenWidth*(buffer: Buffer): int =
  for line in buffer.lines[buffer.fromy..buffer.lastVisibleLine - 1]:
    result = max(line.width(), result)

func atPercentOf*(buffer: Buffer): int =
  if buffer.lines.len == 0: return 100
  return (100 * (buffer.cursory + 1)) div buffer.numLines

func lastNode*(buffer: Buffer): Node =
  return buffer.nodes[^1]

func cursorOnNode*(buffer: Buffer, node: Node): bool =
  if node.y == node.ey and node.y == buffer.cursory:
    return buffer.cursorx >= node.x and buffer.cursorx < node.ex
  else:
    return (buffer.cursory == node.y and buffer.cursorx >= node.x) or
           (buffer.cursory > node.y and buffer.cursory < node.ey) or
           (buffer.cursory == node.ey and buffer.cursorx < node.ex)

func findSelectedElement*(buffer: Buffer): Option[HtmlElement] =
  if buffer.selectedlink != nil and buffer.selectedLink.parentNode of HtmlElement:
    return some(HtmlElement(buffer.selectedlink.parentNode))
  for node in buffer.nodes:
    if node.isElemNode():
      if node.getFmtLen() > 0:
        if buffer.cursorOnNode(node): return some(HtmlElement(node))
  return none(HtmlElement)

func canScroll*(buffer: Buffer): bool =
  return buffer.numLines >= buffer.height

func getElementById*(buffer: Buffer, id: string): Element =
  if buffer.idelements.hasKey(id):
    return buffer.idelements[id]
  return nil

proc findSelectedNode*(buffer: Buffer): Option[Node] =
  for node in buffer.nodes:
    if node.getFmtLen() > 0 and node.displayed():
      if buffer.cursory >= node.y and buffer.cursory <= node.y + node.height and buffer.cursorx >= node.x and buffer.cursorx <= node.x + node.width:
        return some(node)
  return none(Node)

proc writefmt*(buffer: Buffer, str: string) =
  discard

proc writefmt*(buffer: Buffer, c: char) =
  discard

proc writeraw*(buffer: Buffer, str: string) =
  discard

proc writeraw*(buffer: Buffer, c: char) =
  discard

proc write*(buffer: Buffer, str: string) =
  buffer.writefmt(str)
  buffer.writeraw(str)

proc write*(buffer: Buffer, c: char) =
  buffer.writefmt(c)
  buffer.writeraw(c)

proc clearText*(buffer: Buffer) =
  buffer.lines.setLen(0)

proc clearNodes*(buffer: Buffer) =
  buffer.nodes.setLen(0)
  buffer.links.setLen(0)
  buffer.elements.setLen(0)
  buffer.idelements.clear()

proc clearBuffer*(buffer: Buffer) =
  buffer.clearText()
  buffer.clearNodes()
  buffer.cursorx = 0
  buffer.cursory = 0
  buffer.fromx = 0
  buffer.fromy = 0
  buffer.hovertext = ""
  buffer.selectedlink = nil

proc restoreCursorX(buffer: Buffer) =
  buffer.cursorx = max(min(buffer.currentLineWidth() - 1, buffer.xend), 0)

proc scrollTo*(buffer: Buffer, y: int) =
  if y == buffer.fromy:
    return
  buffer.fromy = min(max(buffer.numLines - buffer.height, 0), y)
  buffer.cursory = min(max(buffer.fromy, buffer.cursory), buffer.fromy + buffer.height)
  buffer.redraw = true
  buffer.restoreCursorX()

proc cursorTo*(buffer: Buffer, x: int, y: int) =
  buffer.redraw = false
  buffer.cursory = min(max(y, 0), buffer.numLines - 1)
  if buffer.fromy > buffer.cursory:
    buffer.fromy = max(buffer.cursory, 0)
    buffer.redraw = true
  elif buffer.fromy + buffer.height - 1 <= buffer.cursory:
    buffer.fromy = max(buffer.cursory - buffer.height + 1, 0)
    buffer.redraw = true

  buffer.cursorx = min(max(x, 0), buffer.currentLineWidth())
  if buffer.fromx < buffer.cursorx - buffer.width:
    buffer.fromx = max(0, buffer.cursorx - buffer.width)
    buffer.redraw = true
  elif buffer.fromx > buffer.cursorx:
    buffer.fromx = buffer.cursorx
    buffer.redraw = true

proc cursorDown*(buffer: Buffer) =
  if buffer.cursory < buffer.numLines:
    inc buffer.cursory
    buffer.restoreCursorX()
    if buffer.cursory >= buffer.lastVisibleLine and buffer.lastVisibleLine != buffer.numLines - 1:
      inc buffer.fromy
      buffer.redraw = true

proc cursorUp*(buffer: Buffer) =
  if buffer.cursory > 0:
    dec buffer.cursory
    buffer.restoreCursorX()
    if buffer.cursory < buffer.fromy:
      dec buffer.fromy
      buffer.redraw = true

proc cursorRight*(buffer: Buffer) =
  let cellwidth = buffer.currentCellWidth()
  let lw = buffer.currentLineWidth()
  if buffer.cursorx < lw - 1:
    buffer.cursorx = min(lw - 1, buffer.cursorx + cellwidth)
    buffer.xend = buffer.cursorx
    if buffer.cursorx - buffer.width >= buffer.fromx:
      inc buffer.fromx
      buffer.redraw = true

proc cursorLeft*(buffer: Buffer) =
  let cellwidth = buffer.currentCellWidth()
  if buffer.fromx > buffer.cursorx:
    buffer.fromx = buffer.cursorx
    buffer.redraw = true
  elif buffer.cursorx > 0:
    buffer.cursorx = max(0, buffer.cursorx - cellwidth)
    if buffer.fromx > buffer.cursorx:
      buffer.fromx = buffer.cursorx
      buffer.redraw = true

  buffer.xend = buffer.cursorx

proc cursorLineBegin*(buffer: Buffer) =
  buffer.cursorx = 0
  buffer.xend = 0
  if buffer.fromx > 0:
    buffer.fromx = 0
    buffer.redraw = true

proc cursorLineEnd*(buffer: Buffer) =
  buffer.cursorx = buffer.currentLineWidth() - 1
  buffer.xend = buffer.cursorx
  buffer.fromx = max(buffer.cursorx - buffer.width + 1, 0)
  buffer.redraw = buffer.fromx > 0

iterator revnodes*(buffer: Buffer): Node {.inline.} =
  var i = buffer.nodes.len - 1
  while i >= 0:
    yield buffer.nodes[i]
    dec i

proc cursorNextWord*(buffer: Buffer) =
  let llen = buffer.currentLineWidth() - 1
  var x = buffer.cursorx
  var y = buffer.cursory
  if llen >= 0:

    while not buffer.lines[y][x].rune.breaksWord():
      if x >= llen:
        break
      inc x

    while buffer.lines[y][x].rune.breaksWord():
      if x >= llen:
        break
      inc x

  if x >= llen:
    if y < buffer.numLines:
      inc y
      x = 0
  buffer.cursorTo(x, y)

proc cursorPrevWord*(buffer: Buffer) =
  var x = buffer.cursorx
  var y = buffer.cursory
  if buffer.currentLineWidth() > 0:
    while not buffer.lines[y][x].rune.breaksWord():
      if x == 0:
        break
      dec x

    while buffer.lines[y][x].rune.breaksWord():
      if x == 0:
        break
      dec x

  if x == 0:
    if y > 0:
      dec y
      x = buffer.lines[y].len - 1
  buffer.cursorTo(x, y)

proc cursorNextLink*(buffer: Buffer) =
  #TODO
  return

proc cursorPrevLink*(buffer: Buffer) =
  #TODO
  return

proc cursorFirstLine*(buffer: Buffer) =
  if buffer.fromy > 0:
    buffer.fromy = 0
    buffer.redraw = true
  else:
    buffer.redraw = false

  buffer.cursory = 0
  buffer.restoreCursorX()

proc cursorLastLine*(buffer: Buffer) =
  if buffer.fromy < buffer.numLines - buffer.height:
    buffer.fromy = buffer.numLines - buffer.height
    buffer.redraw = true
  buffer.cursory = buffer.numLines - 1
  buffer.restoreCursorX()

proc cursorTop*(buffer: Buffer) =
  buffer.cursory = buffer.fromy
  buffer.restoreCursorX()

proc cursorMiddle*(buffer: Buffer) =
  buffer.cursory = min(buffer.fromy + (buffer.height - 2) div 2, buffer.numLines - 1)
  buffer.restoreCursorX()

proc cursorBottom*(buffer: Buffer) =
  buffer.cursory = min(buffer.fromy + buffer.height - 1, buffer.numLines)
  buffer.restoreCursorX()

proc centerLine*(buffer: Buffer) =
  let ny = max(min(buffer.cursory - buffer.height div 2, buffer.numLines - buffer.height), 0)
  if ny != buffer.fromy:
    buffer.fromy = ny
    buffer.redraw = true

proc halfPageUp*(buffer: Buffer) =
  buffer.cursory = max(buffer.cursory - buffer.height div 2 + 1, 0)
  let nfy = max(0, buffer.fromy - buffer.height div 2 + 1)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc halfPageDown*(buffer: Buffer) =
  buffer.cursory = min(buffer.cursory + buffer.height div 2 - 1, buffer.numLines - 1)
  let nfy = min(max(buffer.numLines - buffer.height, 0), buffer.fromy + buffer.height div 2 - 1)
  if nfy != buffer.fromy:
    buffer.fromy = nfy
    buffer.redraw = true
  buffer.restoreCursorX()

proc pageUp*(buffer: Buffer) =
  buffer.cursory = max(buffer.cursory - buffer.height + 1, 1)
  buffer.fromy = max(0, buffer.fromy - buffer.height)
  buffer.redraw = true
  buffer.restoreCursorX()

proc pageDown*(buffer: Buffer) =
  buffer.cursory = min(buffer.cursory + buffer.height div 2 - 1, buffer.numLines - 1)
  buffer.fromy = min(max(buffer.numLines - buffer.height, 0), buffer.fromy + buffer.height div 2)
  buffer.redraw = true
  buffer.restoreCursorX()

proc pageLeft*(buffer: Buffer) =
  buffer.cursorx = max(buffer.cursorx - buffer.width, 0)
  buffer.fromx = max(0, buffer.fromx - buffer.width)
  buffer.redraw = true

proc pageRight*(buffer: Buffer) =
  buffer.cursorx = min(buffer.fromx, buffer.currentLineWidth())
  buffer.fromx = min(max(buffer.maxScreenWidth() - buffer.width, 0), buffer.fromx + buffer.width)
  buffer.redraw = true

proc scrollDown*(buffer: Buffer) =
  if buffer.fromy + buffer.height < buffer.numLines:
    inc buffer.fromy
    if buffer.fromy > buffer.cursory:
      buffer.cursorDown()
    buffer.redraw = true
  else:
    buffer.cursorDown()

proc scrollUp*(buffer: Buffer) =
  if buffer.fromy > 0:
    dec buffer.fromy
    if buffer.fromy + buffer.height <= buffer.cursory:
      buffer.cursorUp()
    buffer.redraw = true
  else:
    buffer.cursorUp()

proc scrollRight*(buffer: Buffer) =
  if buffer.fromx + buffer.width < buffer.maxScreenWidth():
    inc buffer.fromx
    if buffer.fromx >= buffer.cursorx:
      buffer.cursorRight()
    buffer.redraw = true

proc scrollLeft*(buffer: Buffer) =
  if buffer.fromx > 0:
    dec buffer.fromx
    if buffer.fromx + buffer.height <= buffer.cursorx:
      buffer.cursorLeft()
    buffer.redraw = true

proc gotoAnchor*(buffer: Buffer): bool =
  if buffer.location.anchor != "":
    let node =  buffer.getElementById(buffer.location.anchor)
    if node != nil:
      buffer.scrollTo(max(node.y - buffer.height div 2, 0))

proc setLocation*(buffer: Buffer, uri: Uri) =
  buffer.location = uri

proc gotoLocation*(buffer: Buffer, uri: Uri) =
  buffer.location = buffer.location.combine(uri)

proc refreshTermAttrs*(buffer: Buffer): bool =
  let newAttrs = getTermAttributes()
  if newAttrs != buffer.attrs:
    buffer.attrs = newAttrs
    buffer.width = newAttrs.termWidth
    buffer.height = newAttrs.termHeight
    return true
  return false

proc setText*(buffer: Buffer, x: int, y: int, text: seq[Rune]) =
  while buffer.lines.len <= y:
    buffer.lines.add(newSeq[BufferCell]())

  while buffer.lines[y].len < x + text.len:
    buffer.lines[y].add(BufferCell())
  
  var i = 0
  while i < text.len:
    buffer.lines[y][i].rune = text[i]
    inc i

proc reshape*(buffer: Buffer) =
  buffer.display = newSeq[DisplayCell](buffer.width * buffer.height)
  buffer.statusmsg = newSeq[DisplayCell](buffer.width)

proc clearDisplay*(buffer: Buffer) =
  var i = 0
  while i < buffer.display.len:
    buffer.display[i].runes.setLen(0)
    inc i

proc refreshDisplay*(buffer: Buffer) =
  var y = 0
  buffer.prevdisplay = buffer.display
  buffer.clearDisplay()
  for line in buffer.lines[buffer.fromy..buffer.lastVisibleLine - 1]:
    var w = 0
    var i = 0
    while w < buffer.fromx and i < line.len:
      w += line[i].rune.width()
      inc i

    let dls = y * buffer.width
    var j = 0
    var n = 0
    while w < buffer.fromx + buffer.width and i < line.len:
      w += line[i].rune.width()
      if line[i].rune.width() == 0 and j != 0:
        inc n
      buffer.display[dls + j - n].runes.add(line[i].rune)
      j += line[i].rune.width()
      inc i

    inc y

proc renderPlainText*(buffer: Buffer, text: string) =
  var i = 0
  var y = 0
  var line = ""
  while i < text.len:
    if text[i] == '\n':
      buffer.setText(0, y, line.toRunes())
      inc y
      line = ""
    elif text[i] == '\r':
      discard
    elif text[i] == '\t':
      line &= ' '.repeat(8)
    else:
      line &= text[i]
    inc i
  if line.len > 0:
    buffer.setText(0, y, line.toRunes())

  buffer.refreshDisplay()

proc cursorBufferPos(buffer: Buffer) =
  let x = max(buffer.cursorx - buffer.fromx, 0)
  let y = buffer.cursory - buffer.fromy
  termGoto(x, y)

proc clearStatusMessage(buffer: Buffer) =
  var i = 0
  while i < buffer.statusmsg.len:
    buffer.statusmsg[i].runes.setLen(0)
    inc i

proc setStatusMessage*(buffer: Buffer, str: string) =
  buffer.clearStatusMessage()
  let text = str.toRunes()
  var i = 0
  var n = 0
  while i < text.len:
    if text[i].width() == 0:
      inc n
    buffer.statusmsg[i - n].runes.add(text[i])
    inc i

proc statusMsgForBuffer(buffer: Buffer) =
  var msg = ($(buffer.cursory + 1) & "/" & $buffer.numLines & " (" &
            $buffer.atPercentOf() & "%) " &
            "<" & buffer.title & ">").ansiStyle(styleReverse).ansiReset().join()
  if buffer.hovertext.len > 0:
    msg &= " " & buffer.hovertext
  buffer.setStatusMessage(msg)

proc displayBuffer(buffer: Buffer) =
  eraseScreen()
  termGoto(0, 0)
  print(buffer.generateFullOutput().ansiReset())

proc displayStatusMessage(buffer: Buffer) =
  termGoto(0, buffer.height)
  eraseLine()
  print(buffer.generateStatusMessage())

proc inputLoop(attrs: TermAttributes, buffer: Buffer): bool =
  var s = ""
  var feedNext = false
  while true:
    buffer.redraw = false
    buffer.displayStatusMessage()
    stdout.showCursor()
    buffer.cursorBufferPos()
    if not feedNext:
      s = ""
    else:
      feedNext = false
    let c = getch()
    s &= c
    let action = getNormalAction(s)
    var redraw = false
    var reshape = false
    var nostatus = false
    case action
    of ACTION_QUIT:
      eraseScreen()
      setCursorPos(0, 0)
      return false
    of ACTION_CURSOR_LEFT: buffer.cursorLeft()
    of ACTION_CURSOR_DOWN: buffer.cursorDown()
    of ACTION_CURSOR_UP: buffer.cursorUp()
    of ACTION_CURSOR_RIGHT: buffer.cursorRight()
    of ACTION_CURSOR_LINEBEGIN: buffer.cursorLineBegin()
    of ACTION_CURSOR_LINEEND: buffer.cursorLineEnd()
    of ACTION_CURSOR_NEXT_WORD: buffer.cursorNextWord()
    of ACTION_CURSOR_PREV_WORD: buffer.cursorPrevWord()
    of ACTION_CURSOR_NEXT_LINK: buffer.cursorNextLink()
    of ACTION_CURSOR_PREV_LINK: buffer.cursorPrevLink()
    of ACTION_PAGE_DOWN: buffer.pageDown()
    of ACTION_PAGE_UP: buffer.pageUp()
    of ACTION_PAGE_RIGHT: buffer.pageRight()
    of ACTION_PAGE_LEFT: buffer.pageLeft()
    of ACTION_HALF_PAGE_DOWN: buffer.halfPageDown()
    of ACTION_HALF_PAGE_UP: buffer.halfPageUp()
    of ACTION_CURSOR_FIRST_LINE: buffer.cursorFirstLine()
    of ACTION_CURSOR_LAST_LINE: buffer.cursorLastLine()
    of ACTION_CURSOR_TOP: buffer.cursorTop()
    of ACTION_CURSOR_MIDDLE: buffer.cursorMiddle()
    of ACTION_CURSOR_BOTTOM: buffer.cursorBottom()
    of ACTION_CENTER_LINE: buffer.centerLine()
    of ACTION_SCROLL_DOWN: buffer.scrollDown()
    of ACTION_SCROLL_UP: buffer.scrollUp()
    of ACTION_SCROLL_LEFT: buffer.scrollLeft()
    of ACTION_SCROLL_RIGHT: buffer.scrollRight()
    of ACTION_CLICK:
      discard
    of ACTION_CHANGE_LOCATION:
      var url = $buffer.location

      let status = readLine("URL: ", url, buffer.width)
      if status:
        buffer.setLocation(parseUri(url))
        return true
    of ACTION_LINE_INFO:
      buffer.setStatusMessage("line " & $(buffer.cursory + 1) & "/" & $buffer.numLines & " col " & $(buffer.cursorx + 1) & "/" & $buffer.currentLineWidth() & " cell width: " & $buffer.currentCellWidth())
      nostatus = true
    of ACTION_FEED_NEXT:
      feedNext = true
    of ACTION_RELOAD: return true
    of ACTION_RESHAPE:
      reshape = true
      redraw = true
    of ACTION_REDRAW: redraw = true
    else: discard
    stdout.hideCursor()

    if buffer.refreshTermAttrs():
      redraw = true
      reshape = true

    if buffer.redraw:
      redraw = true

    if reshape:
      buffer.reshape()
    if redraw:
      buffer.refreshDisplay()
      buffer.displayBuffer()

    if not nostatus:
      buffer.statusMsgForBuffer()
    else:
      nostatus = false

proc displayPage*(attrs: TermAttributes, buffer: Buffer): bool =
  discard buffer.gotoAnchor()
  buffer.displayBuffer()
  buffer.statusMsgForBuffer()
  return inputLoop(attrs, buffer)

