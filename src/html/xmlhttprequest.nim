import std/options
import std/strutils
import std/tables

import chagashi/charset
import chagashi/decoder
import html/catom
import html/chadombuilder
import html/dom
import html/domexception
import html/event
import html/script
import io/dynstream
import io/promise
import monoucha/fromjs
import monoucha/javascript
import monoucha/jserror
import monoucha/quickjs
import monoucha/tojs
import server/headers
import server/loaderiface
import server/request
import server/response
import types/blob
import types/opt
import types/url
import utils/twtstr

type
  XMLHttpRequestResponseType = enum
    xhrtUnknown = ""
    xhrtArraybuffer = "arraybuffer"
    xhrtBlob = "blob"
    xhrtDocument = "document"
    xhrtJSON = "json"
    xhrtText = "text"

  XMLHttpRequestState = enum
    xhrsUnsent = (0u16, "UNSENT")
    xhrsOpened = (1u16, "OPENED")
    xhrsHeadersReceived = (2u16, "HEADERS_RECEIVED")
    xhrsLoading = (3u16, "LOADING")
    xhrsDone = (4u16, "DONE")

  XMLHttpRequestFlag = enum
    xhrfSend, xhrfUploadListener, xhrfSync, xhrfUploadComplete, xhrfTimedOut

  XMLHttpRequestEventTarget = ref object of EventTarget

  XMLHttpRequestUpload = ref object of XMLHttpRequestEventTarget

  XMLHttpRequest = ref object of XMLHttpRequestEventTarget
    readyState: XMLHttpRequestState
    upload {.jsget.}: XMLHttpRequestUpload
    flags: set[XMLHttpRequestFlag]
    requestMethod: HttpMethod
    requestURL: URL
    headers: Headers
    response: Response
    responseType {.jsget.}: XMLHttpRequestResponseType
    timeout {.jsget.}: uint32
    responseObject: JSValue
    received: string
    contentTypeOverride: string

  ProgressEvent = ref object of Event
    lengthComputable {.jsget.}: bool
    loaded {.jsget.}: int64 #TODO should be uint64
    total {.jsget.}: int64 #TODO ditto

  ProgressEventInit = object of EventInit
    lengthComputable: bool
    loaded: int64
    total: int64

jsDestructor(XMLHttpRequestEventTarget)
jsDestructor(XMLHttpRequestUpload)
jsDestructor(XMLHttpRequest)
jsDestructor(ProgressEvent)

func newXMLHttpRequest(): XMLHttpRequest {.jsctor.} =
  let upload = XMLHttpRequestUpload()
  return XMLHttpRequest(
    upload: upload,
    headers: newHeaders(),
    responseObject: JS_UNDEFINED
  )

proc finalize(rt: JSRuntime; this: XMLHttpRequest) {.jsfin.} =
  JS_FreeValueRT(rt, this.responseObject)

proc newProgressEvent(ctype: CAtom; init = ProgressEventInit()): ProgressEvent
    {.jsctor.} =
  let event = ProgressEvent(
    ctype: ctype,
    lengthComputable: init.lengthComputable,
    loaded: init.loaded,
    total: init.total
  )
  Event(event).innerEventCreationSteps(init)
  return event

func readyState(this: XMLHttpRequest): uint16 {.jsfget.} =
  return uint16(this.readyState)

proc parseMethod(s: string): DOMResult[HttpMethod] =
  return case s.toLowerAscii()
  of "get": ok(hmGet)
  of "delete": ok(hmDelete)
  of "head": ok(hmHead)
  of "options": ok(hmOptions)
  of "patch": ok(hmPatch)
  of "post": ok(hmPost)
  of "put": ok(hmPut)
  of "connect", "trace", "track":
    errDOMException("Forbidden method", "SecurityError")
  else:
    errDOMException("Invalid method", "SyntaxError")

