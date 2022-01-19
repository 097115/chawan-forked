import unicode
import options

import layout/box
import html/tags
import html/dom
import css/values
import utils/twtstr
import io/term

func cells_in(l: CSSLength, state: Viewport, d: int, p: Option[int], o: bool): int =
  return cells(l, d, state.term.width_px, state.term.height_px, p, o)

func cells_w(l: CSSLength, state: Viewport, p: int): int =
  return l.cells_in(state, state.term.ppc, p.some, true)

func cells_h(l: CSSLength, state: Viewport, p: Option[int]): int =
  return l.cells_in(state, state.term.ppl, p, false)

func cells_h(l: CSSLength, state: Viewport, p: int): int =
  return l.cells_in(state, state.term.ppl, p.some, false)

#func newInlineContext*(): InlineContext =
#  new(result)
#  result.whitespace = true
#  result.ws_initial = true
#
#func newBlockContext(): BlockContext =
#  new(result)
#
#proc putRows(icontext: InlineContext) =
#  var i = 0
#  while i < icontext.rows.len:
#    icontext.rows[i].bottom = icontext.fromy
#    inc i
#
#proc flushRows(icontext: InlineContext) =
#  if icontext.thisrow.len == 0: return
#  icontext.putRows()
#  var y = 0
#  var re = false
#  y = icontext.thisrow[0].bottom
#  var i = 1
#  while i < icontext.thisrow.len:
#    let ry = icontext.thisrow[i].bottom
#    if y != ry:
#      re = true
#      if y < ry:
#        y = ry
#    inc i
#
#  if re:
#    i = 0
#    while i < icontext.thisrow.len:
#      icontext.thisrow[i].y = y + icontext.thisrow[i].y - icontext.thisrow[i].bottom
#      inc i
#  icontext.rows.add(icontext.thisrow)
#  icontext.thisrow.setLen(0)
#
#func conty(icontext: InlineContext): bool =
#  icontext.thisrow.len > 0
#
#proc flushConty(box: CSSBox) =
#  box.icontext.flushRows()
#  box.icontext.fromx = box.x
#  inc box.icontext.fromy
#  inc box.bcontext.fromy
#  box.icontext.whitespace = true
#  box.icontext.ws_initial = true
#
#proc flushMargins(box: CSSBox) =
#  box.icontext.fromy += box.bcontext.margin_todo
#  box.bcontext.margin_done += box.bcontext.margin_todo
#  box.bcontext.margin_todo = 0
#
#proc applyBlockStart(state: LayoutState, box, parent: CSSBox, vals: CSSSpecifiedValues) =
#  parent.flushMargins()
#  box.bcontext = newBlockContext()
#  box.x += vals{"margin-left"}.cells_w(state, parent.bcontext.width)
#
#  let mtop = vals{"margin-top"}.cells_h(state, parent.bcontext.width)
#  if mtop > parent.bcontext.margin_done or mtop < 0:
#    let diff = mtop - parent.bcontext.margin_done
#    parent.icontext.fromy += diff
#    parent.bcontext.margin_done += diff
#
#  box.y = parent.icontext.fromy
#  box.bcontext.margin_done = parent.bcontext.margin_done
#
#  let pwidth = vals{"width"}
#  if pwidth.auto:
#    box.bcontext.width = parent.bcontext.width
#  else:
#    box.bcontext.width = pwidth.cells_w(state, parent.bcontext.width)
#
#  let pheight = vals{"height"}
#  if not pheight.auto:
#    if pheight.unit != UNIT_PERC or parent.bcontext.height.issome:
#      box.bcontext.height = pheight.cells_h(state, parent.bcontext.height).some
#
#  box.cssvalues = vals
#
#func newBlockBox(state: var LayoutState, parent: CSSBox, vals: CSSSpecifiedValues): CSSBlockBox =
#  new(result)
#  result.t = BOX_BLOCK
#  if parent.icontext.conty:
#    parent.flushConty()
#  result.x = parent.x
#
#  state.applyBlockStart(result, parent, vals)
#  result.icontext = newInlineContext()
#  result.icontext.fromy = result.y
#  result.icontext.fromx = result.x
#
#func newInlineBlockBox*(state: LayoutState, parent: CSSBox, vals: CSSSpecifiedValues): CSSInlineBlockBox =
#  new(result)
#  result.t = BOX_INLINE_BLOCK
#  result.x = parent.icontext.fromx
#
#  state.applyBlockStart(result, parent, vals)
#  result.icontext = newInlineContext()
#  result.icontext.fromy = result.y
#  result.icontext.fromx = result.x
#
#func newInlineBox*(state: LayoutState, parent: CSSBox, vals: CSSSpecifiedValues): CSSInlineBox =
#  new(result)
#  result.t = BOX_INLINE
#  result.x = parent.x
#  result.y = parent.icontext.fromy
#
#  result.icontext = parent.icontext
#  result.bcontext = parent.bcontext
#  result.cssvalues = vals
#  result.icontext.fromx += vals{"margin-left"}.cells_w(state, parent.bcontext.width)
#
#type InlineState = object
#  icontext: InlineContext
#  bcontext: BlockContext
#  ibox: CSSInlineBox
#  rowbox: CSSRowBox
#  word: seq[Rune]
#  ww: int
#  skip: bool
#  nodes: seq[Node]
#  cssvalues: CSSSpecifiedValues
#  x: int
#
#func maxwidth(state: InlineState): int = state.bcontext.width
#
#proc newRowBox(state: var InlineState) =
#  state.rowbox = CSSRowBox()
#  state.rowbox.x = state.icontext.fromx
#  state.rowbox.y = state.icontext.fromy
#  state.rowbox.bottom = state.rowbox.y
#
#  let cssvalues = state.cssvalues
#  state.rowbox.color = cssvalues{"color"}
#  state.rowbox.fontstyle = cssvalues{"font-style"}
#  state.rowbox.fontweight = cssvalues{"font-weight"}
#  state.rowbox.textdecoration = cssvalues{"text-decoration"}
#  state.rowbox.nodes = state.nodes
#
#proc addRowBox(state: var InlineState) =
#  state.icontext.thisrow.add(state.rowbox)
#
#proc inlineWrap(state: var InlineState) =
#  state.addRowBox()
#  state.icontext.flushRows()
#  inc state.icontext.fromy
#  state.icontext.fromx = state.x
#  if state.word.len == 0:
#    state.icontext.whitespace = true
#    state.icontext.ws_initial = true
#  else:
#    if state.word[^1] == Rune(' '):
#      state.icontext.whitespace = true
#      state.icontext.ws_initial = false
#  state.newRowBox()
#
#proc addWord(state: var InlineState) =
#  state.rowbox.str &= $state.word
#  state.rowbox.width += state.ww
#  state.ibox.width += state.ww
#  state.ibox.width = min(state.maxwidth, state.ibox.width)
#  state.word.setLen(0)
#  state.ww = 0
#
#proc wrapNormal(state: var InlineState, r: Rune) =
#  if state.icontext.fromx + state.rowbox.width + state.ww == state.maxwidth and r == Rune(' '):
#    state.addWord()
#  if state.word.len == 0:
#    if r == Rune(' '):
#      state.skip = true
#  elif state.word[0] == Rune(' '):
#    state.word = state.word.substr(1)
#    dec state.ww
#  state.inlineWrap()
#  if not state.skip and r == Rune(' '):
#    state.icontext.whitespace = true
#    state.icontext.ws_initial = false
#
#proc checkWrap(state: var InlineState, r: Rune) =
#  if state.cssvalues{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
#    return
#  case state.cssvalues{"word-break"}
#  of WORD_BREAK_NORMAL:
#    if state.icontext.fromx + state.rowbox.width > state.x and
#        state.icontext.fromx + state.rowbox.width + state.ww + r.width() > state.maxwidth:
#      state.wrapNormal(r)
#  of WORD_BREAK_BREAK_ALL:
#    if state.icontext.fromx + state.rowbox.width + state.ww + r.width() > state.maxwidth:
#      var pl: seq[Rune]
#      var i = 0
#      var w = 0
#      while i < state.word.len and
#          state.icontext.fromx + state.rowbox.width + w <
#            state.bcontext.width:
#        pl &= state.word[i]
#        w += state.word[i].width()
#        inc i
#
#      if pl.len > 0:
#        state.rowbox.str &= $pl
#        state.rowbox.width += w
#        state.word = state.word.substr(pl.len)
#        state.ww = state.word.width()
#      if r == Rune(' '):
#        state.skip = true
#      state.inlineWrap()
#  of WORD_BREAK_KEEP_ALL:
#    if state.icontext.fromx + state.rowbox.width > state.x and
#        state.icontext.fromx + state.rowbox.width + state.ww + r.width() > state.maxwidth:
#      state.wrapNormal(r)
#
#proc preWrap(state: var InlineState) =
#  state.inlineWrap()
#  state.icontext.whitespace = false
#  state.icontext.ws_initial = true
#  state.skip = true
#
#proc processInlineText(str: string, ibox: CSSInlineBox, nodes: seq[Node]) =
#  var state: InlineState
#  state.ibox = ibox
#  state.icontext = ibox.icontext
#  state.bcontext = ibox.bcontext
#  state.cssvalues = ibox.cssvalues
#  state.x = ibox.x
#  state.nodes = nodes
#
#  var i = 0
#  state.newRowBox()
#
#  var r: Rune
#  while i < str.len:
#    var rw = 0
#    case str[i]
#    of ' ', '\n', '\t':
#      rw = 1
#      r = Rune(str[i])
#      inc i
#      state.addWord()
#
#      case state.cssvalues{"white-space"}
#      of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
#        if state.icontext.whitespace:
#          if state.icontext.ws_initial:
#            state.icontext.ws_initial = false
#            state.skip = true
#          else:
#            state.skip = true
#        state.icontext.whitespace = true
#      of WHITESPACE_PRE_LINE:
#        if state.icontext.whitespace:
#          state.skip = true
#        state.icontext.ws_initial = false
#        if r == Rune('\n'):
#          state.preWrap()
#      of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
#        state.icontext.ws_initial = false
#        if r == Rune('\n'):
#          state.preWrap()
#      r = Rune(' ')
#    else:
#      state.icontext.whitespace = false
#      fastRuneAt(str, i, r)
#      rw = r.width()
#
#    # TODO a better line wrapping algorithm would be nice... especially because
#    # this one doesn't even work
#    if rw > 1 or state.cssvalues{"word-break"} == WORD_BREAK_BREAK_ALL:
#      state.addWord()
#
#    state.checkWrap(r)
#
#    if state.skip:
#      state.skip = false
#      continue
#
#    state.word &= r
#    state.ww += rw
#
#  state.addWord()
#
#  if state.rowbox.str.len > 0:
#    state.addRowBox()
#    state.icontext.fromx += state.rowbox.width
#
#  state.bcontext.margin_todo = 0
#  state.bcontext.margin_done = 0
#
#proc processInlineContext(ibox: CSSInlineBox, str: string, nodes: seq[Node]) =
#  processInlineText(str, ibox, nodes)
#
#proc processInlineBox(state: var LayoutState, parent: CSSBox, str: string): CSSInlineBox =
#  if str.len == 0:
#    return nil
#
#  #TODO this doesn't really belong in here
#  parent.flushMargins()
#
#  if parent of CSSInlineBox:
#    let ibox = CSSInlineBox(parent)
#    ibox.processInlineContext(str, state.nodes)
#    return nil
#
#  let ibox = state.newInlineBox(parent, parent.cssvalues.inheritProperties())
#  ibox.processInlineContext(str, state.nodes)
#  return ibox
#
#proc applyBlockEnd(state: var LayoutState, parent, box: CSSBox) =
#  box.flushMargins()
#
#  let mbot = box.cssvalues{"margin-bottom"}.cells_h(state, parent.bcontext.width)
#  parent.bcontext.margin_todo += mbot
#
#  parent.bcontext.margin_done = box.bcontext.margin_done
#  parent.bcontext.margin_todo = max(parent.bcontext.margin_todo - box.bcontext.margin_done, 0)
#
#  if box.bcontext.height.isnone:
#    parent.icontext.fromy = box.icontext.fromy
#  else:
#    parent.icontext.fromy += box.bcontext.height.get
#
#proc add(state: var LayoutState, parent: CSSBox, box: CSSBlockBox) =
#  parent.icontext.fromx = parent.x
#  if box.icontext.conty:
#    box.flushConty()
#
#  state.applyBlockEnd(parent, box)
#  parent.children.add(box)
#
#proc add(state: var LayoutState, parent: CSSBox, box: CSSInlineBox) =
#  parent.width = max(parent.width, box.width)
#  parent.icontext.fromx += box.cssvalues{"margin-right"}.cells_w(state, parent.bcontext.width)
#  parent.icontext.fromy = box.icontext.fromy
#
#  parent.children.add(box)
#
#proc add(state: var LayoutState, parent: CSSBox, box: CSSInlineBlockBox) =
#  parent.width = max(parent.width, box.width)
#  parent.icontext.fromx = max(box.icontext.fromx, box.x + box.width)
#  parent.icontext.fromx += box.cssvalues{"margin-right"}.cells_w(state, parent.bcontext.width)
#  parent.icontext.whitespace = box.icontext.whitespace
#  parent.icontext.ws_initial = box.icontext.ws_initial
#
#  box.icontext.putRows()
#  parent.icontext.thisrow.add(box.icontext.rows)
#  parent.icontext.thisrow.add(box.icontext.thisrow)
#  box.icontext.rows.setLen(0)
#  box.icontext.thisrow.setLen(0)
#
#  state.applyBlockEnd(parent, box)
#  parent.children.add(box)
#
#proc add(state: var LayoutState, parent: CSSBox, box: CSSBox) =
#  case box.t
#  of BOX_BLOCK: state.add(parent, CSSBlockBox(box))
#  of BOX_INLINE: state.add(parent, CSSInlineBox(box))
#  of BOX_INLINE_BLOCK: state.add(parent, CSSInlineBlockBox(box))
#
#proc processComputedValueBox(state: var LayoutState, parent: CSSBox, values: CSSSpecifiedValues): CSSBox =
#  case values{"display"}
#  of DISPLAY_BLOCK:
#    result = state.newBlockBox(parent, values)
#  of DISPLAY_INLINE_BLOCK:
#    result = state.newInlineBlockBox(parent, values)
#  of DISPLAY_INLINE:
#    result = state.newInlineBox(parent, values)
#  of DISPLAY_LIST_ITEM:
#    result = state.newBlockBox(parent, values)
#  of DISPLAY_NONE:
#    return nil
#  else:
#    return nil
#
#proc processBr(state: var LayoutState, parent: CSSBox, vals: CSSSpecifiedValues) =
#  if vals{"display"} == DISPLAY_INLINE:
#    if parent.icontext.conty:
#      parent.flushConty()
#    else:
#      inc parent.bcontext.fromy
#      inc parent.icontext.fromy
#    parent.icontext.fromx = parent.x
#
#proc processElemBox(state: var LayoutState, parent: CSSBox, elem: Element): CSSBox =
#  if elem.tagType == TAG_BR:
#    state.processBr(parent, elem.css)
#
#  result = state.processComputedValueBox(parent, elem.css)
#  if result != nil:
#    result.node = elem
#
#proc processElemChildren(state: var LayoutState, parent: CSSBox, elem: Element)
#
#proc processNode(state: var LayoutState, parent: CSSBox, node: Node): CSSBox =
#  case node.nodeType
#  of ELEMENT_NODE:
#    let elem = Element(node)
#    result = state.processElemBox(parent, Element(node))
#    if result == nil:
#      return
#
#    state.processElemChildren(result, elem)
#  of TEXT_NODE:
#    let text = Text(node)
#    result = state.processInlineBox(parent, text.data)
#    if result != nil:
#      result.node = node
#  else: discard
#
#proc processBeforePseudoElem(state: var LayoutState, parent: CSSBox, elem: Element) =
#  if elem.pseudo[PSEUDO_BEFORE] != nil:
#    let box = state.processComputedValueBox(parent, elem.pseudo[PSEUDO_BEFORE])
#    if box == nil: return
#    box.node = elem
#
#    let text = elem.pseudo[PSEUDO_BEFORE]{"content"}
#    var inline = state.processInlineBox(box, $text)
#    if inline != nil:
#      inline.node = elem
#      state.add(box, inline)
#
#    state.add(parent, box)
#
#proc processAfterPseudoElem(state: var LayoutState, parent: CSSBox, elem: Element) =
#  if elem.pseudo[PSEUDO_AFTER] != nil:
#    let box = state.processComputedValueBox(parent, elem.pseudo[PSEUDO_AFTER])
#    if box == nil: return
#    box.node = elem
#
#    let text = elem.pseudo[PSEUDO_AFTER]{"content"}
#    var inline = state.processInlineBox(box, $text)
#    if inline != nil:
#      inline.node = elem
#      state.add(box, inline)
#
#    state.add(parent, box)
#
#proc processMarker(state: var LayoutState, parent: CSSBox, elem: Element) =
#  if elem.css{"display"} == DISPLAY_LIST_ITEM:
#    var ordinalvalue = 1
#    if elem.tagType == TAG_LI:
#      ordinalvalue = HTMLLIElement(elem).ordinalvalue
#
#    let text = elem.css{"list-style-type"}.listMarker(ordinalvalue)
#    let tlen = text.width()
#    parent.icontext.fromx -= tlen
#    let marker = state.processInlineBox(parent, text)
#    if marker != nil:
#      state.add(parent, marker)
#
#proc processNodes(state: var LayoutState, parent: CSSBox, nodes: seq[Node]) =
#  for node in nodes:
#    let box = state.processNode(parent, node)
#    if box != nil:
#      state.add(parent, box)
#
#proc processElemChildren(state: var LayoutState, parent: CSSBox, elem: Element) =
#  state.nodes.add(elem)
#
#  state.processBeforePseudoElem(parent, elem)
#  state.processMarker(parent, elem)
#  state.processNodes(parent, elem.childNodes)
#  state.processAfterPseudoElem(parent, elem)
#
#  discard state.nodes.pop()
#
#proc alignBoxes*(document: Document, term: TermAttributes): CSSBox =
#  var state: LayoutState
#  state.term = term
#  var rootbox = CSSBlockBox(x: 0, y: 0)
#  rootbox.cssvalues = rootProperties()
#  rootbox.bcontext = newBlockContext()
#  rootbox.icontext = newInlineContext()
#  rootbox.bcontext.width = term.width
#  state.nodes.add(document.root)
#  state.processElemChildren(rootbox, document.root)
#  return rootbox

