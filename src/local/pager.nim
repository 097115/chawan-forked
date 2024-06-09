import std/deques
import std/net
import std/options
import std/os
import std/osproc
import std/posix
import std/selectors
import std/tables
import std/unicode

import config/chapath
import config/config
import config/mailcap
import io/bufreader
import io/dynstream
import io/posixstream
import io/promise
import io/socketstream
import io/stdio
import io/tempfile
import io/urlfilter
import loader/connecterror
import loader/headers
import loader/loader
import loader/request
import local/container
import local/lineedit
import local/select
import local/term
import monoucha/fromjs
import monoucha/javascript
import monoucha/jserror
import monoucha/jsregex
import monoucha/jstypes
import monoucha/jsutils
import monoucha/libregexp
import monoucha/quickjs
import monoucha/tojs
import server/buffer
import server/forkserver
import types/cell
import types/color
import types/cookie
import types/opt
import types/url
import types/winattrs
import utils/luwrap
import utils/mimeguess
import utils/regexutils
import utils/strwidth
import utils/twtstr

import chagashi/charset

type
  LineMode* = enum
    lmLocation = "URL: "
    lmUsername = "Username: "
    lmPassword = "Password: "
    lmCommand = "COMMAND: "
    lmBuffer = "(BUFFER) "
    lmSearchF = "/"
    lmSearchB = "?"
    lmISearchF = "/"
    lmISearchB = "?"
    lmGotoLine = "Goto line: "
    lmDownload = "(Download)Save file to: "
    lmBufferFile = "(Upload)Filename: "

  # fdin is the original fd; fdout may be the same, or different if mailcap
  # is used.
  ProcMapItem = object
    container*: Container
    fdin*: FileHandle
    fdout*: FileHandle
    istreamOutputId*: int
    ostreamOutputId*: int

  PagerAlertState = enum
    pasNormal, pasAlertOn, pasLoadInfo

  ContainerConnectionState = enum
    ccsBeforeResult, ccsBeforeStatus, ccsBeforeHeaders

  ConnectingContainerItem = ref object
    state: ContainerConnectionState
    container: Container
    stream*: SocketStream
    res: int
    outputId: int
    status: uint16

  LineData = ref object of RootObj

  LineDataDownload = ref object of LineData
    outputId: int
    stream: DynStream

  LineDataAuth = ref object of LineData
    url: URL

  NavDirection = enum
    ndPrev = "prev"
    ndNext = "next"
    ndPrevSibling = "prev-sibling"
    ndNextSibling = "next-sibling"
    ndParent = "parent"
    ndFirstChild
    ndAny = "any"

  Pager* = ref object
    alertState: PagerAlertState
    alerts*: seq[string]
    askcharpromise*: Promise[string]
    askcursor: int
    askpromise*: Promise[bool]
    askprompt: string
    commandMode {.jsget.}: bool
    config*: Config
    connectingContainers*: seq[ConnectingContainerItem]
    container*: Container
    cookiejars: Table[string, CookieJar]
    devRandom: PosixStream
    display: FixedGrid
    forkserver*: ForkServer
    formRequestMap*: Table[string, FormRequestType]
    hasload*: bool # has a page been successfully loaded since startup?
    inputBuffer*: string # currently uninterpreted characters
    iregex: Result[Regex, string]
    isearchpromise: EmptyPromise
    jsctx: JSContext
    lineData: LineData
    lineedit*: Option[LineEdit]
    linehist: array[LineMode, LineHistory]
    linemode: LineMode
    loader*: FileLoader
    luctx: LUContext
    navDirection {.jsget.}: NavDirection
    notnum*: bool # has a non-numeric character been input already?
    numload*: int # number of pages currently being loaded
    precnum*: int32 # current number prefix (when vi-numeric-prefix is true)
    procmap*: seq[ProcMapItem]
    redraw: bool
    regex: Opt[Regex]
    reverseSearch: bool
    scommand*: string
    selector*: Selector[int]
    statusgrid*: FixedGrid
    term*: Terminal
    unreg*: seq[Container]

jsDestructor(Pager)

# Forward declarations
proc alert*(pager: Pager; msg: string)

template attrs(pager: Pager): WindowAttributes =
  pager.term.attrs

func loaderPid(pager: Pager): int64 {.jsfget.} =
  int64(pager.loader.process)

func getRoot(container: Container): Container =
  var c = container
  while c.parent != nil: c = c.parent
  return c

# depth-first descendant iterator
iterator descendants(parent: Container): Container {.inline.} =
  var stack = newSeqOfCap[Container](parent.children.len)
  for i in countdown(parent.children.high, 0):
    stack.add(parent.children[i])
  while stack.len > 0:
    let c = stack.pop()
    # add children first, so that deleteContainer works on c
    for i in countdown(c.children.high, 0):
      stack.add(c.children[i])
    yield c

iterator containers*(pager: Pager): Container {.inline.} =
  if pager.container != nil:
    let root = getRoot(pager.container)
    yield root
    for c in root.descendants:
      yield c

proc setContainer*(pager: Pager; c: Container) {.jsfunc.} =
  pager.container = c
  pager.redraw = true
  if c != nil:
    pager.term.setTitle(c.getTitle())

proc hasprop(ctx: JSContext; pager: Pager; s: string): bool {.jshasprop.} =
  result = false
  if pager.container != nil:
    let cval = toJS(ctx, pager.container)
    let val = JS_GetPropertyStr(ctx, cval, s)
    if val != JS_UNDEFINED:
      result = true
    JS_FreeValue(ctx, val)

proc reflect(ctx: JSContext; this_val: JSValue; argc: cint;
    argv: ptr UncheckedArray[JSValue]; magic: cint;
    func_data: ptr UncheckedArray[JSValue]): JSValue {.cdecl.} =
  let obj = func_data[0]
  let fun = func_data[1]
  return JS_Call(ctx, fun, obj, argc, argv)

proc getter(ctx: JSContext; pager: Pager; a: JSAtom): Option[JSValue]
    {.jsgetprop.} =
  if pager.container != nil:
    let cval = toJS(ctx, pager.container)
    let val = JS_GetProperty(ctx, cval, a)
    if JS_IsFunction(ctx, val):
      let func_data = @[cval, val]
      let fun = JS_NewCFunctionData(ctx, reflect, 1, 0, 2,
        func_data.toJSValueArray())
      JS_FreeValue(ctx, cval)
      JS_FreeValue(ctx, val)
      return some(fun)
    JS_FreeValue(ctx, cval)
    if not JS_IsUndefined(val):
      return some(val)
  return none(JSValue)

proc searchNext(pager: Pager; n = 1) {.jsfunc.} =
  if pager.regex.isSome:
    let wrap = pager.config.search.wrap
    pager.container.markPos0()
    if not pager.reverseSearch:
      pager.container.cursorNextMatch(pager.regex.get, wrap, true, n)
    else:
      pager.container.cursorPrevMatch(pager.regex.get, wrap, true, n)
    pager.container.markPos()
  else:
    pager.alert("No previous regular expression")

proc searchPrev(pager: Pager; n = 1) {.jsfunc.} =
  if pager.regex.isSome:
    let wrap = pager.config.search.wrap
    pager.container.markPos0()
    if not pager.reverseSearch:
      pager.container.cursorPrevMatch(pager.regex.get, wrap, true, n)
    else:
      pager.container.cursorNextMatch(pager.regex.get, wrap, true, n)
    pager.container.markPos()
  else:
    pager.alert("No previous regular expression")

proc getLineHist(pager: Pager; mode: LineMode): LineHistory =
  if pager.linehist[mode] == nil:
    pager.linehist[mode] = newLineHistory()
  return pager.linehist[mode]

proc setLineEdit(pager: Pager; mode: LineMode; current = ""; hide = false;
    extraPrompt = "") =
  let hist = pager.getLineHist(mode)
  if pager.term.isatty() and pager.config.input.use_mouse:
    pager.term.disableMouse()
  let edit = readLine($mode & extraPrompt, current, pager.attrs.width, {}, hide,
    hist)
  pager.lineedit = some(edit)
  pager.linemode = mode

proc clearLineEdit(pager: Pager) =
  pager.lineedit = none(LineEdit)
  if pager.term.isatty() and pager.config.input.use_mouse:
    pager.term.enableMouse()

proc searchForward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit(lmSearchF)

