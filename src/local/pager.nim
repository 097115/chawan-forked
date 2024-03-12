import std/deques
import std/net
import std/options
import std/os
import std/osproc
import std/streams
import std/tables
import std/unicode

when defined(posix):
  import std/posix

import bindings/libregexp
import config/chapath
import config/config
import config/mailcap
import config/mimetypes
import display/lineedit
import display/term
import extern/editor
import extern/runproc
import extern/stdio
import extern/tempfile
import io/bufstream
import io/posixstream
import io/promise
import io/socketstream
import io/urlfilter
import js/error
import js/javascript
import js/jstypes
import js/regex
import js/tojs
import loader/headers
import loader/loader
import loader/request
import local/container
import local/select
import server/buffer
import server/forkserver
import types/cell
import types/color
import types/cookie
import types/opt
import types/referrer
import types/urimethodmap
import types/url
import utils/strwidth
import utils/twtstr

import chagashi/charset

type
  LineMode* = enum
    NO_LINEMODE, LOCATION, USERNAME, PASSWORD, COMMAND, BUFFER, SEARCH_F,
    SEARCH_B, ISEARCH_F, ISEARCH_B, GOTO_LINE

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

  Pager* = ref object
    alertState: PagerAlertState
    alerts: seq[string]
    askcharpromise*: Promise[string]
    askcursor: int
    askpromise*: Promise[bool]
    askprompt: string
    cgiDir*: seq[string]
    commandMode {.jsget.}: bool
    config: Config
    connectingBuffers*: seq[tuple[container: Container; stream: SocketStream]]
    container*: Container
    cookiejars: Table[string, CookieJar]
    devRandom: PosixStream
    display: FixedGrid
    forkserver*: ForkServer
    inputBuffer*: string # currently uninterpreted characters
    iregex: Result[Regex, string]
    isearchpromise: EmptyPromise
    lineedit*: Option[LineEdit]
    linehist: array[LineMode, LineHistory]
    linemode: LineMode
    loader*: FileLoader
    mailcap: Mailcap
    mimeTypes: MimeTypes
    notnum*: bool # has a non-numeric character been input already?
    numload*: int
    omnirules: seq[OmniRule]
    precnum*: int32 # current number prefix (when vi-numeric-prefix is true)
    procmap*: seq[ProcMapItem]
    proxy: URL
    redraw*: bool
    regex: Opt[Regex]
    reverseSearch: bool
    scommand*: string
    siteconf: seq[SiteConfig]
    statusgrid*: FixedGrid
    term*: Terminal
    tmpdir*: string
    unreg*: seq[tuple[pid: int; stream: BufStream]]
    urimethodmap: URIMethodMap
    username: string

jsDestructor(Pager)

func attrs(pager: Pager): WindowAttributes = pager.term.attrs

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

proc setContainer*(pager: Pager, c: Container) {.jsfunc.} =
  pager.container = c
  pager.redraw = true
  if c != nil:
    pager.term.setTitle(c.getTitle())

proc hasprop(ctx: JSContext, pager: Pager, s: string): bool {.jshasprop.} =
  if pager.container != nil:
    let cval = toJS(ctx, pager.container)
    let val = JS_GetPropertyStr(ctx, cval, s)
    if val != JS_UNDEFINED:
      result = true
    JS_FreeValue(ctx, val)

proc reflect(ctx: JSContext, this_val: JSValue, argc: cint, argv: ptr JSValue,
             magic: cint, func_data: ptr JSValue): JSValue {.cdecl.} =
  let fun = cast[ptr JSValue](cast[int](func_data) + sizeof(JSValue))[]
  return JS_Call(ctx, fun, func_data[], argc, argv)

proc getter(ctx: JSContext, pager: Pager, s: string): Option[JSValue]
    {.jsgetprop.} =
  if pager.container != nil:
    let cval = toJS(ctx, pager.container)
    let val = JS_GetPropertyStr(ctx, cval, s)
    if val != JS_UNDEFINED:
      if JS_IsFunction(ctx, val):
        var func_data = @[cval, val]
        let fun = JS_NewCFunctionData(ctx, reflect, 1, 0, 2, addr func_data[0])
        return some(fun)
      return some(val)

proc searchNext(pager: Pager, n = 1) {.jsfunc.} =
  if pager.regex.isSome:
    let wrap = pager.config.search.wrap
    pager.container.markPos0()
    if not pager.reverseSearch:
      pager.container.cursorNextMatch(pager.regex.get, wrap, true, n)
    else:
      pager.container.cursorPrevMatch(pager.regex.get, wrap, true, n)
    pager.container.markPos()

proc searchPrev(pager: Pager, n = 1) {.jsfunc.} =
  if pager.regex.isSome:
    let wrap = pager.config.search.wrap
    pager.container.markPos0()
    if not pager.reverseSearch:
      pager.container.cursorPrevMatch(pager.regex.get, wrap, true, n)
    else:
      pager.container.cursorNextMatch(pager.regex.get, wrap, true, n)
    pager.container.markPos()