type InlineState = object
  ictx: InlineContext
  skip: bool
  nodes: seq[Node]
  word: InlineWord
  maxwidth: int
  specified: CSSSpecifiedValues

proc newWord(state: var InlineState) =
  let word = InlineWord()
  let specified = state.specified
  word.color = specified{"color"}
  word.fontstyle = specified{"font-style"}
  word.fontweight = specified{"font-weight"}
  word.textdecoration = specified{"text-decoration"}
  word.nodes = state.nodes
  state.word = word

proc addAtom(row: InlineRow, atom: InlineAtom) =
  atom.relx = row.width
  row.width += atom.width
  row.height = max(row.height, atom.height)
  row.atoms.add(atom)

proc addWord(state: var InlineState) =
  if state.word.str != "":
    let row = state.ictx.thisrow
    var word = state.word
    # Note, this should technically be set as soon as word has one letter but
    # in practice this doesn't matter.
    word.height = 1
    row.addAtom(word)
    state.newWord()

proc finishRow(ictx: InlineContext) =
  if ictx.thisrow != nil and ictx.thisrow.atoms.len > 0:
    let oldrow = ictx.thisrow
    ictx.rows.add(oldrow)
    ictx.height += oldrow.height
    ictx.width = max(ictx.width, oldrow.width)
    ictx.thisrow = InlineRow(rely: oldrow.rely + oldrow.height)