proc searchBackward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit(lmSearchB)

proc isearchForward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.isearchpromise = newResolvedPromise()
  pager.container.markPos0()
  pager.setLineEdit(lmISearchF)

proc isearchBackward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.isearchpromise = newResolvedPromise()
  pager.container.markPos0()
  pager.setLineEdit(lmISearchB)

proc gotoLine[T: string|int](pager: Pager; s: T = "") {.jsfunc.} =
  when s is string:
    if s == "":
      pager.setLineEdit(lmGotoLine)
      return
  pager.container.gotoLine(s)

proc dumpAlerts*(pager: Pager) =
  for msg in pager.alerts:
    stderr.write("cha: " & msg & '\n')

proc quit*(pager: Pager) =
  pager.term.quit()
  pager.dumpAlerts()

proc newPager*(config: Config; forkserver: ForkServer; ctx: JSContext;
    alerts: seq[string]): Pager =
  return Pager(
    config: config,
    forkserver: forkserver,
    term: newTerminal(stdout, config),
    alerts: alerts,
    jsctx: ctx,
    luctx: LUContext()
  )

proc genClientKey(pager: Pager): ClientKey =
  var key: ClientKey
  let n = pager.devRandom.recvData(addr key[0], key.len)
  doAssert n == key.len
  return key

proc addLoaderClient*(pager: Pager; pid: int; config: LoaderClientConfig):
    ClientKey =
  var key = pager.genClientKey()
  while unlikely(not pager.loader.addClient(key, pid, config)):
    key = pager.genClientKey()
  return key

proc setLoader*(pager: Pager; loader: FileLoader) =
  pager.devRandom = newPosixStream("/dev/urandom", O_RDONLY, 0)
  pager.loader = loader
  let config = LoaderClientConfig(
    defaultHeaders: newHeaders(pager.config.network.default_headers),
    proxy: pager.config.network.proxy,
    filter: newURLFilter(default = true),
  )
  loader.key = pager.addLoaderClient(pager.loader.clientPid, config)

proc launchPager*(pager: Pager; istream: PosixStream; selector: Selector[int]) =
  pager.selector = selector
  case pager.term.start(istream)
  of tsrSuccess: discard
  of tsrDA1Fail:
    pager.alert("Failed to query DA1, please set display.query-da1 = false")
  pager.display = newFixedGrid(pager.attrs.width, pager.attrs.height - 1)
  pager.statusgrid = newFixedGrid(pager.attrs.width)

proc clearDisplay(pager: Pager) =
  pager.display = newFixedGrid(pager.display.width, pager.display.height)

proc buffer(pager: Pager): Container {.jsfget, inline.} = pager.container

proc refreshDisplay(pager: Pager; container = pager.container) =
  pager.clearDisplay()
  let hlcolor = cellColor(pager.config.display.highlight_color)
  container.drawLines(pager.display, hlcolor)
  if pager.config.display.highlight_marks:
    container.highlightMarks(pager.display, hlcolor)

# Note: this function does not work correctly if start < i of last written char
proc writeStatusMessage(pager: Pager; str: string; format = Format();
    start = 0; maxwidth = -1; clip = '$'): int {.discardable.} =
  var maxwidth = maxwidth
  if maxwidth == -1:
    maxwidth = pager.statusgrid.len
  var i = start
  let e = min(start + maxwidth, pager.statusgrid.width)
  if i >= e:
    return i
  for r in str.runes:
    let w = r.width()
    if i + w >= e:
      pager.statusgrid[i].format = format
      pager.statusgrid[i].str = $clip
      inc i # Note: we assume `clip' is 1 cell wide
      break
    if r.isControlChar():
      pager.statusgrid[i].str = "^"
      pager.statusgrid[i + 1].str = $getControlLetter(char(r))
      pager.statusgrid[i + 1].format = format
    else:
      pager.statusgrid[i].str = $r
    pager.statusgrid[i].format = format
    i += w
  result = i
  var def = Format()
  while i < e:
    pager.statusgrid[i].str = ""
    pager.statusgrid[i].format = def
    inc i

# Note: should only be called directly after user interaction.
proc refreshStatusMsg*(pager: Pager) =
  let container = pager.container
  if container == nil: return
  if pager.askpromise != nil: return
  if pager.precnum != 0:
    pager.writeStatusMessage($pager.precnum & pager.inputBuffer)
  elif pager.inputBuffer != "":
    pager.writeStatusMessage(pager.inputBuffer)
  elif pager.alerts.len > 0:
    pager.alertState = pasAlertOn
    pager.writeStatusMessage(pager.alerts[0])
    pager.alerts.delete(0)
  else:
    var format = Format(flags: {ffReverse})
    pager.alertState = pasNormal
    container.clearHover()
    var msg = $(container.cursory + 1) & "/" & $container.numLines & " (" &
              $container.atPercentOf() & "%)"
    let mw = pager.writeStatusMessage(msg, format)
    let title = " <" & container.getTitle() & ">"
    let hover = container.getHoverText()
    if hover.len == 0:
      pager.writeStatusMessage(title, format, mw)
    else:
      let hover2 = " " & hover
      let maxwidth = pager.statusgrid.width - hover2.width() - mw
      let tw = pager.writeStatusMessage(title, format, mw, maxwidth, '>')
      pager.writeStatusMessage(hover2, format, tw)

# Call refreshStatusMsg if no alert is being displayed on the screen.
# Alerts take precedence over load info, but load info is preserved when no
# pending alerts exist.
proc showAlerts*(pager: Pager) =
  if (pager.alertState == pasNormal or
      pager.alertState == pasLoadInfo and pager.alerts.len > 0) and
      pager.inputBuffer == "" and pager.precnum == 0:
    pager.refreshStatusMsg()

proc drawBuffer*(pager: Pager; container: Container; ofile: File) =
  var format = Format()
  container.readLines(proc(line: SimpleFlexibleLine) =
    if line.formats.len == 0:
      ofile.write(line.str & "\n")
    else:
      var x = 0
      var w = 0
      var i = 0
      var s = ""
      for f in line.formats:
        let si = i
        while x < f.pos:
          var r: Rune
          fastRuneAt(line.str, i, r)
          x += r.width()
        let outstr = line.str.substr(si, i - 1)
        s &= pager.term.processOutputString(outstr, w)
        s &= pager.term.processFormat(format, f.format)
      if i < line.str.len:
        s &= pager.term.processOutputString(line.str.substr(i), w)
      s &= pager.term.processFormat(format, Format()) & "\n"
      ofile.write(s))
  ofile.flushFile()

proc redraw(pager: Pager) {.jsfunc.} =
  pager.redraw = true
  pager.term.clearCanvas()

proc draw*(pager: Pager) =
  let container = pager.container
  pager.term.hideCursor()
  if container != nil:
    if pager.redraw:
      pager.refreshDisplay()
      pager.term.writeGrid(pager.display)
    if container.select.open and container.select.redraw:
      container.select.drawSelect(pager.display)
      pager.term.writeGrid(pager.display)
  if pager.askpromise != nil or pager.askcharpromise != nil:
    discard
  elif pager.lineedit.isSome:
    if pager.lineedit.get.invalid:
      let x = pager.lineedit.get.generateOutput()
      pager.term.writeGrid(x, 0, pager.attrs.height - 1)
  else:
    pager.term.writeGrid(pager.statusgrid, 0, pager.attrs.height - 1)
  pager.term.outputGrid()
  if container != nil and pager.redraw:
    pager.term.clearImages()
    for image in container.images:
      pager.term.outputImage(image.bmp, image.x - container.fromx,
        image.y - container.fromy, pager.attrs.width, pager.attrs.height - 1)
  if pager.askpromise != nil:
    pager.term.setCursor(pager.askcursor, pager.attrs.height - 1)
  elif pager.lineedit.isSome:
    pager.term.setCursor(pager.lineedit.get.getCursorX(),
      pager.attrs.height - 1)
  elif container != nil:
    if container.select.open:
      pager.term.setCursor(container.select.getCursorX(),
        container.select.getCursorY())
    else:
      pager.term.setCursor(pager.container.acursorx, pager.container.acursory)
  pager.term.showCursor()
  pager.term.flush()
  pager.redraw = false