proc open(ctx: JSContext; this: XMLHttpRequest; httpMethod, url: string;
    misc: varargs[JSValue]): Err[DOMException] {.jsfunc.} =
  let httpMethod = ?parseMethod(httpMethod)
  let global = ctx.getGlobal()
  let x = parseURL(url, some(global.document.baseURL))
  if x.isNone:
    return errDOMException("Invalid URL", "SyntaxError")
  let parsedURL = x.get
  var async = true
  if misc.len > 0: # standard weirdness
    ?ctx.fromJS(misc[0], async)
    if misc.len > 1 and not JS_IsNull(misc[1]):
      var username: string
      ?ctx.fromJS(misc[1], username)
      parsedURL.setUsername(username)
    if misc.len > 2 and not JS_IsNull(misc[2]):
      var password: string
      ?ctx.fromJS(misc[2], password)
      parsedURL.setPassword(password)
  if not async and ctx.getWindow() != nil and
      (this.timeout != 0 or this.responseType != xhrtUnknown):
    return errDOMException("Today's horoscope: don't go outside",
      "InvalidAccessError")
  #TODO terminate fetch controller
  this.flags.excl(xhrfSend)
  this.flags.excl(xhrfUploadListener)
  if async:
    this.flags.excl(xhrfSync)
  else:
    this.flags.incl(xhrfSync)
  this.requestMethod = httpMethod
  this.headers = newHeaders()
  this.response = makeNetworkError()
  this.requestURL = parsedURL
  #TODO response object, received bytes
  if this.readyState != xhrsOpened:
    this.readyState = xhrsOpened
    global.fireEvent(satReadystatechange, this)
  return ok()

proc checkOpened(this: XMLHttpRequest): DOMResult[void] =
  if this.readyState != xhrsOpened:
    return errDOMException("ready state was expected to be `opened'",
      "InvalidStateError")
  ok()

proc checkSendFlag(this: XMLHttpRequest): DOMResult[void] =
  if xhrfSend in this.flags:
    return errDOMException("`send' flag is set", "InvalidStateError")
  ok()

proc setRequestHeader(this: XMLHttpRequest; name, value: string):
    DOMResult[void] {.jsfunc.} =
  ?this.checkOpened()
  ?this.checkSendFlag()
  if not name.isValidHeaderName() or not value.isValidHeaderValue():
    return errDOMException("Invalid header name or value", "SyntaxError")
  if isForbiddenRequestHeader(name, value):
    return ok()
  this.headers.table[name.toHeaderCase()] = @[value]
  ok()

proc setTimeout(ctx: JSContext; this: XMLHttpRequest; value: uint32):
    Err[DOMException] {.jsfset: "timeout".} =
  if ctx.getWindow() != nil and xhrfSync in this.flags:
    return errDOMException("timeout may not be set on synchronous XHR",
      "InvalidAccessError")
  this.timeout = value
  ok()

proc fireProgressEvent(window: Window; target: EventTarget; name: StaticAtom;
    loaded, length: int64) =
  let event = newProgressEvent(window.factory.toAtom(name), ProgressEventInit(
    loaded: loaded,
    total: length,
    lengthComputable: length != 0
  ))
  discard window.jsctx.dispatch(target, event)

proc errorSteps(window: Window; this: XMLHttpRequest; name: StaticAtom) =
  this.readyState = xhrsDone
  this.response = makeNetworkError()
  this.flags.excl(xhrfSend)
  if xhrfSync notin this.flags:
    window.fireEvent(satReadystatechange, this)
    if xhrfUploadComplete notin this.flags:
      this.flags.incl(xhrfUploadComplete)
      if xhrfUploadListener in this.flags:
        window.fireProgressEvent(this.upload, name, 0, 0)
        window.fireProgressEvent(this.upload, satLoadend, 0, 0)
    window.fireProgressEvent(this, name, 0, 0)
    window.fireProgressEvent(this, satLoadend, 0, 0)