proc inlineWrap(state: var InlineState) =
  state.addWord()
  state.ictx.finishRow()

proc wrap(state: var InlineState, r: Rune) =
  if state.ictx.thisrow.width + state.word.width == state.maxwidth and r == Rune(' '):
    state.addWord()
  if state.word.str.len == 0:
    if r == Rune(' '):
      state.skip = true
  elif state.word.str[0] == ' ':
    state.word.str = state.word.str.substr(1)
    dec state.word.width
  state.inlineWrap()
  if not state.skip and r == Rune(' '):
    state.ictx.whitespace = true
    state.ictx.ws_initial = false

proc checkWrap(state: var InlineState, r: Rune) =
  if state.specified{"white-space"} in {WHITESPACE_NOWRAP, WHITESPACE_PRE}:
    return
  if state.ictx.thisrow.width > state.maxwidth:
    state.wrap(r)

proc flushLine(ictx: InlineContext) =
  let oldrow = ictx.thisrow
  oldrow.height = max(oldrow.height, 1)
  ictx.rows.add(oldrow)
  ictx.thisrow = InlineRow()
  ictx.thisrow.relx = oldrow.relx
  ictx.ws_initial = true
  ictx.whitespace = true
  ictx.thisrow.rely = oldrow.rely + oldrow.height
  inc ictx.height