proc writeAskPrompt(pager: Pager; s = "") =
  let maxwidth = pager.statusgrid.width - s.len
  let i = pager.writeStatusMessage(pager.askprompt, maxwidth = maxwidth)
  pager.askcursor = pager.writeStatusMessage(s, start = i)
  pager.term.writeGrid(pager.statusgrid, 0, pager.attrs.height - 1)

proc ask(pager: Pager; prompt: string): Promise[bool] {.jsfunc.} =
  pager.askprompt = prompt
  pager.writeAskPrompt(" (y/n)")
  pager.askpromise = Promise[bool]()
  return pager.askpromise

proc askChar(pager: Pager; prompt: string): Promise[string] {.jsfunc.} =
  pager.askprompt = prompt
  pager.writeAskPrompt()
  pager.askcharpromise = Promise[string]()
  return pager.askcharpromise

proc fulfillAsk*(pager: Pager; y: bool) =
  pager.askpromise.resolve(y)
  pager.askpromise = nil
  pager.askprompt = ""

proc fulfillCharAsk*(pager: Pager; s: string) =
  pager.askcharpromise.resolve(s)
  pager.askcharpromise = nil
  pager.askprompt = ""

proc addContainer*(pager: Pager; container: Container) =
  container.parent = pager.container
  if pager.container != nil:
    pager.container.children.insert(container, 0)
  pager.setContainer(container)

proc onSetLoadInfo(pager: Pager; container: Container) =
  if pager.alertState != pasAlertOn:
    if container.loadinfo == "":
      pager.alertState = pasNormal
    else:
      pager.writeStatusMessage(container.loadinfo)
      pager.alertState = pasLoadInfo

proc newContainer(pager: Pager; bufferConfig: BufferConfig;
    loaderConfig: LoaderClientConfig; request: Request; title = "";
    redirectDepth = 0; flags = {cfCanReinterpret, cfUserRequested};
    contentType = none(string); charsetStack: seq[Charset] = @[];
    url = request.url; cacheId = -1; cacheFile = ""): Container =
  request.suspended = true
  let stream = pager.loader.startRequest(request, loaderConfig)
  pager.loader.registerFun(stream.fd)
  let container = newContainer(
    bufferConfig,
    loaderConfig,
    url,
    request,
    pager.luctx,
    pager.term.attrs,
    title,
    redirectDepth,
    flags,
    contentType,
    charsetStack,
    cacheId,
    cacheFile,
    pager.config
  )
  pager.connectingContainers.add(ConnectingContainerItem(
    state: ccsBeforeResult,
    container: container,
    stream: stream
  ))
  pager.onSetLoadInfo(container)
  return container

proc newContainerFrom(pager: Pager; container: Container; contentType: string):
    Container =
  let url = newURL("cache:" & $container.cacheId).get
  return pager.newContainer(
    container.config,
    container.loaderConfig,
    newRequest(url),
    contentType = some(contentType),
    charsetStack = container.charsetStack,
    url = container.url,
    cacheId = container.cacheId,
    cacheFile = container.cacheFile
  )

func findConnectingContainer*(pager: Pager; fd: int): int =
  for i, item in pager.connectingContainers:
    if item.stream.fd == fd:
      return i
  -1

func findConnectingContainer*(pager: Pager; container: Container): int =
  for i, item in pager.connectingContainers:
    if item.container == container:
      return i
  -1

func findProcMapItem*(pager: Pager; pid: int): int =
  for i, item in pager.procmap:
    if item.container.process == pid:
      return i
  -1

proc dupeBuffer(pager: Pager; container: Container; url: URL) =
  container.clone(url, pager.loader).then(proc(container: Container) =
    if container == nil:
      pager.alert("Failed to duplicate buffer.")
    else:
      pager.addContainer(container)
      pager.procmap.add(ProcMapItem(
        container: container,
        fdin: -1,
        fdout: -1,
        istreamOutputId: -1,
        ostreamOutputId: -1
      ))
  )

proc dupeBuffer(pager: Pager) {.jsfunc.} =
  pager.dupeBuffer(pager.container, pager.container.url)

func findPrev(container: Container): Container =
  if container.parent == nil:
    return nil
  let n = container.parent.children.find(container)
  assert n != -1, "Container not a child of its parent"
  if n == 0:
    return container.parent
  var container = container.parent.children[n - 1]
  while container.children.len > 0:
    container = container.children[^1]
  return container

func findNext(container: Container): Container =
  if container.children.len > 0:
    return container.children[0]
  var container = container
  while container.parent != nil:
    let n = container.parent.children.find(container)
    assert n != -1, "Container not a child of its parent"
    if n < container.parent.children.high:
      return container.parent.children[n + 1]
    container = container.parent
  return nil

func findPrevSibling(container: Container): Container =
  if container.parent == nil:
    return nil
  var n = container.parent.children.find(container)
  assert n != -1, "Container not a child of its parent"
  if n == 0:
    n = container.parent.children.len
  return container.parent.children[n - 1]

func findNextSibling(container: Container): Container =
  if container.parent == nil:
    return nil
  var n = container.parent.children.find(container)
  assert n != -1, "Container not a child of its parent"
  if n == container.parent.children.high:
    n = -1
  return container.parent.children[n + 1]

func findParent(container: Container): Container =
  return container.parent

func findFirstChild(container: Container): Container =
  if container.children.len == 0:
    return nil
  return container.children[0]

func findAny(container: Container): Container =
  let prev = container.findPrev()
  if prev != nil:
    return prev
  return container.findNext()

func opposite(dir: NavDirection): NavDirection =
  const Map = [
    ndPrev: ndNext,
    ndNext: ndPrev,
    ndPrevSibling: ndNextSibling,
    ndNextSibling: ndPrevSibling,
    ndParent: ndFirstChild,
    ndFirstChild: ndParent,
    ndAny: ndAny
  ]
  return Map[dir]

func find(container: Container; dir: NavDirection): Container =
  return case dir
  of ndPrev: container.findPrev()
  of ndNext: container.findNext()
  of ndPrevSibling: container.findPrevSibling()
  of ndNextSibling: container.findNextSibling()
  of ndParent: container.findParent()
  of ndFirstChild: container.findFirstChild()
  of ndAny: container.findAny()

# The prevBuffer and nextBuffer procedures emulate w3m's PREV and NEXT
# commands by traversing the container tree in a depth-first order.
proc prevBuffer*(pager: Pager): bool {.jsfunc.} =
  pager.navDirection = ndPrev
  if pager.container == nil:
    return false
  let prev = pager.container.findPrev()
  if prev == nil:
    return false
  pager.setContainer(prev)
  return true

proc nextBuffer*(pager: Pager): bool {.jsfunc.} =
  pager.navDirection = ndNext
  if pager.container == nil:
    return false
  let next = pager.container.findNext()
  if next == nil:
    return false
  pager.setContainer(next)
  return true

proc parentBuffer(pager: Pager): bool {.jsfunc.} =
  pager.navDirection = ndParent
  if pager.container == nil:
    return false
  let parent = pager.container.findParent()
  if parent == nil:
    return false
  pager.setContainer(parent)
  return true

proc prevSiblingBuffer(pager: Pager): bool {.jsfunc.} =
  pager.navDirection = ndPrevSibling
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  var n = pager.container.parent.children.find(pager.container)
  assert n != -1, "Container not a child of its parent"
  if n == 0:
    n = pager.container.parent.children.len
  pager.setContainer(pager.container.parent.children[n - 1])
  return true

proc nextSiblingBuffer(pager: Pager): bool {.jsfunc.} =
  pager.navDirection = ndNextSibling
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  var n = pager.container.parent.children.find(pager.container)
  assert n != -1, "Container not a child of its parent"
  if n == pager.container.parent.children.high:
    n = -1
  pager.setContainer(pager.container.parent.children[n + 1])
  return true

proc alert*(pager: Pager; msg: string) {.jsfunc.} =
  pager.alerts.add(msg)

# replace target with container in the tree
proc replace*(pager: Pager; target, container: Container) =
  let n = target.children.find(container)
  if n != -1:
    target.children.delete(n)
    container.parent = nil
  let n2 = container.children.find(target)
  if n2 != -1:
    container.children.delete(n2)
    target.parent = nil
  container.children.add(target.children)
  for child in container.children:
    child.parent = container
  target.children.setLen(0)
  if target.parent != nil:
    container.parent = target.parent
    let n = target.parent.children.find(target)
    assert n != -1, "Container not a child of its parent"
    container.parent.children[n] = container
    target.parent = nil
  if pager.container == target:
    pager.setContainer(container)