proc handleErrors(window: Window; this: XMLHttpRequest): DOMException =
  if xhrfSend notin this.flags:
    return nil
  if xhrfTimedOut in this.flags:
    window.errorSteps(this, satTimeout)
    if xhrfSync in this.flags:
      return newDOMException("XHR timed out", "TimeoutError")
  elif rfAborted in this.response.flags:
    window.errorSteps(this, satAbort)
    if xhrfSync in this.flags:
      return newDOMException("XHR aborted", "AbortError")
  elif this.response.responseType == rtError:
    window.errorSteps(this, satError)
    if xhrfSync in this.flags:
      return newDOMException("Network error in XHR", "NetworkError")
  return nil

type XHROpaque = ref object of RootObj
  this: XMLHttpRequest
  window: Window
  len: int64 #TODO should be uint64

proc onReadXHR(response: Response) =
  const BufferSize = 4096
  let opaque = XHROpaque(response.opaque)
  let this = opaque.this
  let window = opaque.window
  while true:
    let olen = this.received.len
    this.received.setLen(olen + BufferSize)
    try:
      let n = response.body.recvData(addr this.received[olen], BufferSize)
      this.received.setLen(olen + n)
      if n == 0:
        break
    except ErrorAgain:
      this.received.setLen(olen)
      break
  if this.readyState == xhrsHeadersReceived:
    this.readyState = xhrsLoading
  window.fireEvent(satReadystatechange, this)
  window.fireProgressEvent(this, satProgress, int64(this.received.len),
    opaque.len)

proc onFinishXHR(response: Response; success: bool) =
  let opaque = XHROpaque(response.opaque)
  let this = opaque.this
  let window = opaque.window
  if success:
    discard window.handleErrors(this)
    if response.responseType != rtError:
      let recvLen = int64(this.received.len)
      window.fireProgressEvent(this, satProgress, recvLen, opaque.len)
      this.readyState = xhrsDone
      this.flags.excl(xhrfSend)
      window.fireEvent(satReadystatechange, this)
      window.fireProgressEvent(this, satLoad, recvLen, opaque.len)
      window.fireProgressEvent(this, satLoadend, recvLen, opaque.len)
  else:
    this.response = makeNetworkError()
    discard window.handleErrors(this)

proc send(ctx: JSContext; this: XMLHttpRequest; body = JS_NULL): JSResult[void]
    {.jsfunc.} =
  ?this.checkOpened()
  ?this.checkSendFlag()
  var body = body
  if this.requestMethod in {hmGet, hmHead}:
    body = JS_NULL
  let request = newRequest(this.requestURL, this.requestMethod, this.headers)
  if not JS_IsNull(body):
    var document: Document = nil
    if ctx.fromJS(body, document).isSome:
      request.body = RequestBody(
        t: rbtString,
        s: document.serializeFragment().toValidUTF8() # replace surrogates
      )
    #TODO else...
    if "Content-Type" in this.headers:
      request.headers["Content-Type"].setContentTypeAttr("charset", "UTF-8")
    elif document != nil:
      request.headers["Content-Type"] = "text/html;charset=UTF-8"
  let jsRequest = JSRequest(
    #TODO unsafe request flag, client, cors credentials mode,
    # use-url-credentials, initiator type
    request: request,
    mode: rmCors,
    credentialsMode: cmSameOrigin,
  )
  if JS_IsNull(body):
    this.flags.incl(xhrfUploadComplete)
  else:
    this.flags.excl(xhrfUploadComplete)
  this.flags.excl(xhrfTimedOut)
  this.flags.incl(xhrfSend)
  let window = ctx.getWindow()
  if xhrfSync notin this.flags: # async
    window.fireProgressEvent(this, satLoadstart, 0, 0)
    let v = ctx.toJS(jsRequest)
    let p = window.fetchImpl(v)
    JS_FreeValue(ctx, v)
    if p.isNone:
      return err(p.error)
    p.get.then(proc(res: JSResult[Response]) =
      if res.isNone:
        this.response = makeNetworkError()
        discard window.handleErrors(this)
        return
      let response = res.get
      this.response = response
      this.readyState = xhrsHeadersReceived
      window.fireEvent(satReadystatechange, this)
      if this.readyState != xhrsHeadersReceived:
        return
      let len = max(response.getContentLength(), 0)
      response.opaque = XHROpaque(this: this, window: window, len: len)
      response.onRead = onReadXHR
      response.onFinish = onFinishXHR
      response.resume()
      #TODO timeout
    )
  else: # sync
    #TODO cors requests?
    if window.settings.origin.isSameOrigin(request.url.origin):
      let response = window.loader.doRequest(request)
      if response.res == 0:
        #TODO timeout
        response.resume()
        try:
          this.received = response.body.recvAll()
          #TODO report timing
          let len = max(response.getContentLength(), 0)
          response.opaque = XHROpaque(this: this, window: window, len: len)
          response.onFinishXHR(true)
          return ok()
        except IOError:
          discard
    let ex = window.handleErrors(this)
    this.response = makeNetworkError()
    if ex != nil:
      return err(ex)
  ok()