proc preWrap(state: var InlineState) =
  state.inlineWrap()
  state.ictx.whitespace = false
  state.ictx.ws_initial = true
  state.skip = true

proc processWhitespace(state: var InlineState, r: Rune) =
  case state.specified{"white-space"}
  of WHITESPACE_NORMAL, WHITESPACE_NOWRAP:
    if state.ictx.whitespace:
      state.ictx.ws_initial = false
      state.skip = true
    state.ictx.whitespace = true
  of WHITESPACE_PRE_LINE:
    if state.ictx.whitespace:
      state.skip = true
    state.ictx.ws_initial = false
    if r == Rune('\n'):
      state.preWrap()
  of WHITESPACE_PRE, WHITESPACE_PRE_WRAP:
    state.ictx.ws_initial = false
    if r == Rune('\n'):
      state.preWrap()

proc renderText*(ictx: InlineContext, str: string, maxwidth: int, specified: CSSSpecifiedValues) =
  var state: InlineState
  state.specified = specified
  state.ictx = ictx
  state.maxwidth = maxwidth
  state.newWord()

  var i = 0

  #if str.strip().len > 0:
    #eprint "start", str.strip()
  var r: Rune
  while i < str.len:
    var rw = 0
    case str[i]
    of ' ', '\n', '\t':
      rw = 1
      r = Rune(str[i])
      inc i
      state.addWord()
      #eprint "process", int(r)
      state.processWhitespace(r)
      #eprint "skip?", state.skip
      r = Rune(' ')
    else:
      ictx.whitespace = false
      fastRuneAt(str, i, r)
      rw = r.width()