proc deleteContainer(pager: Pager; container, setTarget: Container) =
  if container.loadState == lsLoading:
    container.cancel()
  if container.sourcepair != nil:
    container.sourcepair.sourcepair = nil
    container.sourcepair = nil
  if container.parent != nil:
    let parent = container.parent
    let n = parent.children.find(container)
    assert n != -1, "Container not a child of its parent"
    for i in countdown(container.children.high, 0):
      let child = container.children[i]
      child.parent = container.parent
      parent.children.insert(child, n + 1)
    parent.children.delete(n)
  elif container.children.len > 0:
    let parent = container.children[0]
    parent.parent = nil
    for i in 1..container.children.high:
      container.children[i].parent = parent
      parent.children.add(container.children[i])
  container.parent = nil
  container.children.setLen(0)
  if container.replace != nil:
    pager.replace(container, container.replace)
    container.replace = nil
  elif pager.container == container:
    pager.setContainer(setTarget)
  pager.unreg.add(container)
  if container.process != -1:
    pager.forkserver.removeChild(container.process)
    pager.loader.removeClient(container.process)

proc discardBuffer*(pager: Pager; container = none(Container);
    dir = none(NavDirection)) {.jsfunc.} =
  if dir.isSome:
    pager.navDirection = dir.get.opposite()
  let container = container.get(pager.container)
  let dir = pager.navDirection.opposite()
  let setTarget = container.find(dir)
  if container == nil or setTarget == nil:
    pager.alert("No buffer in direction: " & $dir)
  else:
    pager.deleteContainer(container, setTarget)

proc discardTree(pager: Pager; container = none(Container)) {.jsfunc.} =
  let container = container.get(pager.container)
  if container != nil:
    for c in container.descendants:
      pager.deleteContainer(container, nil)
  else:
    pager.alert("Buffer has no children!")

proc c_system(cmd: cstring): cint {.importc: "system", header: "<stdlib.h>".}

# Run process (without suspending the terminal controller).
proc runProcess(cmd: string): bool =
  let wstatus = c_system(cstring(cmd))
  if wstatus == -1:
    result = false
  else:
    result = WIFEXITED(wstatus) and WEXITSTATUS(wstatus) == 0
    if not result:
      # Hack.
      #TODO this is a very bad idea, e.g. say the editor is writing into the
      # file, then receives SIGINT, now the file is corrupted but Chawan will
      # happily read it as if nothing happened.
      # We should find a proper solution for this.
      result = WIFSIGNALED(wstatus) and WTERMSIG(wstatus) == SIGINT

# Run process (and suspend the terminal controller).
proc runProcess(term: Terminal; cmd: string; wait = false): bool =
  term.quit()
  result = runProcess(cmd)
  if wait:
    term.anyKey()
  term.restart()

# Run process, and capture its output.
proc runProcessCapture(cmd: string; outs: var string): bool =
  let file = popen(cmd, "r")
  if file == nil:
    return false
  outs = file.readAll()
  let rv = pclose(file)
  if rv == -1:
    return false
  return rv == 0

# Run process, and write an arbitrary string into its standard input.
proc runProcessInto(cmd, ins: string): bool =
  let file = popen(cmd, "w")
  if file == nil:
    return false
  file.write(ins)
  let rv = pclose(file)
  if rv == -1:
    return false
  return rv == 0

template myExec(cmd: string) =
  discard execl("/bin/sh", "sh", "-c", cstring(cmd), nil)
  exitnow(127)

proc toggleSource(pager: Pager) {.jsfunc.} =
  if cfCanReinterpret notin pager.container.flags:
    return
  if pager.container.sourcepair != nil:
    pager.setContainer(pager.container.sourcepair)
  else:
    let ishtml = cfIsHTML notin pager.container.flags
    #TODO I wish I could set the contentType to whatever I wanted, not just HTML
    let contentType = if ishtml:
      "text/html"
    else:
      "text/plain"
    let container = pager.newContainerFrom(pager.container, contentType)
    if container != nil:
      container.sourcepair = pager.container
      pager.container.sourcepair = container
      pager.addContainer(container)

proc getEditorCommand(pager: Pager; file: string; line = 1): string {.jsfunc.} =
  var editor = pager.config.external.editor
  if (let uqEditor = ChaPath(editor).unquote(); uqEditor.isSome):
    if uqEditor.get in ["vi", "nvi", "vim", "nvim"]:
      editor = uqEditor.get & " +%d"
  var canpipe = true
  var s = unquoteCommand(editor, "", file, nil, canpipe, line)
  if canpipe:
    # %s not in command; add file name ourselves
    if s[^1] != ' ':
      s &= ' '
    s &= quoteFile(file, qsNormal)
  return s

proc openInEditor(pager: Pager; input: var string): bool =
  try:
    let tmpf = getTempFile(pager.config.external.tmpdir)
    if input != "":
      writeFile(tmpf, input)
    let cmd = pager.getEditorCommand(tmpf)
    if pager.term.runProcess(cmd):
      if fileExists(tmpf):
        input = readFile(tmpf)
        removeFile(tmpf)
        return true
  except IOError:
    discard
  return false

proc windowChange*(pager: Pager) =
  let oldAttrs = pager.attrs
  pager.term.windowChange()
  if pager.attrs == oldAttrs:
    #TODO maybe it's more efficient to let false positives through?
    return
  if pager.lineedit.isSome:
    pager.lineedit.get.windowChange(pager.attrs)
  pager.display = newFixedGrid(pager.attrs.width, pager.attrs.height - 1)
  pager.statusgrid = newFixedGrid(pager.attrs.width)
  for container in pager.containers:
    container.windowChange(pager.attrs)
  if pager.askprompt != "":
    pager.writeAskPrompt()
  pager.showAlerts()

# Apply siteconf settings to a request.
# Note that this may modify the URL passed.
proc applySiteconf(pager: Pager; url: var URL; charsetOverride: Charset;
    loaderConfig: var LoaderClientConfig): BufferConfig =
  let host = url.host
  let ctx = pager.jsctx
  var res = BufferConfig(
    userstyle: pager.config.css.stylesheet,
    referer_from: false,
    scripting: false,
    charsets: pager.config.encoding.document_charset,
    images: false,
    isdump: pager.config.start.headless,
    charsetOverride: charsetOverride,
    protocol: pager.config.protocol
  )
  loaderConfig = LoaderClientConfig(
    defaultHeaders: newHeaders(pager.config.network.default_headers),
    cookiejar: nil,
    proxy: pager.config.network.proxy,
    filter: newURLFilter(
      scheme = some(url.scheme),
      allowschemes = @["data", "cache"],
      default = true
    ),
    insecureSSLNoVerify: false
  )
  for sc in pager.config.siteconf:
    if sc.url.isSome and not sc.url.get.match($url):
      continue
    elif sc.host.isSome and not sc.host.get.match(host):
      continue
    if sc.rewrite_url.isSome:
      let fun = sc.rewrite_url.get
      var arg0 = ctx.toJS(url)
      let ret = JS_Call(ctx, fun, JS_UNDEFINED, 1, arg0.toJSValueArray())
      let nu = fromJS[URL](ctx, ret)
      if nu.isSome:
        if nu.get != nil:
          url = nu.get
      elif JS_IsException(ret):
        #TODO should writeException the message to console
        pager.alert("Error rewriting URL: " & ctx.getExceptionMsg(nu.error))
      JS_FreeValue(ctx, arg0)
      JS_FreeValue(ctx, ret)
    if sc.cookie.isSome:
      if sc.cookie.get:
        # host/url might have changed by now
        let jarid = sc.share_cookie_jar.get(url.host)
        if jarid notin pager.cookiejars:
          pager.cookiejars[jarid] = newCookieJar(url,
            sc.third_party_cookie)
        loaderConfig.cookieJar = pager.cookiejars[jarid]
      else:
        loaderConfig.cookieJar = nil # override
    if sc.scripting.isSome:
      res.scripting = sc.scripting.get
    if sc.referer_from.isSome:
      res.referer_from = sc.referer_from.get
    if sc.document_charset.len > 0:
      res.charsets = sc.document_charset
    if sc.images.isSome:
      res.images = sc.images.get
    if sc.stylesheet.isSome:
      res.userstyle &= "\n"
      res.userstyle &= sc.stylesheet.get
    if sc.proxy.isSome:
      loaderConfig.proxy = sc.proxy.get
    if sc.default_headers != nil:
      loaderConfig.defaultHeaders = newHeaders(sc.default_headers[])
    if sc.insecure_ssl_no_verify.isSome:
      loaderConfig.insecureSSLNoVerify = sc.insecure_ssl_no_verify.get
    if sc.autofocus.isSome:
      res.autofocus = sc.autofocus.get
  return res