#TODO abort

proc responseURL(this: XMLHttpRequest): string {.jsfget.} =
  return this.response.surl

proc status(this: XMLHttpRequest): uint16 {.jsfget.} =
  return this.response.status

proc statusText(this: XMLHttpRequest): string {.jsfget.} =
  return ""

proc getResponseHeader(ctx: JSContext; this: XMLHttpRequest; name: string):
    JSValue {.jsfunc.} =
  let res = ctx.get(this.response.headers, name)
  if JS_IsException(res):
    return JS_NULL
  return res

#TODO getAllResponseHeaders

func getCharset(this: XMLHttpRequest): Charset =
  let override = this.contentTypeOverride.toLowerAscii()
  let cs = override.getContentTypeAttr("charset").getCharset()
  if cs != CHARSET_UNKNOWN:
    return cs
  return this.response.getCharset(CHARSET_UTF_8)

proc responseText(ctx: JSContext; this: XMLHttpRequest): JSValue {.jsfget.} =
  if this.responseType notin {xhrtUnknown, xhrtText}:
    let ex = newDOMException("response type was expected to be '' or 'text'",
      "InvalidStateError")
    return JS_Throw(ctx, ctx.toJS(ex))
  if this.readyState notin {xhrsLoading, xhrsDone}:
    return ctx.toJS("")
  let charset = this.getCharset()
  #TODO XML encoding stuff?
  return ctx.toJS(this.received.decodeAll(charset))

proc overrideMimeType(this: XMLHttpRequest; s: string): DOMResult[void]
    {.jsfunc.} =
  if this.readyState notin {xhrsLoading, xhrsDone}:
    return errDOMException("readyState must not be loading or done",
      "InvalidStateError")
  #TODO parse
  this.contentTypeOverride = s
  return ok()

proc setResponseType(ctx: JSContext; this: XMLHttpRequest;
    value: XMLHttpRequestResponseType): Err[DOMException]
    {.jsfset: "responseType".} =
  let window = ctx.getWindow()
  if window == nil and value == xhrtDocument:
    return ok()
  if this.readyState in {xhrsLoading, xhrsDone}:
    return errDOMException("readyState must not be loading or done",
      "InvalidStateError")
  if window != nil and xhrfSync in this.flags:
    return errDOMException("responseType may not be set on synchronous XHR",
      "InvalidAccessError")
  this.responseType = value
  ok()

func getContentType(this: XMLHttpRequest): string =
  if this.contentTypeOverride != "":
    return this.contentTypeOverride
  return this.response.getContentType()

proc ptrify(s: var string):
    tuple[opaque: pointer; p: ptr UncheckedArray[uint8]] =
  if s.len == 0:
    return (nil, nil)
  var sr = new(string)
  sr[] = move(s)
  GC_ref(sr)
  return (cast[pointer](sr), cast[ptr UncheckedArray[uint8]](addr sr[0]))

proc deallocPtrified(p: pointer) =
  if p != nil:
    let sr = cast[ref string](p)
    GC_unref(sr)

proc abufFree(rt: JSRuntime; opaque, p: pointer) {.cdecl.} =
  deallocPtrified(opaque)