proc getLineHist(pager: Pager, mode: LineMode): LineHistory =
  if pager.linehist[mode] == nil:
    pager.linehist[mode] = newLineHistory()
  return pager.linehist[mode]

proc setLineEdit(pager: Pager, prompt: string, mode: LineMode,
    current = "", hide = false) =
  let hist = pager.getLineHist(mode)
  if pager.term.isatty() and pager.config.input.use_mouse:
    pager.term.disableMouse()
  let edit = readLine(prompt, pager.attrs.width, current, {}, hide, hist)
  pager.lineedit = some(edit)
  pager.linemode = mode

proc clearLineEdit(pager: Pager) =
  pager.lineedit = none(LineEdit)
  if pager.term.isatty() and pager.config.input.use_mouse:
    pager.term.enableMouse()

proc searchForward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit("/", SEARCH_F)

proc searchBackward(pager: Pager) {.jsfunc.} =
  pager.setLineEdit("?", SEARCH_B)

proc isearchForward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.isearchpromise = newResolvedPromise()
  pager.container.markPos0()
  pager.setLineEdit("/", ISEARCH_F)

proc isearchBackward(pager: Pager) {.jsfunc.} =
  pager.container.pushCursorPos()
  pager.isearchpromise = newResolvedPromise()
  pager.container.markPos0()
  pager.setLineEdit("?", ISEARCH_B)

proc gotoLine[T: string|int](pager: Pager, s: T = "") {.jsfunc.} =
  when s is string:
    if s == "":
      pager.setLineEdit("Goto line: ", GOTO_LINE)
      return
  pager.container.gotoLine(s)

proc alert*(pager: Pager, msg: string)

proc dumpAlerts*(pager: Pager) =
  for msg in pager.alerts:
    stderr.write("cha: " & msg & '\n')

proc quit*(pager: Pager, code = 0) =
  pager.term.quit()
  pager.dumpAlerts()

proc setPaths(pager: Pager): Err[string] =
  let tmpdir0 = pager.config.external.tmpdir.unquote()
  if tmpdir0.isErr:
    return err("Error unquoting external.tmpdir: " & tmpdir0.error)
  pager.tmpdir = tmpdir0.get
  var cgiDir: seq[string]
  for path in pager.config.external.cgi_dir:
    let x = path.unquote()
    if x.isErr:
      return err("Error unquoting external.cgi-dir: " & x.error)
    cgiDir.add(x.get)
  pager.cgiDir = cgiDir
  return ok()

proc newPager*(config: Config; forkserver: ForkServer; ctx: JSContext): Pager =
  let (mailcap, errs) = config.getMailcap()
  let pager = Pager(
    config: config,
    forkserver: forkserver,
    mailcap: mailcap,
    mimeTypes: config.getMimeTypes(),
    omnirules: config.getOmniRules(ctx),
    proxy: config.getProxy(),
    siteconf: config.getSiteConfig(ctx),
    term: newTerminal(stdout, config),
    urimethodmap: config.getURIMethodMap()
  )
  let r = pager.setPaths()
  if r.isErr:
    pager.alert(r.error)
    pager.alert("Exiting...")
    #TODO maybe there is a better way to do this
    pager.quit(1)
    quit(1)
  for err in errs:
    pager.alert("Error reading mailcap: " & err)
  return pager

proc genClientKey(pager: Pager): ClientKey =
  var key: ClientKey
  let n = pager.devRandom.recvData(addr key[0], key.len)
  doAssert n == key.len
  return key

proc addLoaderClient*(pager: Pager, pid: int, config: LoaderClientConfig):
    ClientKey =
  var key = pager.genClientKey()
  while unlikely(not pager.loader.addClient(key, pid, config)):
    key = pager.genClientKey()
  return key

proc setLoader*(pager: Pager, loader: FileLoader) =
  pager.devRandom = newPosixStream("/dev/urandom", O_RDONLY, 0)
  pager.loader = loader
  let config = LoaderClientConfig(
    defaultHeaders: pager.config.getDefaultHeaders(),
    proxy: pager.config.getProxy(),
    filter: newURLFilter(default = true),
  )
  loader.key = pager.addLoaderClient(pager.loader.clientPid, config)

proc launchPager*(pager: Pager, infile: File) =
  case pager.term.start(infile)
  of tsrSuccess: discard
  of tsrDA1Fail:
    pager.alert("Failed to query DA1, please set display.query-da1 = false")
  pager.display = newFixedGrid(pager.attrs.width, pager.attrs.height - 1)
  pager.statusgrid = newFixedGrid(pager.attrs.width)

func infile*(pager: Pager): File =
  return pager.term.infile

proc clearDisplay(pager: Pager) =
  pager.display = newFixedGrid(pager.display.width, pager.display.height)