# Load request in a new buffer.
proc gotoURL(pager: Pager; request: Request; prevurl = none(URL);
    contentType = none(string); cs = CHARSET_UNKNOWN; replace: Container = nil;
    redirectDepth = 0; referrer: Container = nil; save = false;
    url: URL = nil) =
  pager.navDirection = ndNext
  if referrer != nil and referrer.config.referer_from:
    request.referrer = referrer.url
  let url = if url != nil: url else: request.url
  var loaderConfig: LoaderClientConfig
  var bufferConfig = pager.applySiteconf(request.url, cs, loaderConfig)
  if prevurl.isNone or not prevurl.get.equals(request.url, true) or
      request.url.hash == "" or request.httpMethod != hmGet:
    # Basically, we want to reload the page *only* when
    # a) we force a reload (by setting prevurl to none)
    # b) or the new URL isn't just the old URL + an anchor
    # I think this makes navigation pretty natural, or at least very close to
    # what other browsers do. Still, it would be nice if we got some visual
    # feedback on what is actually going to happen when typing a URL; TODO.
    if referrer != nil:
      loaderConfig.referrerPolicy = referrer.loaderConfig.referrerPolicy
    var flags = {cfCanReinterpret, cfUserRequested}
    if save:
      flags.incl(cfSave)
    let container = pager.newContainer(
      bufferConfig,
      loaderConfig,
      request,
      redirectDepth = redirectDepth,
      contentType = contentType,
      flags = flags,
      url = url
    )
    if replace != nil:
      pager.replace(replace, container)
      container.replace = replace
      container.copyCursorPos(replace)
    else:
      pager.addContainer(container)
    inc pager.numload
  else:
    pager.container.findAnchor(request.url.anchor)

proc omniRewrite(pager: Pager; s: string): string =
  for rule in pager.config.omnirule:
    if rule.match.match(s):
      let fun = rule.substitute_url.get
      let ctx = pager.jsctx
      var arg0 = ctx.toJS(s)
      let jsRet = JS_Call(ctx, fun, JS_UNDEFINED, 1, arg0.toJSValueArray())
      let ret = fromJS[string](ctx, jsRet)
      JS_FreeValue(ctx, jsRet)
      JS_FreeValue(ctx, arg0)
      if ret.isSome:
        return ret.get
      pager.alert("Error in substitution of " & $rule.match & " for " & s &
        ": " & ctx.getExceptionMsg(ret.error))
  return s

# When the user has passed a partial URL as an argument, they might've meant
# either:
# * file://$PWD/<file>
# * https://<url>
# So we attempt to load both, and see what works.
proc loadURL*(pager: Pager; url: string; ctype = none(string);
    cs = CHARSET_UNKNOWN) =
  let url0 = pager.omniRewrite(url)
  let url = if url[0] == '~': expandPath(url0) else: url0
  let firstparse = parseURL(url)
  if firstparse.isSome:
    let prev = if pager.container != nil:
      some(pager.container.url)
    else:
      none(URL)
    pager.gotoURL(newRequest(firstparse.get), prev, ctype, cs)
    return
  var urls: seq[URL]
  if pager.config.network.prepend_https and
      pager.config.network.prepend_scheme != "" and url[0] != '/':
    let pageurl = parseURL(pager.config.network.prepend_scheme & url)
    if pageurl.isSome: # attempt to load remote page
      urls.add(pageurl.get)
  let cdir = parseURL("file://" & percentEncode(getCurrentDir(),
    LocalPathPercentEncodeSet) & DirSep)
  let localurl = percentEncode(url, LocalPathPercentEncodeSet)
  let newurl = parseURL(localurl, cdir)
  if newurl.isSome:
    urls.add(newurl.get) # attempt to load local file
  if urls.len == 0:
    pager.alert("Invalid URL " & url)
  else:
    let prevc = pager.container
    pager.gotoURL(newRequest(urls.pop()), contentType = ctype, cs = cs)
    if pager.container != prevc:
      pager.container.retry = urls

proc readPipe0*(pager: Pager; contentType: string; cs: Charset;
    fd: FileHandle; url: URL; title: string; flags: set[ContainerFlag]):
    Container =
  var url = url
  pager.loader.passFd(url.pathname, fd)
  safeClose(fd)
  var loaderConfig: LoaderClientConfig
  let bufferConfig = pager.applySiteconf(url, cs, loaderConfig)
  return pager.newContainer(
    bufferConfig,
    loaderConfig,
    newRequest(url),
    title = title,
    flags = flags,
    contentType = some(contentType)
  )

proc readPipe*(pager: Pager; contentType: string; cs: Charset; fd: FileHandle;
    title: string) =
  let url = newURL("stream:-").get
  let container = pager.readPipe0(contentType, cs, fd, url, title,
    {cfCanReinterpret, cfUserRequested})
  inc pager.numload
  pager.addContainer(container)

proc command(pager: Pager) {.jsfunc.} =
  pager.setLineEdit(lmCommand)

proc commandMode(pager: Pager; val: bool) {.jsfset.} =
  pager.commandMode = val
  if val:
    pager.command()

proc checkRegex(pager: Pager; regex: Result[Regex, string]): Opt[Regex] =
  if regex.isNone:
    pager.alert("Invalid regex: " & regex.error)
    return err()
  return ok(regex.get)

proc compileSearchRegex(pager: Pager; s: string): Result[Regex, string] =
  var flags = {LRE_FLAG_UNICODE}
  if pager.config.search.ignore_case:
    flags.incl(LRE_FLAG_IGNORECASE)
  return compileSearchRegex(s, flags)

proc updateReadLineISearch(pager: Pager; linemode: LineMode) =
  let lineedit = pager.lineedit.get
  pager.isearchpromise = pager.isearchpromise.then(proc(): EmptyPromise =
    case lineedit.state
    of lesCancel:
      pager.iregex.err()
      pager.container.popCursorPos()
      pager.container.clearSearchHighlights()
      pager.redraw = true
      pager.isearchpromise = nil
    of lesEdit:
      if lineedit.news != "":
        pager.iregex = pager.compileSearchRegex(lineedit.news)
      pager.container.popCursorPos(true)
      pager.container.pushCursorPos()
      if pager.iregex.isSome:
        pager.container.hlon = true
        let wrap = pager.config.search.wrap
        return if linemode == lmISearchF:
          pager.container.cursorNextMatch(pager.iregex.get, wrap, false, 1)
        else:
          pager.container.cursorPrevMatch(pager.iregex.get, wrap, false, 1)
    of lesFinish:
      if lineedit.news != "":
        pager.regex = pager.checkRegex(pager.iregex)
      else:
        pager.searchNext()
      pager.reverseSearch = linemode == lmISearchB
      pager.container.markPos()
      pager.container.clearSearchHighlights()
      pager.container.sendCursorPosition()
      pager.redraw = true
      pager.isearchpromise = nil
  )

proc saveTo(pager: Pager; data: LineDataDownload; path: string) =
  if pager.loader.redirectToFile(data.outputId, path):
    pager.alert("Saving file to " & path)
    pager.loader.resume(@[data.outputId])
    data.stream.sclose()
    pager.lineData = nil
  else:
    pager.ask("Failed to save to " & path & ". Retry?").then(
      proc(x: bool) =
        if x:
          pager.setLineEdit(lmDownload, path)
        else:
          data.stream.sclose()
          pager.lineData = nil
    )