#    # TODO line wrapping
#    if rw > 1 or state.cssvalues{"word-break"} == WORD_BREAK_BREAK_ALL:
#      state.addWord()

    state.checkWrap(r)

    if state.skip:
      state.skip = false
      continue

    #eprint "rune is", int(r)
    state.word.str &= r
    state.word.width += rw

  state.addWord()

proc finish(ictx: InlineContext) =
  ictx.finishRow()

template newBlockContext_common(parent: BlockContext, box: CSSBox) =
  new(result)
  result.rely = parent.height
  result.viewport = parent.viewport
  let pwidth = box.specified{"width"}
  if pwidth.auto:
    result.compwidth = parent.compwidth
  else:
    result.compwidth = pwidth.cells_w(parent.viewport, parent.compwidth)
  result.specified = parent.specified

proc newBlockContext(parent: BlockContext, box: BlockBox): BlockContext =
  newBlockContext_common(parent, box)
  parent.nested.add(result)

proc newInlineBlockContext(parent: BlockContext, box: InlineBlockBox): BlockContext =
  newBlockContext_common(parent, box)

proc newBlockContext(viewport: Viewport): BlockContext =
  new(result)
  result.compwidth = viewport.term.width
  result.specified = rootProperties()
  result.viewport = viewport

proc newBlockContext(parent: BlockContext): BlockContext =
  new(result)
  result.rely = parent.height
  result.compwidth = parent.compwidth
  result.specified = parent.specified.inheritProperties()
  result.viewport = parent.viewport
  parent.nested.add(result)