proc buffer(pager: Pager): Container {.jsfget, inline.} = pager.container

proc refreshDisplay(pager: Pager, container = pager.container) =
  pager.clearDisplay()
  let hlcolor = cellColor(pager.config.display.highlight_color)
  container.drawLines(pager.display, hlcolor)
  if pager.config.display.highlight_marks:
    container.highlightMarks(pager.display, hlcolor)

# Note: this function does not work correctly if start < i of last written char
proc writeStatusMessage(pager: Pager, str: string, format = Format(),
    start = 0, maxwidth = -1, clip = '$'): int {.discardable.} =
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
    var format = Format(flags: {FLAG_REVERSE})
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

proc drawBuffer*(pager: Pager, container: Container, ostream: Stream) =
  var format = Format()
  container.readLines(proc(line: SimpleFlexibleLine) =
    if line.formats.len == 0:
      ostream.write(line.str & "\n")
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
      ostream.write(s))
  ostream.flush()

proc redraw(pager: Pager) {.jsfunc.} =
  pager.redraw = true
  pager.term.clearCanvas()

proc draw*(pager: Pager) =
  let container = pager.container
  if container == nil: return
  pager.term.hideCursor()
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
  if pager.askpromise != nil:
    pager.term.setCursor(pager.askcursor, pager.attrs.height - 1)
  elif pager.lineedit.isSome:
    pager.term.setCursor(pager.lineedit.get.getCursorX(), pager.attrs.height - 1)
  elif container.select.open:
    pager.term.setCursor(container.select.getCursorX(),
      container.select.getCursorY())
  else:
    pager.term.setCursor(pager.container.acursorx, pager.container.acursory)
  pager.term.showCursor()
  pager.term.flush()
  pager.redraw = false

proc writeAskPrompt(pager: Pager, s = "") =
  let maxwidth = pager.statusgrid.width - s.len
  let i = pager.writeStatusMessage(pager.askprompt, maxwidth = maxwidth)
  pager.askcursor = pager.writeStatusMessage(s, start = i)
  pager.term.writeGrid(pager.statusgrid, 0, pager.attrs.height - 1)

proc ask(pager: Pager, prompt: string): Promise[bool] {.jsfunc.} =
  pager.askprompt = prompt
  pager.writeAskPrompt(" (y/n)")
  pager.askpromise = Promise[bool]()
  return pager.askpromise

proc askChar(pager: Pager, prompt: string): Promise[string] {.jsfunc.} =
  pager.askprompt = prompt
  pager.writeAskPrompt()
  pager.askcharpromise = Promise[string]()
  return pager.askcharpromise

proc fulfillAsk*(pager: Pager, y: bool) =
  pager.askpromise.resolve(y)
  pager.askpromise = nil
  pager.askprompt = ""

proc fulfillCharAsk*(pager: Pager, s: string) =
  pager.askcharpromise.resolve(s)
  pager.askcharpromise = nil
  pager.askprompt = ""

proc addContainer*(pager: Pager, container: Container) =
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

proc newContainer(pager: Pager; bufferConfig: BufferConfig; request: Request;
    title = ""; redirectdepth = 0; canreinterpret = true;
    contentType = none(string); charsetStack: seq[Charset] = @[];
    url: URL = request.url; cacheId = -1): Container =
  request.suspended = true
  if bufferConfig.loaderConfig.cookieJar != nil:
    # loader stores cookie jars per client, but we have no client yet.
    # therefore we must set cookie here
    let cookie = bufferConfig.loaderConfig.cookieJar.serialize(request.url)
    if cookie != "":
      request.headers["Cookie"] = cookie
  if request.referrer != nil:
    # same with referrer
    let r = request.referrer.getReferrer(request.url,
      bufferConfig.referrerPolicy)
    if r != "":
      request.headers["Referer"] = r
  let stream = pager.loader.startRequest(request)
  pager.loader.registerFun(stream.fd)
  let container = newContainer(
    bufferConfig,
    url,
    request,
    pager.term.attrs,
    title,
    redirectdepth,
    canreinterpret,
    contentType,
    charsetStack,
    cacheId
  )
  pager.connectingBuffers.add((container, stream))
  pager.onSetLoadInfo(container)
  return container

proc newContainerFrom(pager: Pager; container: Container; contentType: string):
    Container =
  let url = newURL("cache:" & $container.cacheId).get
  return pager.newContainer(
    container.config,
    newRequest(url),
    contentType = some(contentType),
    charsetStack = container.charsetStack,
    url = container.url,
    cacheId = container.cacheId
  )

func findConnectingBuffer*(pager: Pager; fd: int): int =
  for i, (_, stream) in pager.connectingBuffers:
    if stream.fd == fd:
      return i
  -1