proc updateReadLine*(pager: Pager) =
  let lineedit = pager.lineedit.get
  if pager.linemode in {lmISearchF, lmISearchB}:
    pager.updateReadLineISearch(pager.linemode)
  else:
    case lineedit.state
    of lesEdit: discard
    of lesFinish:
      case pager.linemode
      of lmLocation: pager.loadURL(lineedit.news)
      of lmUsername:
        LineDataAuth(pager.lineData).url.username = lineedit.news
        pager.setLineEdit(lmPassword, hide = true)
      of lmPassword:
        let url = LineDataAuth(pager.lineData).url
        url.password = lineedit.news
        pager.gotoURL(newRequest(url), some(pager.container.url),
          replace = pager.container, referrer = pager.container)
        pager.lineData = nil
      of lmCommand:
        pager.scommand = lineedit.news
        if pager.commandMode:
          pager.command()
      of lmBuffer: pager.container.readSuccess(lineedit.news)
      of lmBufferFile:
        let ps = newPosixStream(lineedit.news, O_RDONLY, 0)
        if ps == nil:
          pager.alert("File not found")
          pager.container.readCanceled()
        else:
          var stats: Stat
          if fstat(ps.fd, stats) < 0 or S_ISDIR(stats.st_mode):
            pager.alert("Not a file: " & lineedit.news)
          else:
            let name = lineedit.news.afterLast('/')
            pager.container.readSuccess(name, ps.fd)
          ps.sclose()
      of lmSearchF, lmSearchB:
        if lineedit.news != "":
          let regex = pager.compileSearchRegex(lineedit.news)
          pager.regex = pager.checkRegex(regex)
        pager.reverseSearch = pager.linemode == lmSearchB
        pager.searchNext()
      of lmGotoLine:
        pager.container.gotoLine(lineedit.news)
      of lmDownload:
        let data = LineDataDownload(pager.lineData)
        if fileExists(lineedit.news):
          pager.ask("Override file " & lineedit.news & "?").then(
            proc(x: bool) =
              if x:
                pager.saveTo(data, lineedit.news)
              else:
                pager.setLineEdit(lmDownload, lineedit.news)
          )
        else:
          pager.saveTo(data, lineedit.news)
      of lmISearchF, lmISearchB: discard
    of lesCancel:
      case pager.linemode
      of lmUsername, lmPassword: pager.discardBuffer()
      of lmBuffer: pager.container.readCanceled()
      of lmCommand: pager.commandMode = false
      of lmDownload:
        let data = LineDataDownload(pager.lineData)
        data.stream.sclose()
      else: discard
      pager.lineData = nil
  if lineedit.state in {lesCancel, lesFinish} and
      pager.lineedit.get == lineedit:
    pager.clearLineEdit()

# Same as load(s + '\n')
proc loadSubmit(pager: Pager; s: string) {.jsfunc.} =
  pager.loadURL(s)

# Open a URL prompt and visit the specified URL.
proc load(pager: Pager; s = "") {.jsfunc.} =
  if s.len > 0 and s[^1] == '\n':
    if s.len > 1:
      pager.loadURL(s[0..^2])
  elif s == "":
    pager.setLineEdit(lmLocation, $pager.container.url)
  else:
    pager.setLineEdit(lmLocation, s)

# Go to specific URL (for JS)
proc jsGotoURL(pager: Pager; v: JSValue): JSResult[void] {.jsfunc: "gotoURL".} =
  let req = fromJS[JSRequest](pager.jsctx, v)
  if req.isSome:
    pager.gotoURL(req.get.request)
  else:
    let s = ?fromJS[string](pager.jsctx, v)
    pager.gotoURL(newRequest(?newURL(s)))
  ok()

# Reload the page in a new buffer, then kill the previous buffer.
proc reload(pager: Pager) {.jsfunc.} =
  pager.gotoURL(newRequest(pager.container.url), none(URL),
    pager.container.contentType, replace = pager.container)

proc setEnvVars(pager: Pager) {.jsfunc.} =
  try:
    putEnv("CHA_URL", $pager.container.url)
    putEnv("CHA_CHARSET", $pager.container.charset)
  except OSError:
    pager.alert("Warning: failed to set some environment variables")

#TODO use default values instead...
type ExternDict = object of JSDict
  setenv: Option[bool]
  suspend: Option[bool]
  wait: bool

#TODO we should have versions with retval as int?
proc extern(pager: Pager; cmd: string; t = ExternDict()): bool {.jsfunc.} =
  if t.setenv.get(true):
    pager.setEnvVars()
  if t.suspend.get(true):
    return runProcess(pager.term, cmd, t.wait)
  else:
    return runProcess(cmd)

proc externCapture(pager: Pager; cmd: string): Opt[string] {.jsfunc.} =
  pager.setEnvVars()
  var s: string
  if not runProcessCapture(cmd, s):
    return err()
  return ok(s)

proc externInto(pager: Pager; cmd, ins: string): bool {.jsfunc.} =
  pager.setEnvVars()
  return runProcessInto(cmd, ins)

proc externFilterSource(pager: Pager; cmd: string; c: Container = nil;
    contentType = none(string)) {.jsfunc.} =
  let fromc = if c != nil: c else: pager.container
  let fallback = pager.container.contentType.get("text/plain")
  let contentType = contentType.get(fallback)
  let container = pager.newContainerFrom(fromc, contentType)
  if contentType == "text/html":
    container.flags.incl(cfIsHTML)
  else:
    container.flags.excl(cfIsHTML)
  pager.addContainer(container)
  container.filter = BufferFilter(cmd: cmd)

type CheckMailcapResult = object
  fdout: int
  ostreamOutputId: int
  connect: bool
  ishtml: bool
  found: bool

template myFork(): cint =
  stdout.flushFile()
  stderr.flushFile()
  fork()

# Pipe output of an x-ansioutput mailcap command to the text/x-ansi handler.
proc ansiDecode(pager: Pager; url: URL; ishtml: var bool; fdin: cint): cint =
  let entry = pager.config.external.mailcap.getMailcapEntry("text/x-ansi", "",
    url)
  var canpipe = true
  let cmd = unquoteCommand(entry.cmd, "text/x-ansi", "", url, canpipe)
  if not canpipe:
    pager.alert("Error: could not pipe to text/x-ansi, decoding as text/plain")
    return -1
  var pipefdOutAnsi: array[2, cint]
  if pipe(pipefdOutAnsi) == -1:
    pager.alert("Error: failed to open pipe")
    return
  case myFork()
  of -1:
    pager.alert("Error: failed to fork ANSI decoder process")
    discard close(pipefdOutAnsi[0])
    discard close(pipefdOutAnsi[1])
    return -1
  of 0: # child process
    discard close(pipefdOutAnsi[0])
    discard dup2(fdin, stdin.getFileHandle())
    discard close(fdin)
    discard dup2(pipefdOutAnsi[1], stdout.getFileHandle())
    discard close(pipefdOutAnsi[1])
    closeStderr()
    myExec(cmd)
  else:
    discard close(pipefdOutAnsi[1])
    discard close(fdin)
    ishtml = HTMLOUTPUT in entry.flags
    return pipefdOutAnsi[0]

# Pipe input into the mailcap command, then read its output into a buffer.
# needsterminal is ignored.
proc runMailcapReadPipe(pager: Pager; stream: SocketStream; cmd: string;
    pipefdOut: array[2, cint]): int =
  let pid = myFork()
  if pid == -1:
    pager.alert("Error: failed to fork mailcap read process")
    return -1
  elif pid == 0:
    # child process
    discard close(pipefdOut[0])
    discard dup2(stream.fd, stdin.getFileHandle())
    stream.sclose()
    discard dup2(pipefdOut[1], stdout.getFileHandle())
    closeStderr()
    discard close(pipefdOut[1])
    myExec(cmd)
  # parent
  pid

# Pipe input into the mailcap command, and discard its output.
# If needsterminal, leave stderr and stdout open and wait for the process.
proc runMailcapWritePipe(pager: Pager; stream: SocketStream;
    needsterminal: bool; cmd: string) =
  if needsterminal:
    pager.term.quit()
  let pid = myFork()
  if pid == -1:
    pager.alert("Error: failed to fork mailcap write process")
  elif pid == 0:
    # child process
    discard dup2(stream.fd, stdin.getFileHandle())
    stream.sclose()
    if not needsterminal:
      closeStdout()
      closeStderr()
    myExec(cmd)
  else:
    # parent
    stream.sclose()
    if needsterminal:
      var x: cint
      discard waitpid(pid, x, 0)
      pager.term.restart()