proc newInlineContext(bctx: BlockContext): InlineContext =
  new(result)
  result.ws_initial = true
  result.whitespace = true
  result.thisrow = InlineRow()
  bctx.inline = result

proc alignInline(pctx: BlockContext, box: InlineBox) =
  let box = InlineBox(box)
  if box.ictx == nil:
    box.ictx = pctx.newInlineContext()
  if box.newline:
    box.ictx.flushLine()
  for text in box.text:
    assert box.children.len == 0
    box.ictx.renderText(text, pctx.compwidth, box.specified)

  for child in box.children:
    let child = InlineBox(child)
    child.ictx = box.ictx
    pctx.alignInline(child)

proc alignBlock(box: BlockBox)

proc alignInlines(bctx: BlockContext, inlines: seq[CSSBox]) =
  let ictx = bctx.newInlineContext()
  for child in inlines:
    case child.t
    of BOX_INLINE:
      let child = InlineBox(child)
      child.ictx = ictx
      bctx.alignInline(child)
    of BOX_INLINE_BLOCK:
      let child = InlineBlockBox(child)
      child.bctx = bctx.newInlineBlockContext(child)
      alignBlock(child)
      child.ictx = ictx
      child.bctx.relx = ictx.thisrow.width
      if ictx.thisrow.width + child.bctx.width > ictx.maxwidth:
        ictx.finishRow()
      ictx.thisrow.addAtom(child.bctx)
      ictx.thisrow.height = max(ictx.thisrow.height, child.bctx.height)
    else:
      assert false
  ictx.finish()
  bctx.height += ictx.height
  bctx.width = max(bctx.width, ictx.width)