proc dupeBuffer(pager: Pager, container: Container, url: URL) =
  container.clone(url).then(proc(container: Container) =
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

# The prevBuffer and nextBuffer procedures emulate w3m's PREV and NEXT
# commands by traversing the container tree in a depth-first order.
proc prevBuffer*(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  let n = pager.container.parent.children.find(pager.container)
  assert n != -1, "Container not a child of its parent"
  if n > 0:
    var container = pager.container.parent.children[n - 1]
    while container.children.len > 0:
      container = container.children[^1]
    pager.setContainer(container)
  else:
    pager.setContainer(pager.container.parent)
  return true

proc nextBuffer*(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.children.len > 0:
    pager.setContainer(pager.container.children[0])
    return true
  var container = pager.container
  while container.parent != nil:
    let n = container.parent.children.find(container)
    assert n != -1, "Container not a child of its parent"
    if n < container.parent.children.high:
      pager.setContainer(container.parent.children[n + 1])
      return true
    container = container.parent
  return false

proc parentBuffer(pager: Pager): bool {.jsfunc.} =
  if pager.container == nil:
    return false
  if pager.container.parent == nil:
    return false
  pager.setContainer(pager.container.parent)
  return true

proc prevSiblingBuffer(pager: Pager): bool {.jsfunc.} =
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

proc alert*(pager: Pager, msg: string) {.jsfunc.} =
  pager.alerts.add(msg)

proc deleteContainer(pager: Pager, container: Container) =
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
    if container == pager.container:
      if n == 0:
        pager.setContainer(parent)
      else:
        pager.setContainer(parent.children[n - 1])
  elif container.children.len > 0:
    let parent = container.children[0]
    parent.parent = nil
    for i in 1..container.children.high:
      container.children[i].parent = parent
      parent.children.add(container.children[i])
    if container == pager.container:
      pager.setContainer(parent)
  else:
    for child in container.children:
      child.parent = nil
    if container == pager.container:
      pager.setContainer(nil)
  container.parent = nil
  container.children.setLen(0)
  if container.iface != nil:
    pager.unreg.add((container.process, container.iface.stream))
    pager.forkserver.removeChild(container.process)
    pager.loader.removeClient(container.process)

proc discardBuffer*(pager: Pager, container = none(Container)) {.jsfunc.} =
  let c = container.get(pager.container)
  if c == nil or c.parent == nil and c.children.len == 0:
    pager.alert("Cannot discard last buffer!")
  else:
    pager.deleteContainer(c)

proc discardTree(pager: Pager, container = none(Container)) {.jsfunc.} =
  let container = container.get(pager.container)
  if container != nil:
    for c in container.descendants:
      pager.deleteContainer(c)
  else:
    pager.alert("Buffer has no children!")

proc toggleSource(pager: Pager) {.jsfunc.} =
  if not pager.container.canreinterpret:
    return
  if pager.container.sourcepair != nil:
    pager.setContainer(pager.container.sourcepair)
  else:
    let ishtml = not pager.container.ishtml
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
proc applySiteconf(pager: Pager; url: var URL; cs: Charset): BufferConfig =
  let host = url.host
  var referer_from = false
  var cookieJar: CookieJar = nil
  var headers = pager.config.getDefaultHeaders()
  var scripting = false
  var images = false
  var charsets = pager.config.encoding.document_charset
  var userstyle = pager.config.css.stylesheet
  var proxy = pager.proxy
  let mimeTypes = pager.mimeTypes
  let urimethodmap = pager.urimethodmap
  for sc in pager.siteconf:
    if sc.url.isSome and not sc.url.get.match($url):
      continue
    elif sc.host.isSome and not sc.host.get.match(host):
      continue
    if sc.rewrite_url != nil:
      let s = sc.rewrite_url(url)
      if s.isSome and s.get != nil:
        url = s.get
    if sc.cookie.isSome:
      if sc.cookie.get:
        # host/url might have changed by now
        let jarid = sc.share_cookie_jar.get(url.host)
        if jarid notin pager.cookiejars:
          pager.cookiejars[jarid] = newCookieJar(url,
            sc.third_party_cookie)
        cookieJar = pager.cookiejars[jarid]
      else:
        cookieJar = nil # override
    if sc.scripting.isSome:
      scripting = sc.scripting.get
    if sc.referer_from.isSome:
      referer_from = sc.referer_from.get
    if sc.document_charset.len > 0:
      charsets = sc.document_charset
    if sc.images.isSome:
      images = sc.images.get
    if sc.stylesheet.isSome:
      userstyle &= "\n"
      userstyle &= sc.stylesheet.get
    if sc.proxy.isSome:
      proxy = sc.proxy.get
  return pager.config.getBufferConfig(url, cookieJar, headers, referer_from,
    scripting, charsets, images, userstyle, proxy, mimeTypes, urimethodmap,
    pager.cgiDir, pager.tmpdir, cs)

# Load request in a new buffer.
proc gotoURL(pager: Pager, request: Request, prevurl = none(URL),
    contentType = none(string), cs = CHARSET_UNKNOWN, replace: Container = nil,
    redirectdepth = 0, referrer: Container = nil) =
  if referrer != nil and referrer.config.referer_from:
    request.referrer = referrer.url
  var bufferConfig = pager.applySiteconf(request.url, cs)
  if prevurl.isNone or not prevurl.get.equals(request.url, true) or
      request.url.hash == "" or request.httpMethod != HTTP_GET:
    # Basically, we want to reload the page *only* when
    # a) we force a reload (by setting prevurl to none)
    # b) or the new URL isn't just the old URL + an anchor
    # I think this makes navigation pretty natural, or at least very close to
    # what other browsers do. Still, it would be nice if we got some visual
    # feedback on what is actually going to happen when typing a URL; TODO.
    if referrer != nil:
      bufferConfig.referrerPolicy = referrer.config.referrerPolicy
    let container = pager.newContainer(
      bufferConfig,
      request,
      redirectdepth = redirectdepth,
      contentType = contentType
    )
    if replace != nil:
      container.replace = replace
      container.copyCursorPos(container.replace)
    else:
      pager.addContainer(container)
    inc pager.numload
  else:
    pager.container.findAnchor(request.url.anchor)

proc omniRewrite(pager: Pager, s: string): string =
  for rule in pager.omnirules:
    if rule.match.match(s):
      let sub = rule.substitute_url(s)
      if sub.isSome:
        return sub.get
      else:
        let buf = $rule.match
        pager.alert("Error in substitution of rule " & buf & " for " & s)
  return s

# When the user has passed a partial URL as an argument, they might've meant
# either:
# * file://$PWD/<file>
# * https://<url>
# So we attempt to load both, and see what works.
proc loadURL*(pager: Pager, url: string, ctype = none(string),
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
  let cdir = parseURL("file://" & percentEncode(getCurrentDir(), LocalPathPercentEncodeSet) & DirSep)
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

proc readPipe0*(pager: Pager, contentType: string, cs: Charset,
    fd: FileHandle, url: URL, title: string, canreinterpret: bool): Container =
  var url = url
  pager.loader.passFd(url.pathname, fd)
  safeClose(fd)
  let bufferConfig = pager.applySiteconf(url, cs)
  return pager.newContainer(
    bufferConfig,
    newRequest(url),
    title = title,
    canreinterpret = canreinterpret,
    contentType = some(contentType)
  )

proc readPipe*(pager: Pager, contentType: string, cs: Charset, fd: FileHandle,
    title: string) =
  let url = newURL("stream:-").get
  let container = pager.readPipe0(contentType, cs, fd, url, title, true)
  inc pager.numload
  pager.addContainer(container)

proc command(pager: Pager) {.jsfunc.} =
  pager.setLineEdit("COMMAND: ", COMMAND)

proc commandMode(pager: Pager, val: bool) {.jsfset.} =
  pager.commandMode = val
  if val:
    pager.command()

proc checkRegex(pager: Pager, regex: Result[Regex, string]): Opt[Regex] =
  if regex.isErr:
    pager.alert("Invalid regex: " & regex.error)
    return err()
  return ok(regex.get)

proc compileSearchRegex(pager: Pager, s: string): Result[Regex, string] =
  var flags = {LRE_FLAG_UTF16}
  if pager.config.search.ignore_case:
    flags.incl(LRE_FLAG_IGNORECASE)
  return compileSearchRegex(s, flags)

proc updateReadLineISearch(pager: Pager, linemode: LineMode) =
  let lineedit = pager.lineedit.get
  pager.isearchpromise = pager.isearchpromise.then(proc(): EmptyPromise =
    case lineedit.state
    of CANCEL:
      pager.iregex.err()
      pager.container.popCursorPos()
      pager.container.clearSearchHighlights()
      pager.redraw = true
      pager.isearchpromise = nil
    of EDIT:
      if lineedit.news != "":
        pager.iregex = pager.compileSearchRegex(lineedit.news)
      pager.container.popCursorPos(true)
      pager.container.pushCursorPos()
      if pager.iregex.isSome:
        pager.container.hlon = true
        let wrap = pager.config.search.wrap
        return if linemode == ISEARCH_F:
          pager.container.cursorNextMatch(pager.iregex.get, wrap, false, 1)
        else:
          pager.container.cursorPrevMatch(pager.iregex.get, wrap, false, 1)
    of FINISH:
      pager.regex = pager.checkRegex(pager.iregex)
      pager.reverseSearch = linemode == ISEARCH_B
      pager.container.markPos()
      pager.container.clearSearchHighlights()
      pager.container.sendCursorPosition()
      pager.redraw = true
      pager.isearchpromise = nil
  )

proc updateReadLine*(pager: Pager) =
  let lineedit = pager.lineedit.get
  if pager.linemode in {ISEARCH_F, ISEARCH_B}:
    pager.updateReadLineISearch(pager.linemode)
  else:
    case lineedit.state
    of EDIT: return
    of FINISH:
      case pager.linemode
      of LOCATION: pager.loadURL(lineedit.news)
      of USERNAME:
        pager.username = lineedit.news
        pager.setLineEdit("Password: ", PASSWORD, hide = true)
      of PASSWORD:
        let url = newURL(pager.container.url)
        url.username = pager.username
        url.password = lineedit.news
        pager.username = ""
        pager.gotoURL(
          newRequest(url), some(pager.container.url),
          replace = pager.container,
          referrer = pager.container
        )
      of COMMAND:
        pager.scommand = lineedit.news
        if pager.commandMode:
          pager.command()
      of BUFFER: pager.container.readSuccess(lineedit.news)
      of SEARCH_F, SEARCH_B:
        if lineedit.news != "":
          let regex = pager.compileSearchRegex(lineedit.news)
          pager.regex = pager.checkRegex(regex)
        pager.reverseSearch = pager.linemode == SEARCH_B
        pager.searchNext()
      of GOTO_LINE:
        pager.container.gotoLine(lineedit.news)
      else: discard
    of CANCEL:
      case pager.linemode
      of USERNAME: pager.discardBuffer()
      of PASSWORD:
        pager.username = ""
        pager.discardBuffer()
      of BUFFER: pager.container.readCanceled()
      of COMMAND: pager.commandMode = false
      else: discard
  if lineedit.state in {LineEditState.CANCEL, LineEditState.FINISH}:
    if pager.lineedit.get == lineedit:
      pager.clearLineEdit()

# Same as load(s + '\n')
proc loadSubmit(pager: Pager, s: string) {.jsfunc.} =
  pager.loadURL(s)

# Open a URL prompt and visit the specified URL.
proc load(pager: Pager, s = "") {.jsfunc.} =
  if s.len > 0 and s[^1] == '\n':
    if s.len > 1:
      pager.loadURL(s[0..^2])
  elif s == "":
    pager.setLineEdit("URL: ", LOCATION, $pager.container.url)
  else:
    pager.setLineEdit("URL: ", LOCATION, s)

# Go to specific URL (for JS)
proc jsGotoURL(pager: Pager, s: string): JSResult[void] {.jsfunc: "gotoURL".} =
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
  setenv: Opt[bool]
  suspend: Opt[bool]
  wait: bool

#TODO we should have versions with retval as int?
proc extern(pager: Pager, cmd: string, t = ExternDict()): bool {.jsfunc.} =
  if t.setenv.get(true):
    pager.setEnvVars()
  if t.suspend.get(true):
    return runProcess(pager.term, cmd, t.wait)
  else:
    return runProcess(cmd)

proc externCapture(pager: Pager, cmd: string): Opt[string] {.jsfunc.} =
  pager.setEnvVars()
  var s: string
  if not runProcessCapture(cmd, s):
    return err()
  return ok(s)

proc externInto(pager: Pager, cmd, ins: string): bool {.jsfunc.} =
  pager.setEnvVars()
  return runProcessInto(cmd, ins)

proc externFilterSource(pager: Pager; cmd: string; c: Container = nil;
    contentType = opt(string)) {.jsfunc.} =
  let fromc = if c != nil: c else: pager.container
  let contentType = contentType.get(pager.container.contentType.get(""))
  let container = pager.newContainerFrom(fromc, contentType)
  container.ishtml = contentType == "text/html"
  pager.addContainer(container)
  container.filter = BufferFilter(cmd: cmd)

proc authorize(pager: Pager) =
  pager.setLineEdit("Username: ", USERNAME)

type CheckMailcapResult = object
  fdout: int
  ostreamOutputId: int
  connect: bool
  ishtml: bool

# Pipe output of an x-ansioutput mailcap command to the text/x-ansi handler.
proc ansiDecode(pager: Pager; url: URL; charset: Charset; ishtml: var bool;
    fdin: cint): cint =
  let entry = pager.mailcap.getMailcapEntry("text/x-ansi", "", url, charset)
  var canpipe = true
  let cmd = unquoteCommand(entry.cmd, "text/x-ansi", "", url, charset, canpipe)
  if not canpipe:
    pager.alert("Error: could not pipe to text/x-ansi, decoding as text/plain")
    return -1
  var pipefdOutAnsi: array[2, cint]
  if pipe(pipefdOutAnsi) == -1:
    pager.alert("Error: failed to open pipe")
    return
  case fork()
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
    assert false
  else:
    discard close(pipefdOutAnsi[1])
    discard close(fdin)
    ishtml = HTMLOUTPUT in entry.flags
    return pipefdOutAnsi[0]

# Pipe input into the mailcap command, then read its output into a buffer.
# needsterminal is ignored.
proc runMailcapReadPipe(pager: Pager; stream: SocketStream; cmd: string;
    pipefdOut: array[2, cint]): int =
  let pid = fork()
  if pid == -1:
    pager.alert("Error: failed to fork mailcap read process")
    return -1
  elif pid == 0:
    # child process
    discard close(pipefdOut[0])
    discard dup2(stream.fd, stdin.getFileHandle())
    stream.close()
    discard dup2(pipefdOut[1], stdout.getFileHandle())
    closeStderr()
    discard close(pipefdOut[1])
    myExec(cmd)
    doAssert false
  # parent
  pid

# Pipe input into the mailcap command, and discard its output.
# If needsterminal, leave stderr and stdout open and wait for the process.
proc runMailcapWritePipe(pager: Pager; stream: SocketStream;
    needsterminal: bool; cmd: string) =
  if needsterminal:
    pager.term.quit()
  let pid = fork()
  if pid == -1:
    pager.alert("Error: failed to fork mailcap write process")
  elif pid == 0:
    # child process
    discard dup2(stream.fd, stdin.getFileHandle())
    stream.close()
    if not needsterminal:
      closeStdout()
      closeStderr()
    myExec(cmd)
    doAssert false
  else:
    # parent
    stream.close()
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
    if ps.sendData(buffer.toOpenArray(0, n - 1)) < n:
      ps.close()
      return false
    if n < buffer.len:
      break
  ps.close()
  true

# Save input in a file, run the command, and redirect its output to a
# new buffer.
# needsterminal is ignored.
proc runMailcapReadFile(pager: Pager; stream: SocketStream;
    cmd, outpath: string; pipefdOut: array[2, cint]): int =
  let pid = fork()
  if pid == 0:
    # child process
    discard close(pipefdOut[0])
    discard dup2(pipefdOut[1], stdout.getFileHandle())
    discard close(pipefdOut[1])
    closeStderr()
    if not stream.writeToFile(outpath):
      #TODO print error message
      quit(1)
    stream.close()
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
    let pid = fork()
    if pid == 0:
      # child process
      closeStdin()
      closeStdout()
      closeStderr()
      if not stream.writeToFile(outpath):
        #TODO print error message (maybe in parent?)
        quit(1)
      stream.close()
      let ret = execCmd(cmd)
      discard tryRemoveFile(outpath)
      quit(ret)
    # parent
    stream.close()

proc filterBuffer(pager: Pager; stream: SocketStream; cmd: string;
    ishtml: bool): CheckMailcapResult =
  pager.setEnvVars()
  var pipefd_out: array[2, cint]
  if pipe(pipefd_out) == -1:
    pager.alert("Error: failed to open pipe")
    return CheckMailcapResult(connect: false, fdout: -1)
  let pid = fork()
  if pid == -1:
    pager.alert("Error: failed to fork buffer filter process")
    return CheckMailcapResult(connect: false, fdout: -1)
  elif pid == 0:
    # child
    discard close(pipefd_out[0])
    discard dup2(stream.fd, stdin.getFileHandle())
    stream.close()
    discard dup2(pipefd_out[1], stdout.getFileHandle())
    closeStderr()
    discard close(pipefd_out[1])
    myExec(cmd)
    doAssert false
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
    ishtml: ishtml
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
    istreamOutputId: int): CheckMailcapResult =
  if container.filter != nil:
    return pager.filterBuffer(stream, container.filter.cmd, container.ishtml)
  # contentType must exist, because we set it in applyResponse
  let contentType = container.contentType.get
  if contentType == "text/html":
    # We support text/html natively, so it would make little sense to execute
    # mailcap filters for it.
    return CheckMailcapResult(connect: true, fdout: stream.fd, ishtml: true)
  if contentType == "text/plain":
    # text/plain could potentially be useful. Unfortunately, many mailcaps
    # include a text/plain entry with less by default, so it's probably better
    # to ignore this.
    return CheckMailcapResult(connect: true, fdout: stream.fd)
  #TODO callback for outpath or something
  let url = container.url
  let cs = container.charset
  let entry = pager.mailcap.getMailcapEntry(contentType, "", url, cs)
  if entry == nil:
    return CheckMailcapResult(connect: true, fdout: stream.fd)
  let tmpdir = pager.tmpdir
  let ext = url.pathname.afterLast('.')
  let tempfile = getTempFile(tmpdir, ext)
  let outpath = if entry.nametemplate != "":
    unquoteCommand(entry.nametemplate, contentType, tempfile, url, cs)
  else:
    tempfile
  var canpipe = true
  let cmd = unquoteCommand(entry.cmd, contentType, outpath, url, cs, canpipe)
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
      stream.close() # connect: false implies that we consumed the stream
      break needsConnect
    let pid = if canpipe:
      pager.runMailcapReadPipe(stream, cmd, pipefdOut)
    else:
      pager.runMailcapReadFile(stream, cmd, outpath, pipefdOut)
    discard close(pipefdOut[1]) # close write
    let fdout = if not ishtml and ANSIOUTPUT in entry.flags:
      pager.ansiDecode(url, cs, ishtml, pipefdOut[0])
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
      ishtml: ishtml
    )
  delEnv("MAILCAP_URL")
  return CheckMailcapResult(connect: false, fdout: -1)

proc redirectTo(pager: Pager; container: Container; request: Request) =
  pager.alert("Redirecting to " & $request.url)
  pager.gotoURL(request, some(container.url), replace = container,
    redirectdepth = container.redirectdepth + 1, referrer = container)
  dec pager.numload

proc fail*(pager: Pager; container: Container; errorMessage: string) =
  dec pager.numload
  pager.deleteContainer(container)
  if container.retry.len > 0:
    pager.gotoURL(newRequest(container.retry.pop()),
      contentType = container.contentType)
  else:
    pager.alert("Can't load " & $container.url & " (" & errorMessage & ")")

proc redirect*(pager: Pager; container: Container; response: Response) =
  # still need to apply response, or we lose cookie jars.
  container.applyResponse(response)
  let request = response.redirect
  if container.redirectdepth < pager.config.network.max_redirect:
    if container.url.scheme == request.url.scheme or
        container.url.scheme == "cgi-bin" or
        container.url.scheme == "http" and request.url.scheme == "https" or
        container.url.scheme == "https" and request.url.scheme == "http":
      pager.redirectTo(container, request)
    else:
      let url = request.url
      pager.ask("Warning: switch protocols? " & $url).then(proc(x: bool) =
        if x:
          pager.redirectTo(container, request)
      )
  else:
    pager.alert("Error: maximum redirection depth reached")
    pager.deleteContainer(container)

proc replace(pager: Pager; container: Container) =
  let n = container.replace.children.find(container)
  if n != -1:
    container.replace.children.delete(n)
    container.parent = nil
  let n2 = container.children.find(container.replace)
  if n2 != -1:
    container.children.delete(n2)
    container.replace.parent = nil
  container.children.add(container.replace.children)
  for child in container.children:
    child.parent = container
  container.replace.children.setLen(0)
  if container.replace.parent != nil:
    container.parent = container.replace.parent
    let n = container.replace.parent.children.find(container.replace)
    assert n != -1, "Container not a child of its parent"
    container.parent.children[n] = container
    container.replace.parent = nil
  if pager.container == container.replace:
    pager.setContainer(container)
  pager.deleteContainer(container.replace)
  container.replace = nil

proc connected*(pager: Pager; container: Container; response: Response) =
  let istream = response.body
  container.applyResponse(response)
  if response.status == 401: # unauthorized
    pager.authorize()
    istream.close()
    return
  let mailcapRes = pager.checkMailcap(container, istream, response.outputId)
  if mailcapRes.connect:
    container.ishtml = mailcapRes.ishtml
    container.applyResponse(response)
    # buffer now actually exists; create a process for it
    container.process = pager.forkserver.forkBuffer(
      container.config,
      container.url,
      container.request,
      pager.attrs,
      container.ishtml,
      container.charsetStack
    )
    if mailcapRes.fdout != istream.fd:
      # istream has been redirected into a filter
      istream.close()
    pager.procmap.add(ProcMapItem(
      container: container, 
      fdout: FileHandle(mailcapRes.fdout),
      fdin: FileHandle(istream.fd),
      ostreamOutputId: mailcapRes.ostreamOutputId,
      istreamOutputId: response.outputId
    ))
    if container.replace != nil:
      pager.replace(container)
  else:
    dec pager.numload
    pager.deleteContainer(container)
    pager.redraw = true
    pager.refreshStatusMsg()

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
      pager.setLineEdit("(BUFFER) " & event.prompt, BUFFER, event.value, hide = event.password)
  of cetReadArea:
    if container == pager.container:
      var s = event.tvalue
      if openInEditor(pager.term, pager.config, pager.tmpdir, s):
        pager.container.readSuccess(s)
      else:
        pager.container.readCanceled()
      pager.redraw = true
  of cetOpen:
    let url = event.request.url
    if pager.container == nil or not pager.container.isHoverURL(url):
      pager.ask("Open pop-up? " & $url).then(proc(x: bool) =
        if x:
          pager.gotoURL(event.request, some(container.url),
            referrer = pager.container)
      )
    else:
      pager.gotoURL(event.request, some(container.url),
        referrer = pager.container)
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
  return true

proc handleEvents*(pager: Pager, container: Container) =
  while container.events.len > 0:
    let event = container.events.popFirst()
    if not pager.handleEvent0(container, event):
      break

proc handleEvent*(pager: Pager, container: Container) =
  try:
    container.handleEvent()
    pager.handleEvents(container)
  except IOError:
    discard

proc addPagerModule*(ctx: JSContext) =
  ctx.registerType(Pager)