proc writeToFile(istream: SocketStream; outpath: string): bool =
  let ps = newPosixStream(outpath, O_WRONLY or O_CREAT, 0o600)
  if ps == nil:
    return false
  var buffer: array[4096, uint8]
  while true:
    let n = istream.recvData(buffer)
    if n == 0:
      break
    ps.sendDataLoop(buffer.toOpenArray(0, n - 1))
  ps.sclose()
  true

# Save input in a file, run the command, and redirect its output to a
# new buffer.
# needsterminal is ignored.
proc runMailcapReadFile(pager: Pager; stream: SocketStream;
    cmd, outpath: string; pipefdOut: array[2, cint]): int =
  let pid = myFork()
  if pid == 0:
    # child process
    discard close(pipefdOut[0])
    discard dup2(pipefdOut[1], stdout.getFileHandle())
    discard close(pipefdOut[1])
    closeStderr()
    if not stream.writeToFile(outpath):
      #TODO print error message
      quit(1)
    stream.sclose()
    let ret = execCmd(cmd)
    discard tryRemoveFile(outpath)
    quit(ret)
  # parent
  pid

# Save input in a file, run the command, and discard its output.
# If needsterminal, leave stderr and stdout open and wait for the process.
proc runMailcapWriteFile(pager: Pager; stream: SocketStream;
    needsterminal: bool; cmd, outpath: string) =
  if needsterminal:
    pager.term.quit()
    if not stream.writeToFile(outpath):
      pager.term.restart()
      pager.alert("Error: failed to write file for mailcap process")
    else:
      discard execCmd(cmd)
      discard tryRemoveFile(outpath)
      pager.term.restart()
  else:
    # don't block
    let pid = myFork()
    if pid == 0:
      # child process
      closeStdin()
      closeStdout()
      closeStderr()
      if not stream.writeToFile(outpath):
        #TODO print error message (maybe in parent?)
        quit(1)
      stream.sclose()
      let ret = execCmd(cmd)
      discard tryRemoveFile(outpath)
      quit(ret)
    # parent
    stream.sclose()

proc filterBuffer(pager: Pager; stream: SocketStream; cmd: string;
    ishtml: bool): CheckMailcapResult =
  pager.setEnvVars()
  var pipefd_out: array[2, cint]
  if pipe(pipefd_out) == -1:
    pager.alert("Error: failed to open pipe")
    return CheckMailcapResult(connect: false, fdout: -1)
  let pid = myFork()
  if pid == -1:
    pager.alert("Error: failed to fork buffer filter process")
    return CheckMailcapResult(connect: false, fdout: -1)
  elif pid == 0:
    # child
    discard close(pipefd_out[0])
    discard dup2(stream.fd, stdin.getFileHandle())
    stream.sclose()
    discard dup2(pipefd_out[1], stdout.getFileHandle())
    closeStderr()
    discard close(pipefd_out[1])
    myExec(cmd)
  # parent
  discard close(pipefd_out[1])
  let fdout = pipefd_out[0]
  let url = parseURL("stream:" & $pid).get
  pager.loader.passFd(url.pathname, FileHandle(fdout))
  safeClose(fdout)
  let response = pager.loader.doRequest(newRequest(url, suspended = true))
  return CheckMailcapResult(
    connect: true,
    fdout: response.body.fd,
    ostreamOutputId: response.outputId,
    ishtml: ishtml,
    found: true
  )

# Search for a mailcap entry, and if found, execute the specified command
# and pipeline the input and output appropriately.
# There are four possible outcomes:
# * pipe stdin, discard stdout
# * pipe stdin, read stdout
# * write to file, run, discard stdout
# * write to file, run, read stdout
# If needsterminal is specified, and stdout is not being read, then the
# pager is suspended until the command exits.
#TODO add support for edit/compose, better error handling
proc checkMailcap(pager: Pager; container: Container; stream: SocketStream;
    istreamOutputId: int; contentType: string): CheckMailcapResult =
  if container.filter != nil:
    return pager.filterBuffer(
      stream,
      container.filter.cmd,
      cfIsHTML in container.flags
    )
  # contentType must exist, because we set it in applyResponse
  let shortContentType = container.contentType.get
  if shortContentType == "text/html":
    # We support text/html natively, so it would make little sense to execute
    # mailcap filters for it.
    return CheckMailcapResult(
      connect: true,
      fdout: stream.fd,
      ishtml: true,
      found: true
    )
  if shortContentType == "text/plain":
    # text/plain could potentially be useful. Unfortunately, many mailcaps
    # include a text/plain entry with less by default, so it's probably better
    # to ignore this.
    return CheckMailcapResult(connect: true, fdout: stream.fd, found: true)
  #TODO callback for outpath or something
  let url = container.url
  let entry = pager.config.external.mailcap.getMailcapEntry(contentType, "",
    url)
  if entry == nil:
    return CheckMailcapResult(connect: true, fdout: stream.fd, found: false)
  let ext = url.pathname.afterLast('.')
  let tempfile = getTempFile(pager.config.external.tmpdir, ext)
  let outpath = if entry.nametemplate != "":
    unquoteCommand(entry.nametemplate, contentType, tempfile, url)
  else:
    tempfile
  var canpipe = true
  let cmd = unquoteCommand(entry.cmd, contentType, outpath, url, canpipe)
  var ishtml = HTMLOUTPUT in entry.flags
  let needsterminal = NEEDSTERMINAL in entry.flags
  putEnv("MAILCAP_URL", $url)
  block needsConnect:
    if entry.flags * {COPIOUSOUTPUT, HTMLOUTPUT, ANSIOUTPUT} == {}:
      # No output. Resume here, so that blocking needsterminal filters work.
      pager.loader.resume(@[istreamOutputId])
      if canpipe:
        pager.runMailcapWritePipe(stream, needsterminal, cmd)
      else:
        pager.runMailcapWriteFile(stream, needsterminal, cmd, outpath)
      # stream is already closed
      break needsConnect # never connect here, since there's no output
    var pipefdOut: array[2, cint]
    if pipe(pipefdOut) == -1:
      pager.alert("Error: failed to open pipe")
      stream.sclose() # connect: false implies that we consumed the stream
      break needsConnect
    let pid = if canpipe:
      pager.runMailcapReadPipe(stream, cmd, pipefdOut)
    else:
      pager.runMailcapReadFile(stream, cmd, outpath, pipefdOut)
    discard close(pipefdOut[1]) # close write
    let fdout = if not ishtml and ANSIOUTPUT in entry.flags:
      pager.ansiDecode(url, ishtml, pipefdOut[0])
    else:
      pipefdOut[0]
    delEnv("MAILCAP_URL")
    let url = parseURL("stream:" & $pid).get
    pager.loader.passFd(url.pathname, FileHandle(fdout))
    safeClose(cint(fdout))
    let response = pager.loader.doRequest(newRequest(url, suspended = true))
    return CheckMailcapResult(
      connect: true,
      fdout: response.body.fd,
      ostreamOutputId: response.outputId,
      ishtml: ishtml,
      found: true
    )
  delEnv("MAILCAP_URL")
  return CheckMailcapResult(connect: false, fdout: -1, found: true)

proc redirectTo(pager: Pager; container: Container; request: Request) =
  pager.gotoURL(request, some(container.url), replace = container,
    redirectDepth = container.redirectDepth + 1, referrer = container)
  pager.container.loadinfo = "Redirecting to " & $request.url
  pager.onSetLoadInfo(pager.container)
  dec pager.numload

proc fail(pager: Pager; container: Container; errorMessage: string) =
  dec pager.numload
  pager.deleteContainer(container, container.find(ndAny))
  if container.retry.len > 0:
    pager.gotoURL(newRequest(container.retry.pop()),
      contentType = container.contentType)
  else:
    pager.alert("Can't load " & $container.url & " (" & errorMessage & ")")

proc redirect(pager: Pager; container: Container; response: Response;
    request: Request) =
  # if redirection fails, then we need some other container to move to...
  let failTarget = container.find(ndAny)
  # still need to apply response, or we lose cookie jars.
  container.applyResponse(response, pager.config.external.mime_types)
  if container.redirectDepth < pager.config.network.max_redirect:
    if container.url.scheme == request.url.scheme or
        container.url.scheme == "cgi-bin" or
        container.url.scheme == "http" and request.url.scheme == "https" or
        container.url.scheme == "https" and request.url.scheme == "http":
      pager.redirectTo(container, request)
    #TODO perhaps make following behavior configurable?
    elif request.url.scheme == "cgi-bin":
      pager.alert("Blocked redirection attempt to " & $request.url)
    else:
      let url = request.url
      pager.ask("Warning: switch protocols? " & $url).then(proc(x: bool) =
        if x:
          pager.redirectTo(container, request)
      )
  else:
    pager.alert("Error: maximum redirection depth reached")
    pager.deleteContainer(container, failTarget)