proc alignBlocks(bctx: BlockContext, blocks: seq[CSSBox]) =
  # Box contains block boxes.
  # If present, group inline boxes together in anonymous block boxes. Place
  # block boxes inbetween these.
  var blockgroup: seq[CSSBox]
  var has_noinline = false
  template flush_group() =
    if blockgroup.len > 0:
      let gctx = newBlockContext(bctx)
      gctx.alignInlines(blockgroup)
      bctx.height += gctx.height
      bctx.width = max(bctx.width, gctx.width)
      blockgroup.setLen(0)

  for child in blocks:
    case child.t
    of BOX_BLOCK:
      let child = BlockBox(child)
      flush_group()
      child.bctx = newBlockContext(bctx, child)
      alignBlock(child)
      bctx.height += child.bctx.height
      bctx.width = max(bctx.width, child.bctx.width)
    of BOX_INLINE:
      if child.inlinelayout:
        blockgroup.add(child)
      else:
        flush_group()
        bctx.alignBlocks(child.children)
        #eprint "put"
    of BOX_INLINE_BLOCK:
      blockgroup.add(child)
    else: discard #TODO
  flush_group()

proc alignBlock(box: BlockBox) =
  if box.inlinelayout:
    # Box only contains inline boxes.
    box.bctx.alignInlines(box.children)
  else:
    box.bctx.alignBlocks(box.children)

proc getBox(specified: CSSSpecifiedValues): CSSBox =
  case specified{"display"}
  of DISPLAY_BLOCK:
    result = BlockBox()
    result.t = BOX_BLOCK
  of DISPLAY_INLINE_BLOCK:
    result = InlineBlockBox()
    result.t = BOX_INLINE_BLOCK
  of DISPLAY_INLINE:
    result = InlineBox()
    result.t = BOX_INLINE
  of DISPLAY_LIST_ITEM:
    result = ListItemBox()
    result.t = BOX_LIST_ITEM
  of DISPLAY_NONE: return nil
  else: return nil
  result.specified = specified

proc getTextBox(box: CSSBox): InlineBox =
  new(result)
  result.inlinelayout = true
  result.specified = box.specified

proc getPseudoBox(specified: CSSSpecifiedValues): CSSBox =
  let box = getBox(specified)
  if box == nil:
    return nil
  box.inlinelayout = true
  if specified{"content"}.len > 0:
    let content = getTextBox(box)
    content.text.add($specified{"content"})
    box.children.add(content)
  return box

proc generateBox(elem: Element): CSSBox =
  let box = getBox(elem.css)

  if box == nil:
    return nil

  var ibox: InlineBox
  template add_ibox() =
    if ibox != nil:
      box.children.add(ibox)
      ibox = nil

  template add_box(child: CSSBox) =
    box.children.add(child)
    if child.t != BOX_INLINE or not child.inlinelayout:
      box.inlinelayout = false

  box.inlinelayout = true
  let before = elem.pseudo[PSEUDO_BEFORE]
  if before != nil:
    let bbox = getPseudoBox(before)
    if bbox != nil:
      add_box(bbox)

  for child in elem.childNodes:
    case child.nodeType
    of ELEMENT_NODE:
      let elem = Element(child)
      if elem.tagType == TAG_BR:
        add_ibox()
        ibox = box.getTextBox()
        ibox.newline = true

      let cbox = generateBox(elem)
      if cbox != nil:
        add_ibox()
        add_box(cbox)
    of TEXT_NODE:
      if ibox == nil:
        ibox = box.getTextBox()
      ibox.text.add(Text(child).data)
    else: discard
  add_ibox()

  let after = elem.pseudo[PSEUDO_AFTER]
  if after != nil:
    let abox = getPseudoBox(after)
    if abox != nil:
      add_box(abox)

  return box

proc generateBoxes(document: Document): BlockBox =
  let box = document.root.generateBox()
  assert box != nil
  assert box.t == BOX_BLOCK #TODO this shouldn't be enforced by the ua stylesheet

  return BlockBox(box)

proc renderLayout*(document: Document, term: TermAttributes): BlockBox =
  #eprint document.root
  let viewport = Viewport(term: term)
  let root = document.generateBoxes()
  root.bctx = viewport.newBlockContext()
  alignBlock(root)
  return root