proc blobFree(opaque, p: pointer) {.nimcall.} =
  deallocPtrified(opaque)

proc response(ctx: JSContext; this: XMLHttpRequest): JSValue {.jsfget.} =
  if this.responseType in {xhrtText, xhrtUnknown}:
    return ctx.responseText(this)
  if this.readyState != xhrsDone:
    return JS_NULL
  if JS_IsUndefined(this.responseObject):
    case this.responseType
    of xhrtArraybuffer:
      let len = csize_t(this.received.len)
      let (opaque, p) = this.received.ptrify()
      this.responseObject = JS_NewArrayBuffer(ctx, p, len, abufFree, opaque,
        false)
    of xhrtBlob:
      let len = this.received.len
      let (opaque, p) = this.received.ptrify()
      let blob = newBlob(p, len, this.getContentType(), blobFree, opaque)
      this.responseObject = ctx.toJS(blob)
    of xhrtDocument:
      #TODO this is certainly not compliant
      let res = ctx.parseFromString(newDOMParser(), this.received, "text/html")
      this.responseObject = ctx.toJS(res)
    of xhrtJSON:
      this.responseObject = JS_ParseJSON(ctx, cstring(this.received),
        csize_t(this.received.len), cstring"<input>")
    else: discard
  if JS_IsException(this.responseObject):
    this.responseObject = JS_UNDEFINED
  return this.responseObject

# Event reflection

const ReflectMap = [
  cint(0): satLoadstart,
  satProgress,
  satAbort,
  satError,
  satLoad,
  satTimeout,
  satLoadend,
  satReadystatechange
]

proc jsReflectGet(ctx: JSContext; this: JSValue; magic: cint): JSValue
    {.cdecl.} =
  let val = toJS(ctx, $ReflectMap[magic])
  let atom = JS_ValueToAtom(ctx, val)
  var res = JS_NULL
  var desc: JSPropertyDescriptor
  if JS_GetOwnProperty(ctx, addr desc, this, atom) > 0:
    JS_FreeValue(ctx, desc.setter)
    JS_FreeValue(ctx, desc.getter)
    res = JS_GetProperty(ctx, this, atom)
  JS_FreeValue(ctx, val)
  JS_FreeAtom(ctx, atom)
  return res

proc jsReflectSet(ctx: JSContext; this, val: JSValue; magic: cint): JSValue
    {.cdecl.} =
  if JS_IsFunction(ctx, val):
    let atom = ReflectMap[magic]
    var target: EventTarget
    assert ctx.fromJS(this, target).isSome
    ctx.definePropertyC(this, "on" & $atom, JS_DupValue(ctx, val))
    #TODO I haven't checked but this might also be wrong
    doAssert ctx.addEventListener(target, ctx.toAtom(atom), val).isSome
  return JS_DupValue(ctx, val)

func xhretGetSet(): seq[TabGetSet] =
  result = @[]
  for i, it in ReflectMap:
    if it == satReadystatechange:
      break
    result.add(TabGetSet(
      name: "on" & $it,
      get: jsReflectGet,
      set: jsReflectSet,
      magic: int16(i)
    ))

proc addXMLHttpRequestModule*(ctx: JSContext) =
  let eventTargetCID = ctx.getClass("EventTarget")
  let eventCID = ctx.getClass("Event")
  const getset0 = xhretGetSet()
  let xhretCID = ctx.registerType(XMLHttpRequestEventTarget, eventTargetCID,
    hasExtraGetSet = true, extraGetSet = getset0)
  ctx.registerType(XMLHttpRequestUpload, xhretCID)
  ctx.registerType(ProgressEvent, eventCID)
  const getset1 = [TabGetSet(
    name: "onreadystatechange",
    get: jsReflectGet,
    set: jsReflectSet,
    magic: int16(ReflectMap.high)
  )]
  let xhrCID = ctx.registerType(XMLHttpRequest, xhretCID, hasExtraGetSet = true,
    extraGetSet = getset1)
  ctx.defineConsts(xhrCID, XMLHttpRequestState, uint16)