proc askDownloadPath(pager: Pager; container: Container; response: Response) =
  var buf = pager.config.external.download_dir
  let pathname = container.url.pathname
  if pathname[^1] == '/':
    buf &= "index.html"
  else:
    buf &= container.url.pathname.afterLast('/').percentDecode()
  pager.setLineEdit(lmDownload, buf)
  pager.lineData = LineDataDownload(
    outputId: response.outputId,
    stream: response.body
  )
  pager.deleteContainer(container, container.find(ndAny))
  pager.redraw = true
  pager.refreshStatusMsg()
  dec pager.numload

proc connected(pager: Pager; container: Container; response: Response) =
  let istream = response.body
  container.applyResponse(response, pager.config.external.mime_types)
  if response.status == 401: # unauthorized
    pager.setLineEdit(lmUsername)
    pager.lineData = LineDataAuth(url: newURL(container.url))
    istream.sclose()
    return
  # This forces client to ask for confirmation before quitting.
  # (It checks a flag on container, because console buffers must not affect this
  # variable.)
  if cfUserRequested in container.flags:
    pager.hasload = true
  if cfSave in container.flags:
    # download queried by user
    pager.askDownloadPath(container, response)
    return
  let realContentType = if "Content-Type" in response.headers:
    response.headers["Content-Type"]
  else:
    # both contentType and charset must be set by applyResponse.
    container.contentType.get & ";charset=" & $container.charset
  let mailcapRes = pager.checkMailcap(container, istream, response.outputId,
    realContentType)
  let shortContentType = container.contentType.get
  if not mailcapRes.found and
      not shortContentType.startsWithIgnoreCase("text/") and
      not shortContentType.isJavaScriptType():
    pager.askDownloadPath(container, response)
    return
  if mailcapRes.connect:
    if mailcapRes.ishtml:
      container.flags.incl(cfIsHTML)
    else:
      container.flags.excl(cfIsHTML)
    # buffer now actually exists; create a process for it
    var attrs = pager.attrs
    # subtract status line height
    attrs.height -= 1
    attrs.height_px -= attrs.ppl
    container.process = pager.forkserver.forkBuffer(
      container.config,
      container.url,
      attrs,
      mailcapRes.ishtml,
      container.charsetStack
    )
    if mailcapRes.fdout != istream.fd:
      # istream has been redirected into a filter
      istream.sclose()
    pager.procmap.add(ProcMapItem(
      container: container,
      fdout: FileHandle(mailcapRes.fdout),
      fdin: FileHandle(istream.fd),
      ostreamOutputId: mailcapRes.ostreamOutputId,
      istreamOutputId: response.outputId
    ))
    if container.replace != nil:
      pager.deleteContainer(container.replace, container.find(ndAny))
      container.replace = nil
  else:
    dec pager.numload
    pager.deleteContainer(container, container.find(ndAny))
    pager.redraw = true
    pager.refreshStatusMsg()

# true if done, false if keep
proc handleConnectingContainer*(pager: Pager; i: int) =
  let item = pager.connectingContainers[i]
  let container = item.container
  let stream = item.stream
  case item.state
  of ccsBeforeResult:
    var r = stream.initPacketReader()
    var res: int
    r.sread(res)
    if res == 0:
      r.sread(item.outputId)
      inc item.state
      container.loadinfo = "Connected to " & $container.url & ". Downloading..."
      pager.onSetLoadInfo(container)
      # continue
    else:
      var msg: string
      r.sread(msg)
      if msg == "":
        msg = getLoaderErrorMessage(res)
      pager.fail(container, msg)
      # done
      pager.connectingContainers.del(i)
      pager.selector.unregister(item.stream.fd)
      pager.loader.unregistered.add(item.stream.fd)
      stream.sclose()
  of ccsBeforeStatus:
    var r = stream.initPacketReader()
    r.sread(item.status)
    inc item.state
    # continue
  of ccsBeforeHeaders:
    let response = Response(
      res: item.res,
      outputId: item.outputId,
      status: item.status,
      url: container.request.url,
      body: stream
    )
    var r = stream.initPacketReader()
    r.sread(response.headers)
    # done
    pager.connectingContainers.del(i)
    pager.selector.unregister(item.stream.fd)
    pager.loader.unregistered.add(item.stream.fd)
    let redirect = response.getRedirect(container.request)
    if redirect != nil:
      stream.sclose()
      pager.redirect(container, response, redirect)
    else:
      pager.connected(container, response)

proc handleConnectingContainerError*(pager: Pager; i: int) =
  let item = pager.connectingContainers[i]
  pager.fail(item.container, "loader died while loading")
  pager.selector.unregister(item.stream.fd)
  pager.loader.unregistered.add(item.stream.fd)
  item.stream.sclose()
  pager.connectingContainers.del(i)

proc handleEvent0(pager: Pager; container: Container; event: ContainerEvent):
    bool =
  case event.t
  of cetLoaded:
    dec pager.numload
  of cetAnchor:
    let url2 = newURL(container.url)
    url2.setHash(event.anchor)
    pager.dupeBuffer(container, url2)
  of cetNoAnchor:
    pager.alert("Couldn't find anchor " & event.anchor)
  of cetUpdate:
    if container == pager.container:
      pager.redraw = true
      if event.force:
        pager.term.clearCanvas()
  of cetReadLine:
    if container == pager.container:
      pager.setLineEdit(lmBuffer, event.value, hide = event.password,
        extraPrompt = event.prompt)
  of cetReadArea:
    if container == pager.container:
      var s = event.tvalue
      if pager.openInEditor(s):
        pager.container.readSuccess(s)
      else:
        pager.container.readCanceled()
      pager.redraw = true
  of cetReadFile:
    if container == pager.container:
      pager.setLineEdit(lmBufferFile, "")
  of cetOpen:
    let url = event.request.url
    let sameScheme = container.url.scheme == url.scheme
    if event.request.httpMethod != hmGet and not sameScheme and
        not (container.url.scheme in ["http", "https"] and
          url.scheme in ["http", "https"]):
      pager.alert("Blocked cross-scheme POST: " & $url)
      return
    #TODO this is horrible UX, async actions shouldn't block input
    if pager.container != container or
        not event.save and not container.isHoverURL(url):
      pager.ask("Open pop-up? " & $url).then(proc(x: bool) =
        if x:
          pager.gotoURL(event.request, some(container.url),
            referrer = pager.container, save = event.save)
      )
    else:
      let url = if event.url != nil: event.url else: event.request.url
      pager.gotoURL(event.request, some(container.url),
        referrer = pager.container, save = event.save, url = url)
  of cetStatus:
    if pager.container == container:
      pager.showAlerts()
  of cetSetLoadInfo:
    if pager.container == container:
      pager.onSetLoadInfo(container)
  of cetTitle:
    if pager.container == container:
      pager.showAlerts()
      pager.term.setTitle(container.getTitle())
  of cetAlert:
    if pager.container == container:
      pager.alert(event.msg)
  of cetCancel:
    let i = pager.findConnectingContainer(container)
    if i == -1:
      # whoops. we tried to cancel, but the event loop did not favor us...
      # at least cancel it in the buffer
      container.remoteCancel()
    else:
      let item = pager.connectingContainers[i]
      dec pager.numload
      pager.deleteContainer(container, container.find(ndAny))
      pager.connectingContainers.del(i)
      pager.selector.unregister(item.stream.fd)
      pager.loader.unregistered.add(item.stream.fd)
      item.stream.sclose()
  return true

proc handleEvents*(pager: Pager; container: Container) =
  while container.events.len > 0:
    let event = container.events.popFirst()
    if not pager.handleEvent0(container, event):
      break

proc handleEvent*(pager: Pager; container: Container) =
  try:
    container.handleEvent()
    pager.handleEvents(container)
  except IOError:
    discard

proc addPagerModule*(ctx: JSContext) =
  ctx.registerType(Pager)
